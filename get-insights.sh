#!/usr/bin/env bash
set -euo pipefail

# This script sets up a Fabric RTI data flow endpoint in Azure IoT Operations and integrates the oven asset with it.
# Prerequisites: AIO instance deployed with secure settings, Fabric workspace and RTI endpoint created, and required secrets in Key Vault.

# User-editable variables (override with env or edit here)
OPS_RG="rg-aioOps"
AIO_INSTANCE_NAME="aio-k3s-instance"
AIO_NAMESPACE="myqsnamespace"
OVEN_ASSET_NAME="oven"
FABRIC_WORKSPACE_ID="<your-fabric-workspace-id>"   # e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Fabric/workspaces/<name>
FABRIC_RTI_ENDPOINT="<your-fabric-rti-endpoint>"   # e.g. https://<rti>.fabric.microsoft.com/api/...
FABRIC_MI_NAME="aio-k3s-cloud-mi"                  # The managed identity assigned for cloud connections
KEYVAULT_NAME="aiokv$(date +%s)"                   # Or your actual Key Vault name
SECRET_NAME="<your-fabric-secret-name>"            # The secret synced from Key Vault

# --- Fabric workspace and RTI endpoint automation ---

FABRIC_RG="$OPS_RG"  # Use same RG for simplicity
FABRIC_WORKSPACE_NAME="aio-fabric-ws"
FABRIC_LOCATION="eastus2"
FABRIC_RTI_NAME="aio-fabric-rti"

# Register Microsoft.Fabric provider if needed
if ! az provider show -n Microsoft.Fabric --query registrationState -o tsv | grep -q Registered; then
  echo "Registering Microsoft.Fabric resource provider..."
  az provider register -n Microsoft.Fabric
  echo "Waiting for Microsoft.Fabric provider registration..."
  for i in {1..20}; do
    state=$(az provider show -n Microsoft.Fabric --query registrationState -o tsv)
    if [[ "$state" == "Registered" ]]; then break; fi
    sleep 10
  done
fi

# Create Fabric workspace (lowest SKU)
if ! az resource show -g "$FABRIC_RG" -n "$FABRIC_WORKSPACE_NAME" --resource-type "Microsoft.Fabric/workspaces" >/dev/null 2>&1; then
  echo "Creating Fabric workspace..."
  az resource create \
    --resource-group "$FABRIC_RG" \
    --name "$FABRIC_WORKSPACE_NAME" \
    --resource-type "Microsoft.Fabric/workspaces" \
    --location "$FABRIC_LOCATION" \
    --properties '{"sku":{"name":"F2"}}'
fi
FABRIC_WORKSPACE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$FABRIC_RG/providers/Microsoft.Fabric/workspaces/$FABRIC_WORKSPACE_NAME"

echo "Fabric workspace created: $FABRIC_WORKSPACE_ID"

# --- Auto-generate RTI endpoint URL after workspace creation ---
# (This is a placeholder. Replace with actual RTI endpoint creation logic if/when CLI support is available.)
FABRIC_RTI_ENDPOINT="https://${FABRIC_RTI_NAME}.${FABRIC_LOCATION}.fabric.microsoft.com/api/endpoint"
SECRET_NAME="fabric-rti-secret"

# Get resource IDs
FABRIC_MI_ID=$(az identity show --name "$FABRIC_MI_NAME" --resource-group "$OPS_RG" --query id -o tsv)
AIO_INSTANCE_ID=$(az iot ops show -g "$OPS_RG" -n "$AIO_INSTANCE_NAME" --query id -o tsv)

# Create the Fabric RTI data flow endpoint in AIO
az iot ops dataflow endpoint create \
  --instance "$AIO_INSTANCE_NAME" \
  --resource-group "$OPS_RG" \
  --name "fabric-rti-endpoint" \
  --type fabric-rti \
  --url "$FABRIC_RTI_ENDPOINT" \
  --mi-user-assigned "$FABRIC_MI_ID" \
  --secret-name "$SECRET_NAME" \
  --namespace "$AIO_NAMESPACE" \
  --description "Data flow from oven asset to Fabric RTI endpoint"

echo "Fabric RTI data flow endpoint created."

# Integrate the oven asset with the Fabric RTI endpoint
echo "Integrating oven asset with Fabric RTI endpoint..."
az iot ops dataflow create \
  --instance "$AIO_INSTANCE_NAME" \
  --resource-group "$OPS_RG" \
  --name "oven-to-fabric-rti" \
  --source-asset "$OVEN_ASSET_NAME" \
  --target-endpoint "fabric-rti-endpoint" \
  --namespace "$AIO_NAMESPACE" \
  --description "Connect oven asset to Fabric RTI endpoint"

echo "Oven asset is now integrated with Fabric RTI endpoint."
