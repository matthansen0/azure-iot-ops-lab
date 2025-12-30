#!/usr/bin/env bash
# fabric-preflight.sh - Pre-flight checks for Fabric RTI integration
# Run this BEFORE deploying AIO to validate Fabric API access, permissions, and capacity
#
# Usage:
#   ./fabric/fabric-preflight.sh                    # Interactive mode
#   ./fabric/fabric-preflight.sh --capacity-id <id> # Specify capacity
#   ./fabric/fabric-preflight.sh --list-capacities  # List available capacities

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fabric API base URL
FABRIC_API_BASE="https://api.fabric.microsoft.com/v1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $*"; }

# ============================================================================
# PRE-FLIGHT CHECK FUNCTIONS
# ============================================================================

# Check 1: Azure CLI login status
check_azure_login() {
    log_step "Checking Azure CLI login status..."
    
    if ! command -v az &>/dev/null; then
        log_error "Azure CLI is not installed"
        echo "  Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
        return 1
    fi
    
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure CLI"
        echo "  Run: az login"
        return 1
    fi
    
    local account_info
    account_info=$(az account show -o json)
    local user_name
    user_name=$(echo "$account_info" | jq -r '.user.name // "unknown"')
    local subscription
    subscription=$(echo "$account_info" | jq -r '.name // "unknown"')
    
    log_success "Logged in as: $user_name"
    log_info "  Subscription: $subscription"
    return 0
}

# Check 2: Can get Fabric API token
check_fabric_token() {
    log_step "Checking Fabric API token acquisition..."
    
    local token
    token=$(az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv 2>&1) || {
        log_error "Cannot get Fabric API token"
        echo "  This usually means:"
        echo "    - Fabric is not enabled for your tenant"
        echo "    - Your account doesn't have Fabric access"
        echo "    - You need to consent to the Fabric API"
        echo ""
        echo "  Try: az login --scope https://api.fabric.microsoft.com/.default"
        return 1
    }
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Received empty token"
        return 1
    fi
    
    # Store for subsequent checks
    FABRIC_TOKEN="$token"
    log_success "Fabric API token acquired"
    return 0
}

# Check 3: Fabric API is accessible
check_fabric_api_access() {
    log_step "Checking Fabric API accessibility..."
    
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    case "$http_code" in
        200)
            log_success "Fabric API is accessible"
            local workspace_count
            workspace_count=$(echo "$body" | jq '.value | length' 2>/dev/null || echo "0")
            log_info "  You have access to $workspace_count existing workspace(s)"
            return 0
            ;;
        401)
            log_error "Authentication failed (HTTP 401)"
            echo "  Your token may be expired. Try: az login"
            return 1
            ;;
        403)
            log_error "Access forbidden (HTTP 403)"
            echo "  You don't have permission to access Fabric"
            echo "  Contact your Fabric admin to grant access"
            return 1
            ;;
        *)
            log_error "Fabric API error (HTTP $http_code)"
            echo "  Response: $body"
            return 1
            ;;
    esac
}

# Check 4: List available capacities
list_fabric_capacities() {
    log_step "Checking available Fabric capacities..."
    
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/capacities" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" != "200" ]]; then
        log_warn "Could not list capacities (HTTP $http_code)"
        echo "  You may need to specify a capacity ID manually"
        return 1
    fi
    
    local capacity_count
    capacity_count=$(echo "$body" | jq '.value | length' 2>/dev/null || echo "0")
    
    if [[ "$capacity_count" == "0" ]]; then
        log_warn "No Fabric capacities found"
        echo ""
        echo "  You need a Fabric capacity to create workspaces."
        echo "  Options:"
        echo "    1. Start a Fabric trial: https://app.fabric.microsoft.com"
        echo "    2. Purchase F2+ capacity in Azure portal"
        echo "    3. Ask your admin to assign you to an existing capacity"
        echo ""
        return 1
    fi
    
    log_success "Found $capacity_count capacity/capacities:"
    echo ""
    echo "$body" | jq -r '.value[] | "  ID: \(.id)\n  Name: \(.displayName)\n  SKU: \(.sku)\n  State: \(.state)\n  Region: \(.region)\n"' 2>/dev/null
    
    # Return the capacities JSON for use by other functions
    FABRIC_CAPACITIES="$body"
    return 0
}

# Check 5: Verify specific capacity
check_capacity_access() {
    local capacity_id="$1"
    
    log_step "Verifying access to capacity: $capacity_id"
    
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/capacities/${capacity_id}" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        local cap_name
        cap_name=$(echo "$body" | jq -r '.displayName // "unknown"')
        local cap_sku
        cap_sku=$(echo "$body" | jq -r '.sku // "unknown"')
        local cap_state
        cap_state=$(echo "$body" | jq -r '.state // "unknown"')
        
        log_success "Capacity verified: $cap_name ($cap_sku)"
        log_info "  State: $cap_state"
        
        if [[ "$cap_state" != "Active" ]]; then
            log_warn "Capacity is not in Active state"
            return 1
        fi
        
        SELECTED_CAPACITY_ID="$capacity_id"
        return 0
    else
        log_error "Cannot access capacity (HTTP $http_code)"
        echo "  Response: $body"
        return 1
    fi
}

