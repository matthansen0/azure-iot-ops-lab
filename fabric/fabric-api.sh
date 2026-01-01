#!/usr/bin/env bash
# fabric-api.sh - Microsoft Fabric REST API integration for Azure IoT Operations
# This module provides functions to create and manage Fabric workspaces, Eventhouses,
# KQL databases, and Eventstreams using the Fabric REST API.

set -euo pipefail

# Fabric API base URL
FABRIC_API_BASE="https://api.fabric.microsoft.com/v1"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${YELLOW}$*${NC}\n"; }

# Get Fabric API access token using Azure CLI
# Returns: Access token string
get_fabric_token() {
    local token
    token=$(az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv 2>/dev/null)
    if [[ -z "$token" ]]; then
        log_error "Failed to get Fabric API access token. Ensure you're logged in with 'az login'"
        return 1
    fi
    echo "$token"
}

# Validate that the token works by calling the Fabric API
# Arguments: $1 = token
# Returns: 0 if valid, 1 if invalid
validate_fabric_token() {
    local token="$1"
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    http_code=$(echo "$response" | tail -n1)
    
    if [[ "$http_code" == "200" ]]; then
        log_success "Fabric API token validated successfully"
        return 0
    else
        log_error "Fabric API token validation failed (HTTP $http_code)"
        return 1
    fi
}

# Create a Fabric workspace
# Arguments: $1 = token, $2 = workspace_name, $3 = capacity_id (optional)
# Returns: Workspace ID on success
create_fabric_workspace() {
    local token="$1"
    local workspace_name="$2"
    local capacity_id="${3:-}"
    local payload
    local response
    local http_code
    local body
    local workspace_id
    
    log_info "Creating Fabric workspace: $workspace_name"
    
    # Check if workspace already exists
    local existing_id
    existing_id=$(get_workspace_by_name "$token" "$workspace_name")
    if [[ -n "$existing_id" ]]; then
        log_warn "Workspace '$workspace_name' already exists with ID: $existing_id"
        echo "$existing_id"
        return 0
    fi
    
    # Build payload
    if [[ -n "$capacity_id" ]]; then
        payload=$(jq -n --arg name "$workspace_name" --arg cap "$capacity_id" \
            '{displayName: $name, capacityId: $cap}')
    else
        payload=$(jq -n --arg name "$workspace_name" '{displayName: $name}')
    fi
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" ]]; then
        workspace_id=$(echo "$body" | jq -r '.id')
        log_success "Created workspace: $workspace_name (ID: $workspace_id)"
        echo "$workspace_id"
        return 0
    elif [[ "$http_code" == "202" ]]; then
        # Async operation - need to poll for completion
        local operation_id
        operation_id=$(echo "$body" | jq -r '.operationId // empty')
        if [[ -n "$operation_id" ]]; then
            log_info "Workspace creation in progress (operation: $operation_id)"
            workspace_id=$(wait_for_operation "$token" "$operation_id" "workspace")
            if [[ -n "$workspace_id" ]]; then
                log_success "Created workspace: $workspace_name (ID: $workspace_id)"
                echo "$workspace_id"
                return 0
            fi
        fi
        log_error "Failed to get workspace ID from async operation"
        return 1
    else
        log_error "Failed to create workspace (HTTP $http_code): $body"
        return 1
    fi
}

