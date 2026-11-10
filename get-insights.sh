#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: FABRIC_WORKSPACE_ID=<guid> FABRIC_BOOTSTRAP_SERVER=<host:port> \
       FABRIC_TOPIC=<topic> bash get-insights.sh [ops-resource-group]

The Fabric workspace, eventstream, custom endpoint, and managed-identity
workspace access must already exist. See the README for prerequisites.
EOF
}

error() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
  usage >&2
  exit 2
fi

OPS_RG="${1:-${OPS_RG:-rg-aioOps}}"
AIO_INSTANCE_NAME="${AIO_INSTANCE_NAME:-aio-k3s-instance}"
FABRIC_MI_NAME="${FABRIC_MI_NAME:-aio-k3s-cloud-mi}"
FABRIC_ENDPOINT_NAME="${FABRIC_ENDPOINT_NAME:-fabric-rti-endpoint}"
DATAFLOW_NAME="${DATAFLOW_NAME:-oven-to-fabric-rti}"
DATAFLOW_PROFILE="${DATAFLOW_PROFILE:-default}"
DATAFLOW_SOURCE_TOPIC="${DATAFLOW_SOURCE_TOPIC:-azure-iot-operations/data/oven}"

[[ -n "${FABRIC_WORKSPACE_ID:-}" ]] || error "Set FABRIC_WORKSPACE_ID to the existing workspace GUID."
[[ -n "${FABRIC_BOOTSTRAP_SERVER:-}" ]] || error "Set FABRIC_BOOTSTRAP_SERVER to the eventstream Kafka host and port."
[[ -n "${FABRIC_TOPIC:-}" ]] || error "Set FABRIC_TOPIC to the eventstream Kafka topic."
[[ "$FABRIC_WORKSPACE_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
  error "FABRIC_WORKSPACE_ID must be a GUID, not an Azure resource ID."
[[ "$FABRIC_BOOTSTRAP_SERVER" =~ ^[[:alnum:].-]+:[0-9]{1,5}$ ]] ||
  error "FABRIC_BOOTSTRAP_SERVER must be a hostname and port, without a URL scheme."
port="${FABRIC_BOOTSTRAP_SERVER##*:}"
(( 10#$port >= 1 && 10#$port <= 65535 )) || error "FABRIC_BOOTSTRAP_SERVER has an invalid port."

for command in az jq; do
  command -v "$command" >/dev/null 2>&1 || error "$command is required."
done

if ! workspace="$(az rest --method get \
  --url "https://api.fabric.microsoft.com/v1/workspaces/$FABRIC_WORKSPACE_ID" \
  --resource "https://api.fabric.microsoft.com" --output json)"; then
  error "Unable to access the Fabric workspace. Check the workspace ID, tenant, and permissions."
fi
workspace_id="$(jq -er '.id | strings | select(length > 0)' <<< "$workspace")" ||
  error "Fabric returned a workspace without an ID."
[[ "${workspace_id,,}" == "${FABRIC_WORKSPACE_ID,,}" ]] ||
  error "Fabric returned a different workspace ID."
workspace_type="$(jq -r '.type // empty' <<< "$workspace")"
[[ "$workspace_type" == "Workspace" ]] || error "A non-personal Fabric workspace is required."
capacity_id="$(jq -r '.capacityId // empty' <<< "$workspace")"
[[ -n "$capacity_id" ]] || error "Assign the Fabric workspace to a capacity or trial before continuing."

if ! identity="$(az identity show --name "$FABRIC_MI_NAME" --resource-group "$OPS_RG" --output json)"; then
  error "Unable to find managed identity $FABRIC_MI_NAME in $OPS_RG."
fi
identity_id="$(jq -er '.id | strings | select(length > 0)' <<< "$identity")" ||
  error "The managed identity response does not contain a resource ID."
client_id="$(jq -er '.clientId | strings | select(length > 0)' <<< "$identity")" ||
  error "The managed identity response does not contain a client ID."
tenant_id="$(az account show --query tenantId --output tsv)" || error "Unable to determine the Azure tenant."
[[ -n "$tenant_id" ]] || error "The Azure account did not return a tenant ID."
az iot ops show --name "$AIO_INSTANCE_NAME" --resource-group "$OPS_RG" --output none ||
  error "Unable to access Azure IoT Operations instance $AIO_INSTANCE_NAME."

config_file="$(mktemp --suffix=.json)"
trap 'rm -f -- "$config_file"' EXIT
jq -n --arg source "$DATAFLOW_SOURCE_TOPIC" --arg endpoint "$FABRIC_ENDPOINT_NAME" --arg topic "$FABRIC_TOPIC" '
  {
    mode: "Enabled",
    operations: [
      {operationType: "Source", sourceSettings: {endpointRef: "default", dataSources: [$source]}},
      {operationType: "Destination", destinationSettings: {endpointRef: $endpoint, dataDestination: $topic}}
    ]
  }
' > "$config_file"

echo "Validated Fabric workspace $workspace_id. Configuring Azure IoT Operations..."
az iot ops identity assign --name "$AIO_INSTANCE_NAME" --resource-group "$OPS_RG" \
  --mi-user-assigned "$identity_id" --usage dataflow --output none
az iot ops dataflow endpoint create fabric-realtime \
  --resource-group "$OPS_RG" --instance "$AIO_INSTANCE_NAME" --name "$FABRIC_ENDPOINT_NAME" \
  --host "$FABRIC_BOOTSTRAP_SERVER" --auth-type UserAssignedManagedIdentity \
  --client-id "$client_id" --tenant-id "$tenant_id" --output none
az iot ops dataflow apply --resource-group "$OPS_RG" --instance "$AIO_INSTANCE_NAME" \
  --profile "$DATAFLOW_PROFILE" --name "$DATAFLOW_NAME" --config-file "$config_file" --output none

echo "Fabric endpoint and data flow configured. Verify messages in the Fabric eventstream."
