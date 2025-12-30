#!/usr/bin/env bash
# fabric-eventstream-setup.sh - Configure Eventstream with Custom App source and KQL destination
# This handles the complex setup that the basic Fabric API can't fully automate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fabric-api.sh"

# Fabric API base
FABRIC_API_BASE="https://api.fabric.microsoft.com/v1"

# ============================================================================
# EVENTSTREAM CONFIGURATION
# ============================================================================

# Get Eventstream details including the ingestion endpoint
# This requires querying the Eventstream item definition
# Arguments: $1 = token, $2 = workspace_id, $3 = eventstream_id
get_eventstream_details() {
    local token="$1"
    local workspace_id="$2"
    local eventstream_id="$3"
    
    log_info "Getting Eventstream details..."
    
    # Get item definition which may contain connection info
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" -X GET \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items/${eventstream_id}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        echo "$body" | jq '.'
        return 0
    else
        log_error "Failed to get Eventstream details (HTTP $http_code)"
        echo "$body"
        return 1
    fi
}

# Get Eventstream definition (for advanced configuration)
# Arguments: $1 = token, $2 = workspace_id, $3 = eventstream_id
get_eventstream_definition() {
    local token="$1"
    local workspace_id="$2"
    local eventstream_id="$3"
    
    log_info "Getting Eventstream definition..."
    
    local response
    local http_code
    
    # The getDefinition API returns the Eventstream configuration
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items/${eventstream_id}/getDefinition" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        echo "$body"
        return 0
    elif [[ "$http_code" == "202" ]]; then
        # Async - need to poll
        log_info "Definition retrieval in progress..."
        sleep 5
        # For now just return what we have
        echo "$body"
        return 0
    else
        log_warn "Could not get Eventstream definition (HTTP $http_code)"
        log_warn "This may require manual configuration in Fabric portal"
        return 1
    fi
}

# Update Eventstream definition to add Custom App source
# NOTE: This is complex and may not be fully supported via API
# Arguments: $1 = token, $2 = workspace_id, $3 = eventstream_id, $4 = source_name
configure_eventstream_custom_source() {
    local token="$1"
    local workspace_id="$2"
    local eventstream_id="$3"
    local source_name="${4:-aio-custom-input}"
    
    log_info "Configuring Custom App source on Eventstream..."
    log_warn "NOTE: Eventstream source configuration via API has limitations"
    log_warn "You may need to complete this step in Fabric portal"
    
    # The Fabric API for Eventstream configuration is limited
    # Most source/destination setup requires the portal
    
    # What we CAN do is provide instructions and check readiness
    echo ""
    echo "Manual steps required in Fabric portal:"
    echo "1. Open the Eventstream in Fabric portal"
    echo "2. Click 'New source' → 'Custom App'"
    echo "3. Configure with these settings:"
    echo "   - Source name: $source_name"
    echo "   - Authentication: Shared Access Key or Managed Identity"
    echo "4. Copy the Event Hub-compatible endpoint"
    echo ""
    
    return 0
}

# ============================================================================
# KQL DATABASE TABLE SETUP
# ============================================================================

# Create KQL table for oven telemetry using the KQL API
# Arguments: $1 = token, $2 = workspace_id, $3 = database_id
create_oven_telemetry_table() {
    local token="$1"
    local workspace_id="$2"
    local database_id="$3"
    local database_name="${4:-aio-rti-db}"
    
    log_info "Creating OvenTelemetry table in KQL database..."
    
    # KQL query to create table
    local kql_command=".create-merge table OvenTelemetry (
    timestamp: datetime,
    temperature: real,
    weight: real,
    energy_use: real,
    source_topic: string
) with (folder = 'AIO')"

    # The Fabric API for executing KQL commands
    local response
    local http_code
    
    # Use the KQL query execution endpoint
    # Note: This requires the Eventhouse/KQL Database to support query execution
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/items/${database_id}/executeCommand" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg cmd "$kql_command" '{command: $cmd}')")
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" || "$http_code" == "202" ]]; then
        log_success "OvenTelemetry table created/updated"
        return 0
    else
        log_warn "Could not create table via API (HTTP $http_code)"
        log_warn "Table creation may need to be done via KQL queryset"
        echo ""
        echo "Run this KQL command in a Fabric KQL Queryset:"
        echo "─────────────────────────────────────────────"
        echo "$kql_command"
        echo "─────────────────────────────────────────────"
        return 1
    fi
}