# Get workspace ID by name
# Arguments: $1 = token, $2 = workspace_name
# Returns: Workspace ID or empty string
get_workspace_by_name() {
    local token="$1"
    local workspace_name="$2"
    local response
    local workspace_id
    
    response=$(curl -s -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    workspace_id=$(echo "$response" | jq -r --arg name "$workspace_name" \
        '.value[] | select(.displayName == $name) | .id' 2>/dev/null || echo "")
    
    echo "$workspace_id"
}

# Create an Eventhouse in a workspace
# Arguments: $1 = token, $2 = workspace_id, $3 = eventhouse_name
# Returns: Eventhouse ID on success
create_eventhouse() {
    local token="$1"
    local workspace_id="$2"
    local eventhouse_name="$3"
    local payload
    local response
    local http_code
    local body
    local eventhouse_id
    
    log_info "Creating Eventhouse: $eventhouse_name"
    
    # Check if eventhouse already exists
    local existing_id
    existing_id=$(get_item_by_name "$token" "$workspace_id" "$eventhouse_name" "Eventhouse")
    if [[ -n "$existing_id" ]]; then
        log_warn "Eventhouse '$eventhouse_name' already exists with ID: $existing_id"
        echo "$existing_id"
        return 0
    fi
    
    payload=$(jq -n --arg name "$eventhouse_name" \
        '{displayName: $name, type: "Eventhouse"}')
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" || "$http_code" == "202" ]]; then
        # Handle async operation
        if [[ "$http_code" == "202" ]]; then
            local operation_id
            operation_id=$(echo "$body" | jq -r '.operationId // empty')
            if [[ -n "$operation_id" ]]; then
                log_info "Eventhouse creation in progress..."
                eventhouse_id=$(wait_for_item_creation "$token" "$workspace_id" "$eventhouse_name" "Eventhouse" 60)
            fi
        else
            eventhouse_id=$(echo "$body" | jq -r '.id')
        fi
        
        if [[ -n "$eventhouse_id" ]]; then
            log_success "Created Eventhouse: $eventhouse_name (ID: $eventhouse_id)"
            echo "$eventhouse_id"
            return 0
        fi
    fi
    
    log_error "Failed to create Eventhouse (HTTP $http_code): $body"
    return 1
}

# Create a KQL Database in an Eventhouse
# Arguments: $1 = token, $2 = workspace_id, $3 = database_name, $4 = eventhouse_id
# Returns: Database ID on success
create_kql_database() {
    local token="$1"
    local workspace_id="$2"
    local database_name="$3"
    local eventhouse_id="$4"
    local payload
    local response
    local http_code
    local body
    local database_id
    
    log_info "Creating KQL Database: $database_name"
    
    # Check if database already exists
    local existing_id
    existing_id=$(get_item_by_name "$token" "$workspace_id" "$database_name" "KQLDatabase")
    if [[ -n "$existing_id" ]]; then
        log_warn "KQL Database '$database_name' already exists with ID: $existing_id"
        echo "$existing_id"
        return 0
    fi
    
    # KQL Database creation payload with parent Eventhouse reference
    payload=$(jq -n --arg name "$database_name" --arg ehId "$eventhouse_id" \
        '{
            displayName: $name,
            type: "KQLDatabase",
            creationPayload: {
                databaseType: "ReadWrite",
                parentEventhouseItemId: $ehId
            }
        }')
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" || "$http_code" == "202" ]]; then
        if [[ "$http_code" == "202" ]]; then
            log_info "KQL Database creation in progress..."
            database_id=$(wait_for_item_creation "$token" "$workspace_id" "$database_name" "KQLDatabase" 60)
        else
            database_id=$(echo "$body" | jq -r '.id')
        fi
        
        if [[ -n "$database_id" ]]; then
            log_success "Created KQL Database: $database_name (ID: $database_id)"
            echo "$database_id"
            return 0
        fi
    fi
    
    log_error "Failed to create KQL Database (HTTP $http_code): $body"
    return 1
}

# Create an Eventstream in a workspace
# Arguments: $1 = token, $2 = workspace_id, $3 = eventstream_name
# Returns: Eventstream ID on success
create_eventstream() {
    local token="$1"
    local workspace_id="$2"
    local eventstream_name="$3"
    local payload
    local response
    local http_code
    local body
    local eventstream_id
    
    log_info "Creating Eventstream: $eventstream_name"
    
    # Check if eventstream already exists
    local existing_id
    existing_id=$(get_item_by_name "$token" "$workspace_id" "$eventstream_name" "Eventstream")
    if [[ -n "$existing_id" ]]; then
        log_warn "Eventstream '$eventstream_name' already exists with ID: $existing_id"
        echo "$existing_id"
        return 0
    fi
    
    payload=$(jq -n --arg name "$eventstream_name" \
        '{displayName: $name, type: "Eventstream"}')
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" || "$http_code" == "202" ]]; then
        if [[ "$http_code" == "202" ]]; then
            log_info "Eventstream creation in progress..."
            eventstream_id=$(wait_for_item_creation "$token" "$workspace_id" "$eventstream_name" "Eventstream" 60)
        else
            eventstream_id=$(echo "$body" | jq -r '.id')
        fi
        
        if [[ -n "$eventstream_id" ]]; then
            log_success "Created Eventstream: $eventstream_name (ID: $eventstream_id)"
            echo "$eventstream_id"
            return 0
        fi
    fi
    
    log_error "Failed to create Eventstream (HTTP $http_code): $body"
    return 1
}

# Get Eventstream connection info for AIO dataflow
# Arguments: $1 = token, $2 = workspace_id, $3 = eventstream_id
# Returns: JSON with connection details
get_eventstream_connection_info() {
    local token="$1"
    local workspace_id="$2"
    local eventstream_id="$3"
    local response
    local http_code
    local body
    
    log_info "Getting Eventstream connection info..."
    
    response=$(curl -s -w "\n%{http_code}" -X GET \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/eventstreams/${eventstream_id}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        echo "$body"
        return 0
    fi
    
    log_error "Failed to get Eventstream info (HTTP $http_code)"
    return 1
}

# Get item by name and type in a workspace
# Arguments: $1 = token, $2 = workspace_id, $3 = item_name, $4 = item_type
# Returns: Item ID or empty string
get_item_by_name() {
    local token="$1"
    local workspace_id="$2"
    local item_name="$3"
    local item_type="$4"
    local response
    local item_id
    
    response=$(curl -s -X GET \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items?type=${item_type}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    item_id=$(echo "$response" | jq -r --arg name "$item_name" \
        '.value[] | select(.displayName == $name) | .id' 2>/dev/null || echo "")
    
    echo "$item_id"
}

# Wait for an item to be created (polling)
# Arguments: $1 = token, $2 = workspace_id, $3 = item_name, $4 = item_type, $5 = timeout_seconds
# Returns: Item ID on success
wait_for_item_creation() {
    local token="$1"
    local workspace_id="$2"
    local item_name="$3"
    local item_type="$4"
    local timeout="${5:-120}"
    local elapsed=0
    local interval=5
    local item_id
    
    while [[ $elapsed -lt $timeout ]]; do
        item_id=$(get_item_by_name "$token" "$workspace_id" "$item_name" "$item_type")
        if [[ -n "$item_id" ]]; then
            echo "$item_id"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Waiting for $item_type creation... (${elapsed}s / ${timeout}s)"
    done
    
    log_error "Timeout waiting for $item_type creation"
    return 1
}

# Wait for async operation to complete
# Arguments: $1 = token, $2 = operation_id, $3 = resource_type
# Returns: Resource ID on success
wait_for_operation() {
    local token="$1"
    local operation_id="$2"
    local resource_type="$3"
    local timeout=120
    local elapsed=0
    local interval=5
    local response
    local status
    
    while [[ $elapsed -lt $timeout ]]; do
        response=$(curl -s -X GET "${FABRIC_API_BASE}/operations/${operation_id}" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json")
        
        status=$(echo "$response" | jq -r '.status // "Unknown"')
        
        if [[ "$status" == "Succeeded" ]]; then
            local resource_id
            resource_id=$(echo "$response" | jq -r '.resourceId // empty')
            echo "$resource_id"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
            log_error "Operation failed: $error_msg"
            return 1
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for operation to complete"
    return 1
}

# Delete a Fabric workspace
# Arguments: $1 = token, $2 = workspace_id
delete_fabric_workspace() {
    local token="$1"
    local workspace_id="$2"
    local response
    local http_code
    
    log_info "Deleting Fabric workspace: $workspace_id"
    
    response=$(curl -s -w "\n%{http_code}" -X DELETE \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    http_code=$(echo "$response" | tail -n1)
    
    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        log_success "Deleted workspace: $workspace_id"
        return 0
    else
        log_error "Failed to delete workspace (HTTP $http_code)"
        return 1
    fi
}

# List all workspaces
# Arguments: $1 = token
list_workspaces() {
    local token="$1"
    local response
    
    response=$(curl -s -X GET "${FABRIC_API_BASE}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    echo "$response" | jq '.value[] | {id, displayName, capacityId}' 2>/dev/null
}

# ============================================================================
# VALIDATION AND TEST FUNCTIONS
# ============================================================================

# Run all validation tests
# Arguments: $1 = token (optional, will get if not provided)
# Returns: 0 if all tests pass, 1 otherwise
run_fabric_validation() {
    local token="${1:-}"
    local test_workspace_name="aio-test-workspace-$(date +%s)"
    local test_eventhouse_name="aio-test-eventhouse"
    local test_database_name="aio-test-db"
    local test_eventstream_name="aio-test-eventstream"
    local workspace_id=""
    local eventhouse_id=""
    local database_id=""
    local eventstream_id=""
    local all_passed=true
    
    echo ""
    echo "=========================================="
    echo "  Fabric API Validation Tests"
    echo "=========================================="
    echo ""
    
    # Test 1: Get and validate token
    log_info "Test 1: Get and validate Fabric API token"
    if [[ -z "$token" ]]; then
        token=$(get_fabric_token) || { log_error "FAILED: Could not get token"; return 1; }
    fi
    validate_fabric_token "$token" || { log_error "FAILED: Token validation"; return 1; }
    log_success "PASSED: Token validation"
    
    # Test 2: Create workspace
    log_info "Test 2: Create Fabric workspace"
    workspace_id=$(create_fabric_workspace "$token" "$test_workspace_name") || {
        log_error "FAILED: Workspace creation"
        all_passed=false
    }
    if [[ -n "$workspace_id" ]]; then
        log_success "PASSED: Workspace creation (ID: $workspace_id)"
    fi
    
    if [[ -n "$workspace_id" ]]; then
        # Test 3: Create Eventhouse
        log_info "Test 3: Create Eventhouse"
        eventhouse_id=$(create_eventhouse "$token" "$workspace_id" "$test_eventhouse_name") || {
            log_error "FAILED: Eventhouse creation"
            all_passed=false
        }
        if [[ -n "$eventhouse_id" ]]; then
            log_success "PASSED: Eventhouse creation (ID: $eventhouse_id)"
        fi
        
        # Test 4: Create KQL Database
        if [[ -n "$eventhouse_id" ]]; then
            log_info "Test 4: Create KQL Database"
            database_id=$(create_kql_database "$token" "$workspace_id" "$test_database_name" "$eventhouse_id") || {
                log_error "FAILED: KQL Database creation"
                all_passed=false
            }
            if [[ -n "$database_id" ]]; then
                log_success "PASSED: KQL Database creation (ID: $database_id)"
            fi
        fi
        
        # Test 5: Create Eventstream
        log_info "Test 5: Create Eventstream"
        eventstream_id=$(create_eventstream "$token" "$workspace_id" "$test_eventstream_name") || {
            log_error "FAILED: Eventstream creation"
            all_passed=false
        }
        if [[ -n "$eventstream_id" ]]; then
            log_success "PASSED: Eventstream creation (ID: $eventstream_id)"
        fi
        
        # Test 6: Verify all items exist
        log_info "Test 6: Verify items exist in workspace"
        local items_response
        items_response=$(curl -s -X GET \
            "${FABRIC_API_BASE}/workspaces/${workspace_id}/items" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json")
        local item_count
        item_count=$(echo "$items_response" | jq '.value | length')
        log_info "Found $item_count items in workspace"
        
        # Cleanup - delete test workspace
        log_info "Cleanup: Deleting test workspace"
        delete_fabric_workspace "$token" "$workspace_id" || {
            log_warn "Could not delete test workspace - please delete manually: $test_workspace_name"
        }
    fi
    
    echo ""
    echo "=========================================="
    if [[ "$all_passed" == "true" ]]; then
        log_success "All validation tests PASSED"
        return 0
    else
        log_error "Some validation tests FAILED"
        return 1
    fi
}

# Quick connectivity test (no resource creation)
# Arguments: $1 = token (optional)
test_fabric_connectivity() {
    local token="${1:-}"
    
    log_info "Testing Fabric API connectivity..."
    
    if [[ -z "$token" ]]; then
        token=$(get_fabric_token) || {
            log_error "Failed to get Fabric API token"
            return 1
        }
    fi
    
    if validate_fabric_token "$token"; then
        log_success "Fabric API is accessible"
        
        # List existing workspaces as additional verification
        log_info "Listing existing workspaces..."
        local workspaces
        workspaces=$(list_workspaces "$token")
        if [[ -n "$workspaces" ]]; then
            echo "$workspaces"
        else
            log_info "No existing workspaces found (or empty list)"
        fi
        return 0
    else
        log_error "Fabric API connectivity test failed"
        return 1
    fi
}

# ============================================================================
# MAIN ENTRY POINT (for standalone testing)
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        test)
            test_fabric_connectivity
            ;;
        validate)
            run_fabric_validation
            ;;
        list)
            token=$(get_fabric_token)
            list_workspaces "$token"
            ;;
        *)
            echo "Usage: $0 {test|validate|list}"
            echo ""
            echo "Commands:"
            echo "  test      - Quick connectivity test (no resources created)"
            echo "  validate  - Full validation (creates and deletes test resources)"
            echo "  list      - List all accessible workspaces"
            exit 1
            ;;
    esac
fi
