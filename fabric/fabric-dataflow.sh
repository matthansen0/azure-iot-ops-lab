#!/usr/bin/env bash
# fabric-dataflow.sh - Configure AIO dataflow to send oven data to Fabric Real-Time Intelligence
# This module creates the dataflow configuration to stream data from the oven asset to Fabric Eventstream

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fabric-api.sh"

# ============================================================================
# AIO DATAFLOW CONFIGURATION FOR FABRIC RTI
# ============================================================================

# Generate AIO dataflow YAML for Fabric Eventstream destination
# Arguments: $1 = dataflow_name, $2 = eventstream_endpoint, $3 = eventstream_name
# Returns: YAML configuration string
generate_fabric_dataflow_yaml() {
    local dataflow_name="$1"
    local eventstream_endpoint="$2"
    local eventstream_name="$3"
    
    cat <<EOF
apiVersion: connectivity.iotoperations.azure.com/v1
kind: Dataflow
metadata:
  name: ${dataflow_name}
  namespace: azure-iot-operations
spec:
  profileRef: default
  mode: Enabled
  operations:
    - operationType: Source
      sourceSettings:
        endpointRef: default
        dataSources:
          - azure-iot-operations/data/oven
    - operationType: BuiltInTransformation
      builtInTransformationSettings:
        serializationFormat: Json
        datasets: []
        filter: []
        map:
          - inputs:
              - 'Temperature'
            output: temperature
          - inputs:
              - 'Weight'
            output: weight
          - inputs:
              - 'EnergyUse'
            output: energy_use
          - inputs:
              - '\$metadata.time'
            output: timestamp
          - inputs:
              - '\$metadata.topic'
            output: source_topic
    - operationType: Destination
      destinationSettings:
        endpointRef: fabric-eventstream-endpoint
        dataDestination: ${eventstream_name}
EOF
}

# Generate the DataflowEndpoint for Fabric Eventstream (Custom MQTT/Kafka endpoint)
# Arguments: $1 = endpoint_name, $2 = eventstream_connection_string
generate_eventstream_endpoint_yaml() {
    local endpoint_name="$1"
    local eventstream_host="$2"
    local eventstream_port="${3:-9093}"
    
    cat <<EOF
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowEndpoint
metadata:
  name: ${endpoint_name}
  namespace: azure-iot-operations
spec:
  endpointType: Kafka
  kafkaSettings:
    host: "${eventstream_host}:${eventstream_port}"
    authentication:
      method: SystemAssignedManagedIdentity
      systemAssignedManagedIdentitySettings:
        audience: "https://eventhubs.azure.net"
    tls:
      mode: Enabled
    consumerGroupId: aio-consumer
    batching:
      mode: Enabled
      latencyMs: 1000
      maxMessages: 100
EOF
}

# Create secrets for Eventstream connection (if using SAS)
# Arguments: $1 = secret_name, $2 = connection_string
create_eventstream_secret() {
    local secret_name="$1"
    local connection_string="$2"
    
    log_info "Creating Kubernetes secret for Eventstream connection..."
    
    kubectl create secret generic "$secret_name" \
        --namespace azure-iot-operations \
        --from-literal=connection-string="$connection_string" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Created secret: $secret_name"
}

# Deploy the dataflow configuration to the AIO cluster
# Arguments: $1 = dataflow_yaml_file
deploy_dataflow() {
    local yaml_file="$1"
    
    log_info "Deploying AIO dataflow configuration..."
    
    if kubectl apply -f "$yaml_file"; then
        log_success "Dataflow deployed successfully"
        return 0
    else
        log_error "Failed to deploy dataflow"
        return 1
    fi
}

# Validate that the oven data source exists
validate_oven_source() {
    log_info "Validating oven data source exists..."
    
    # Check if the OPC PLC simulator is running
    if kubectl get deployment opc-plc-deployment -n azure-iot-operations &>/dev/null; then
        log_success "OPC PLC simulator deployment found"
    else
        log_warn "OPC PLC simulator deployment not found - data source may not be available"
    fi
    
    # Check for asset endpoints
    if kubectl get assetendpointprofiles -n azure-iot-operations 2>/dev/null | grep -q opc; then
        log_success "OPC asset endpoint profile found"
        return 0
    else
        log_warn "OPC asset endpoint profile not found"
        return 1
    fi
}

# Get the oven asset details
get_oven_asset_info() {
    log_info "Getting oven asset information..."
    
    kubectl get assets -n azure-iot-operations -o json 2>/dev/null | \
        jq '.items[] | select(.metadata.name | contains("oven")) | {name: .metadata.name, endpoint: .spec.assetEndpointProfileRef}' || \
        log_warn "No oven asset found"
}

