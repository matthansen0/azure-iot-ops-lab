#!/usr/bin/env bash
set -euo pipefail

# This script helps you get started with the "Get Insights" step from the Azure IoT Operations tutorial.
# It will check for required extensions, help you find your Log Analytics workspace, and run a sample query.

# Prerequisites: az login, jq

RESOURCE_GROUP="${1:-rg-aioOps}"

# Check for required extensions
az extension add --name azure-iot-ops --upgrade --allow-preview true -y
# Ensure log-analytics extension is installed (allow preview)
if ! az extension show --name log-analytics &>/dev/null; then
  az extension add --name log-analytics --allow-preview true -y
else
  az extension update --name log-analytics --allow-preview true -y
fi

# Find Log Analytics workspace in the resource group

WORKSPACE_NAME="aio-laworkspace"
WORKSPACE_ID=$(az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" --query "customerId" -o tsv 2>/dev/null)
if [[ -z "$WORKSPACE_ID" ]]; then
  echo "Log Analytics workspace '$WORKSPACE_NAME' not found in $RESOURCE_GROUP. Please check your deployment."
  exit 1
fi

echo "Found Log Analytics workspace: $WORKSPACE_ID"

echo "Running sample query for IoT Operations logs..."
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "IoTOperationsLogs | sort by TimeGenerated desc | limit 10" \
  --output table

echo "\nFor more, see: https://learn.microsoft.com/en-us/azure/iot-operations/end-to-end-tutorials/tutorial-get-insights"