# Create ingestion mapping for JSON data
# Arguments: $1 = token, $2 = workspace_id, $3 = database_id
create_ingestion_mapping() {
    local token="$1"
    local workspace_id="$2"
    local database_id="$3"
    
    log_info "Creating JSON ingestion mapping..."
    
    local kql_command=".create-or-alter table OvenTelemetry ingestion json mapping 'OvenTelemetryMapping' '[
    {\"column\":\"timestamp\", \"path\":\"\$.timestamp\", \"datatype\":\"datetime\"},
    {\"column\":\"temperature\", \"path\":\"\$.temperature\", \"datatype\":\"real\"},
    {\"column\":\"weight\", \"path\":\"\$.weight\", \"datatype\":\"real\"},
    {\"column\":\"energy_use\", \"path\":\"\$.energy_use\", \"datatype\":\"real\"},
    {\"column\":\"source_topic\", \"path\":\"\$.source_topic\", \"datatype\":\"string\"}
]'"

    echo ""
    echo "Run this KQL command to create the ingestion mapping:"
    echo "─────────────────────────────────────────────────────"
    echo "$kql_command"
    echo "─────────────────────────────────────────────────────"
    
    return 0
}

# ============================================================================
# RBAC SETUP FOR MANAGED IDENTITY
# ============================================================================

# Get the Arc cluster's managed identity
# Arguments: $1 = cluster_name, $2 = resource_group
get_arc_cluster_identity() {
    local cluster_name="$1"
    local resource_group="$2"
    
    log_info "Getting Arc cluster managed identity..."
    
    local identity_id
    identity_id=$(az connectedk8s show \
        --name "$cluster_name" \
        --resource-group "$resource_group" \
        --query "identity.principalId" -o tsv 2>/dev/null)
    
    if [[ -n "$identity_id" ]]; then
        log_success "Found Arc cluster identity: $identity_id"
        echo "$identity_id"
        return 0
    else
        log_error "Could not get Arc cluster identity"
        return 1
    fi
}

# Assign Fabric permissions to the Arc cluster identity
# NOTE: This requires Fabric admin permissions
# Arguments: $1 = workspace_id, $2 = identity_principal_id
assign_fabric_permissions() {
    local workspace_id="$1"
    local principal_id="$2"
    local token="$3"
    
    log_info "Assigning workspace permissions to Arc cluster identity..."
    
    # Add the service principal as a workspace contributor
    local response
    local http_code
    
    local payload
    payload=$(jq -n \
        --arg pid "$principal_id" \
        '{
            principal: {
                id: $pid,
                type: "ServicePrincipal"
            },
            role: "Contributor"
        }')
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${FABRIC_API_BASE}/workspaces/${workspace_id}/roleAssignments" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
        log_success "Workspace permissions assigned"
        return 0
    elif [[ "$http_code" == "409" ]]; then
        log_info "Permission already exists"
        return 0
    else
        log_error "Failed to assign permissions (HTTP $http_code): $body"
        log_warn "You may need to manually add the Arc cluster identity to the workspace"
        return 1
    fi
}

# ============================================================================
# EVENT HUB NAMESPACE INFO (for connection string format)
# ============================================================================

# Parse Event Hub compatible connection string format
# Eventstream exposes an Event Hub-compatible endpoint
parse_eventhub_connection() {
    local connection_string="$1"
    
    # Connection string format:
    # Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<name>;SharedAccessKey=<key>;EntityPath=<eventhub>
    
    local endpoint
    local namespace
    local entity_path
    
    endpoint=$(echo "$connection_string" | grep -oP 'Endpoint=sb://\K[^/]+' || echo "")
    entity_path=$(echo "$connection_string" | grep -oP 'EntityPath=\K[^;]+' || echo "")
    
    echo "Namespace: $endpoint"
    echo "Entity Path: $entity_path"
}

# Generate the Kafka bootstrap server from Eventstream
# Eventstream provides Kafka-compatible endpoints on port 9093
get_kafka_bootstrap_server() {
    local eventstream_namespace="$1"
    
    # Fabric Eventstream uses this format for Kafka
    echo "${eventstream_namespace}:9093"
}

# ============================================================================
# FULL SETUP WIZARD
# ============================================================================

run_eventstream_setup_wizard() {
    local token="${1:-}"
    local workspace_id="${2:-}"
    local eventstream_id="${3:-}"
    local database_id="${4:-}"
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║           Eventstream Setup Wizard                                    ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ -z "$token" ]]; then
        log_info "Getting Fabric API token..."
        token=$(get_fabric_token) || {
            log_error "Failed to get token"
            return 1
        }
    fi
    
    # Step 1: Get Eventstream details
    if [[ -n "$workspace_id" && -n "$eventstream_id" ]]; then
        log_step "Step 1: Getting Eventstream details..."
        get_eventstream_details "$token" "$workspace_id" "$eventstream_id" || true
        echo ""
    fi
    
    # Step 2: Provide manual instructions for Custom App setup
    log_step "Step 2: Custom App Source Configuration"
    configure_eventstream_custom_source "$token" "$workspace_id" "$eventstream_id"
    echo ""
    
    # Step 3: KQL Table creation
    if [[ -n "$database_id" ]]; then
        log_step "Step 3: KQL Table Setup"
        create_oven_telemetry_table "$token" "$workspace_id" "$database_id" || true
        echo ""
        create_ingestion_mapping "$token" "$workspace_id" "$database_id"
        echo ""
    fi
    
    # Step 4: Summary
    log_step "Step 4: Next Steps Summary"
    echo ""
    echo "To complete the Fabric RTI integration:"
    echo ""
    echo "1. IN FABRIC PORTAL:"
    echo "   a. Open your Eventstream"
    echo "   b. Add 'Custom App' as source → Get the connection string"
    echo "   c. Add 'KQL Database' as destination → Select your database"
    echo "   d. Configure the data mapping"
    echo ""
    echo "2. ON THE AIO VM:"
    echo "   a. Create the AIO dataflow endpoint with the Eventstream connection"
    echo "   b. Deploy the dataflow to start sending data"
    echo ""
    echo "3. VERIFY:"
    echo "   a. Check Eventstream is receiving data"
    echo "   b. Query the KQL database for oven telemetry"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        wizard)
            run_eventstream_setup_wizard "${2:-}" "${3:-}" "${4:-}" "${5:-}"
            ;;
        get-details)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                echo "Usage: $0 get-details <workspace_id> <eventstream_id>"
                exit 1
            fi
            token=$(get_fabric_token)
            get_eventstream_details "$token" "$2" "$3"
            ;;
        get-definition)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                echo "Usage: $0 get-definition <workspace_id> <eventstream_id>"
                exit 1
            fi
            token=$(get_fabric_token)
            get_eventstream_definition "$token" "$2" "$3"
            ;;
        create-table)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                echo "Usage: $0 create-table <workspace_id> <database_id>"
                exit 1
            fi
            token=$(get_fabric_token)
            create_oven_telemetry_table "$token" "$2" "$3"
            create_ingestion_mapping "$token" "$2" "$3"
            ;;
        assign-rbac)
            if [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
                echo "Usage: $0 assign-rbac <workspace_id> <cluster_name> <resource_group>"
                exit 1
            fi
            token=$(get_fabric_token)
            principal_id=$(get_arc_cluster_identity "$3" "$4")
            assign_fabric_permissions "$2" "$principal_id" "$token"
            ;;
        *)
            echo "Eventstream Setup Utilities"
            echo ""
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  wizard                              - Interactive setup wizard"
            echo "  get-details <ws_id> <es_id>         - Get Eventstream details"
            echo "  get-definition <ws_id> <es_id>      - Get Eventstream definition"
            echo "  create-table <ws_id> <db_id>        - Create KQL table for oven data"
            echo "  assign-rbac <ws_id> <cluster> <rg>  - Assign RBAC for Arc cluster"
            echo ""
            echo "NOTE: Some Eventstream configuration requires Fabric portal."
            echo "      This tool provides guidance and automates what's possible via API."
            exit 1
            ;;
    esac
fi