# Verify dataflow is running
verify_dataflow_status() {
    local dataflow_name="$1"
    local timeout="${2:-60}"
    local elapsed=0
    local interval=5
    
    log_info "Verifying dataflow status: $dataflow_name"
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(kubectl get dataflow "$dataflow_name" -n azure-iot-operations -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [[ "$status" == "Running" ]]; then
            log_success "Dataflow is running"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            log_error "Dataflow failed to start"
            kubectl get dataflow "$dataflow_name" -n azure-iot-operations -o yaml
            return 1
        fi
        
        log_info "Dataflow status: $status (waiting...)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for dataflow to start"
    return 1
}

# ============================================================================
# FULL DEPLOYMENT FUNCTION
# ============================================================================

# Deploy complete Fabric RTI integration
# Arguments: $1 = fabric_workspace_name, $2 = eventhouse_name, $3 = database_name, $4 = eventstream_name
deploy_fabric_rti_integration() {
    local workspace_name="${1:-aio-fabric-workspace}"
    local eventhouse_name="${2:-aio-eventhouse}"
    local database_name="${3:-aio-rti-db}"
    local eventstream_name="${4:-aio-eventstream}"
    local dataflow_name="oven-to-fabric-dataflow"
    
    echo ""
    echo "=========================================="
    echo "  Deploying Fabric RTI Integration"
    echo "=========================================="
    echo ""
    
    # Step 1: Get Fabric token
    log_info "Step 1: Authenticating with Fabric API..."
    local token
    token=$(get_fabric_token) || {
        log_error "Failed to get Fabric token"
        return 1
    }
    
    # Step 2: Create Fabric workspace
    log_info "Step 2: Creating Fabric workspace..."
    local workspace_id
    workspace_id=$(create_fabric_workspace "$token" "$workspace_name") || {
        log_error "Failed to create workspace"
        return 1
    }
    
    # Step 3: Create Eventhouse
    log_info "Step 3: Creating Eventhouse..."
    local eventhouse_id
    eventhouse_id=$(create_eventhouse "$token" "$workspace_id" "$eventhouse_name") || {
        log_error "Failed to create Eventhouse"
        return 1
    }
    
    # Step 4: Create KQL Database
    log_info "Step 4: Creating KQL Database..."
    local database_id
    database_id=$(create_kql_database "$token" "$workspace_id" "$database_name" "$eventhouse_id") || {
        log_error "Failed to create KQL Database"
        return 1
    }
    
    # Step 5: Create Eventstream
    log_info "Step 5: Creating Eventstream..."
    local eventstream_id
    eventstream_id=$(create_eventstream "$token" "$workspace_id" "$eventstream_name") || {
        log_error "Failed to create Eventstream"
        return 1
    }
    
    # Step 6: Get Eventstream connection info
    log_info "Step 6: Getting Eventstream connection details..."
    # Note: In a real deployment, you would get the actual connection endpoint from the Eventstream
    # For now, we'll output the IDs for manual configuration or future automation
    
    echo ""
    echo "=========================================="
    log_success "Fabric RTI Infrastructure Created!"
    echo "=========================================="
    echo ""
    echo "Resources created:"
    echo "  Workspace:    $workspace_name (ID: $workspace_id)"
    echo "  Eventhouse:   $eventhouse_name (ID: $eventhouse_id)"
    echo "  KQL Database: $database_name (ID: $database_id)"
    echo "  Eventstream:  $eventstream_name (ID: $eventstream_id)"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Eventstream custom endpoint in Fabric portal"
    echo "  2. Get the Event Hub compatible connection string"
    echo "  3. Configure AIO dataflow with the endpoint"
    echo ""
    
    # Export for use by other scripts
    export FABRIC_WORKSPACE_ID="$workspace_id"
    export FABRIC_EVENTHOUSE_ID="$eventhouse_id"
    export FABRIC_DATABASE_ID="$database_id"
    export FABRIC_EVENTSTREAM_ID="$eventstream_id"
    
    return 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        deploy)
            deploy_fabric_rti_integration "${2:-}" "${3:-}" "${4:-}" "${5:-}"
            ;;
        validate-source)
            validate_oven_source
            get_oven_asset_info
            ;;
        verify-dataflow)
            verify_dataflow_status "${2:-oven-to-fabric-dataflow}"
            ;;
        generate-dataflow)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                echo "Usage: $0 generate-dataflow <eventstream_endpoint> <eventstream_name>"
                exit 1
            fi
            generate_fabric_dataflow_yaml "oven-to-fabric-dataflow" "$2" "$3"
            ;;
        generate-endpoint)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 generate-endpoint <eventstream_host> [port]"
                exit 1
            fi
            generate_eventstream_endpoint_yaml "fabric-eventstream-endpoint" "$2" "${3:-9093}"
            ;;
        *)
            echo "Usage: $0 {deploy|validate-source|verify-dataflow|generate-dataflow|generate-endpoint}"
            echo ""
            echo "Commands:"
            echo "  deploy                        - Deploy full Fabric RTI integration"
            echo "  validate-source               - Validate oven data source exists"
            echo "  verify-dataflow <name>        - Verify dataflow status"
            echo "  generate-dataflow <ep> <name> - Generate dataflow YAML"
            echo "  generate-endpoint <host>      - Generate endpoint YAML"
            exit 1
            ;;
    esac
fi