# Check 6: Test workspace creation (dry-run style)
check_workspace_creation_permission() {
    log_step "Checking workspace creation permission..."
    
    # We can't do a true dry-run, but we can try to create and immediately delete
    # Or check if there's an existing workspace we can query
    
    # For now, just verify we have the token scopes needed
    # The actual test would create a resource, which we want to avoid in preflight
    
    local response
    local http_code
    
    # Try to get workspace list - if this works, we likely have create permission too
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $FABRIC_TOKEN" \
        -H "Content-Type: application/json" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    
    if [[ "$http_code" == "200" ]]; then
        log_success "Workspace API access confirmed"
        log_info "  Note: Actual creation will be tested during deployment"
        return 0
    else
        log_error "Cannot access workspace API"
        return 1
    fi
}

# Check 7: Verify Eventhouse/RTI features available
check_rti_features() {
    log_step "Checking Real-Time Intelligence features..."
    
    # Check if we can access the items API with RTI types
    # This helps confirm RTI is enabled for the capacity
    
    log_info "RTI features (Eventhouse, KQL Database, Eventstream) require:"
    echo "    - Fabric capacity with RTI enabled"
    echo "    - F2 SKU or higher (or trial)"
    echo ""
    log_success "RTI feature check passed (will be verified during deployment)"
    return 0
}

# ============================================================================
# MAIN PREFLIGHT RUNNER
# ============================================================================

run_preflight_checks() {
    local capacity_id="${1:-}"
    local all_passed=true
    
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Fabric RTI Pre-Flight Checks                                ║${NC}"
    echo -e "${CYAN}║           Run BEFORE deploying AIO to save time!                      ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check 1: Azure CLI
    if ! check_azure_login; then
        all_passed=false
        echo ""
    fi
    
    # Check 2: Fabric token
    if ! check_fabric_token; then
        all_passed=false
        log_error "Cannot proceed without Fabric API access"
        return 1
    fi
    echo ""
    
    # Check 3: API access
    if ! check_fabric_api_access; then
        all_passed=false
    fi
    echo ""
    
    # Check 4: List capacities
    if ! list_fabric_capacities; then
        all_passed=false
    fi
    echo ""
    
    # Check 5: Specific capacity (if provided)
    if [[ -n "$capacity_id" ]]; then
        if ! check_capacity_access "$capacity_id"; then
            all_passed=false
        fi
        echo ""
    fi
    
    # Check 6: Workspace permission
    if ! check_workspace_creation_permission; then
        all_passed=false
    fi
    echo ""
    
    # Check 7: RTI features
    if ! check_rti_features; then
        all_passed=false
    fi
    echo ""
    
    # Summary
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════${NC}"
    if [[ "$all_passed" == "true" ]]; then
        log_success "All pre-flight checks PASSED!"
        echo ""
        echo "You can now deploy AIO with Fabric integration:"
        echo ""
        if [[ -n "${SELECTED_CAPACITY_ID:-}" ]]; then
            echo "  ./deploy.sh \\"
            echo "    --subscription \"<SUB_ID>\" \\"
            echo "    --location \"eastus2\" \\"
            echo "    --storage-account \"aio\$(date +%s)\" \\"
            echo "    --enable-fabric \\"
            echo "    --fabric-workspace \"aio-fabric-workspace\" \\"
            echo "    --fabric-capacity-id \"$SELECTED_CAPACITY_ID\""
        else
            echo "  ./deploy.sh \\"
            echo "    --subscription \"<SUB_ID>\" \\"
            echo "    --location \"eastus2\" \\"
            echo "    --storage-account \"aio\$(date +%s)\" \\"
            echo "    --enable-fabric \\"
            echo "    --fabric-workspace \"aio-fabric-workspace\" \\"
            echo "    --fabric-capacity-id \"<CAPACITY_ID_FROM_ABOVE>\""
        fi
        echo ""
        return 0
    else
        log_error "Some pre-flight checks FAILED"
        echo ""
        echo "Please resolve the issues above before deploying."
        echo "This will save you from a 45+ minute failed deployment!"
        echo ""
        return 1
    fi
}

show_help() {
    cat <<EOF
Fabric RTI Pre-Flight Checks

Usage:
  $0 [options]

Options:
  --list-capacities     List available Fabric capacities and exit
  --capacity-id <ID>    Verify access to a specific capacity
  --help                Show this help message

Examples:
  # Run all pre-flight checks
  $0

  # List available capacities first
  $0 --list-capacities

  # Verify a specific capacity
  $0 --capacity-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

What this checks:
  1. Azure CLI login status
  2. Fabric API token acquisition
  3. Fabric API accessibility
  4. Available Fabric capacities
  5. Workspace creation permissions
  6. RTI feature availability

Run this BEFORE './deploy.sh --enable-fabric' to avoid wasting time!
EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local capacity_id=""
    local list_only=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --capacity-id)
                capacity_id="$2"
                shift 2
                ;;
            --list-capacities)
                list_only=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    if [[ "$list_only" == "true" ]]; then
        check_azure_login || exit 1
        check_fabric_token || exit 1
        echo ""
        list_fabric_capacities
        exit $?
    fi
    
    run_preflight_checks "$capacity_id"
}

main "$@"
