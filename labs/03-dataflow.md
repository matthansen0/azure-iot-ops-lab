# Lab 3: Create a Data Flow

Data flows route, transform, and deliver data from edge sources (like the OPC PLC simulator) to cloud destinations. This lab walks through creating a data flow using the Azure IoT Operations portal experience.

## Prerequisites

- Completed deployment with AIO instance running
- Access to the [Azure Portal](https://portal.azure.com)
- An Azure Event Hubs namespace (created in this lab)

## Background

The quickstart Bicep already deployed a basic data flow from the OPC PLC simulator to the local MQTT broker. In this lab, you'll create an additional data flow that routes data to Azure Event Hubs.

## 1. Review Existing Data Flows in the Portal

1. Open the [Azure Portal](https://portal.azure.com) and navigate to your ops resource group (default: **rg-aioOps**).
2. Click the **Azure IoT Operations** instance.
3. In the left nav, click **Data flow profiles** — you should see the default profile.
4. Click the default profile to view its existing data flows.
5. In the left nav, click **Data flow endpoints** — you should see the `default` local MQTT endpoint.

## 2. Create an Event Hubs Destination

Before creating the data flow, set up the cloud destination:

1. In the Azure Portal, search for **Event Hubs** in the top search bar.
2. Click **+ Create**.
3. Fill in:
   - **Resource group**: your ops resource group (e.g., `rg-aioOps`)
   - **Namespace name**: `<CLUSTER_NAME>-ehns` (e.g., `aio-k3s-ehns`)
   - **Location**: same as your deployment
   - **Pricing tier**: Standard
4. Click **Review + create**, then **Create**.
5. Once deployed, open the Event Hubs namespace.
6. Click **+ Event Hub** to create a new hub:
   - **Name**: `opc-data`
   - Leave defaults for partition count and retention
7. Click **Create**.

## 3. Assign Permissions to the AIO Extension Identity

The AIO extension's managed identity needs the **Azure Event Hubs Data Sender** role on the Event Hubs namespace:

1. In the Azure Portal, open your **Event Hubs namespace**.
2. In the left nav, click **Access control (IAM)**.
3. Click **+ Add** > **Add role assignment**.
4. On the **Role** tab, search for and select **Azure Event Hubs Data Sender**. Click **Next**.
5. On the **Members** tab:
   - Select **Managed identity**.
   - Click **+ Select members**.
   - Set **Managed identity** to **Extension** (under Kubernetes — Azure Arc).
   - Select the IoT Operations extension identity.
   - Click **Select**, then **Next**.
6. Click **Review + assign**.

## 4. Create the Data Flow Endpoint (Portal)

1. Navigate back to your **Azure IoT Operations** instance.
2. In the left nav, click **Data flow endpoints**.
3. Click **+ Create data flow endpoint**.
4. Fill in:
   - **Name**: `eventhub-endpoint`
   - **Endpoint type**: Kafka (Event Hubs uses the Kafka protocol)
   - **Host**: `<NAMESPACE_NAME>.servicebus.windows.net:9093` (your Event Hubs namespace FQDN)
   - **Authentication**: System-assigned managed identity
   - **Kafka topic**: `opc-data`
5. Click **Create**.

## 5. Create the Data Flow (Portal)

1. In the left nav of the AIO instance, click **Data flow profiles**.
2. Click the default profile.
3. Click **+ Create data flow** (or use the no-code **data flow graph** editor).
4. Configure the data flow:
   - **Name**: `opc-to-eventhub`
   - **Source**:
     - **Endpoint**: `default` (local MQTT broker)
     - **Data source topic**: `azure-iot-operations/data/#`
   - **Destination**:
     - **Endpoint**: `eventhub-endpoint`
     - **Data destination**: `opc-data`
5. Click **Create**.

> **Tip:** AIO 2603 introduced [no-code data flow graphs](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-create-dataflow-graph) — a visual drag-and-drop editor for building data flows directly in the portal.

## 6. Validate

1. After creating the data flow, navigate to **Data flow profiles** > default profile in the AIO instance.
2. You should see `opc-to-eventhub` listed with status **Running**.
3. Open the **Event Hubs namespace** in the portal:
   - Click the `opc-data` event hub.
   - On the **Overview** page, check the **Incoming Messages** chart — you should see messages arriving within 1–2 minutes.

## 7. (Optional) CLI Alternative

If you prefer the CLI, SSH into the VM and run:

```bash
sudo -i
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
source /etc/aio.env
INST_NAME="${CLUSTER_NAME}-instance"

# List existing data flows and endpoints
az iot ops dataflow profile list -g "$OPS_RG" --instance "$INST_NAME" -o table
az iot ops dataflow endpoint list -g "$OPS_RG" --instance "$INST_NAME" -o table

# Create Event Hubs namespace + hub
EH_NAMESPACE="${CLUSTER_NAME}-ehns"
az eventhubs namespace create --name "$EH_NAMESPACE" -g "$OPS_RG" --location "$LOCATION" --sku Standard -o none
az eventhubs eventhub create --name "opc-data" --namespace-name "$EH_NAMESPACE" -g "$OPS_RG" -o none

# Get Event Hubs host
EH_HOST=$(az eventhubs namespace show --name "$EH_NAMESPACE" -g "$OPS_RG" \
  --query serviceBusEndpoint -o tsv | sed 's|https://||;s|:443/||')

# Assign role to AIO extension identity
EXT_NAME=$(az k8s-extension list -g "$OPS_RG" \
  --cluster-name "$CLUSTER_NAME" --cluster-type connectedClusters \
  --query "[?extensionType == 'microsoft.iotoperations'].name | [0]" -o tsv)
EXT_PRINCIPAL_ID=$(az k8s-extension show -g "$OPS_RG" \
  --cluster-name "$CLUSTER_NAME" --cluster-type connectedClusters \
  --name "$EXT_NAME" --query "identity.principalId" -o tsv)
EH_RESOURCE_ID=$(az eventhubs namespace show --name "$EH_NAMESPACE" -g "$OPS_RG" --query id -o tsv)
az role assignment create --assignee-object-id "$EXT_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Event Hubs Data Sender" --scope "$EH_RESOURCE_ID" -o none

# Create endpoint and data flow
az iot ops dataflow endpoint create eventhub \
  -g "$OPS_RG" --instance "$INST_NAME" \
  --name "eventhub-endpoint" --eh-namespace-host "$EH_HOST" --kafka-topic "opc-data"

PROFILE_NAME=$(az iot ops dataflow profile list -g "$OPS_RG" --instance "$INST_NAME" --query "[0].name" -o tsv)
cat <<EOF > /tmp/dataflow-to-eh.yaml
{
  "properties": {
    "profileRef": "$PROFILE_NAME",
    "operations": [
      {
        "operationType": "Source",
        "sourceSettings": {
          "endpointRef": "default",
          "dataSources": ["azure-iot-operations/data/#"]
        }
      },
      {
        "operationType": "Destination",
        "destinationSettings": {
          "endpointRef": "eventhub-endpoint",
          "dataDestination": "opc-data"
        }
      }
    ]
  }
}
EOF

az iot ops dataflow apply \
  -g "$OPS_RG" --instance "$INST_NAME" \
  --profile "$PROFILE_NAME" --name "opc-to-eventhub" \
  --config-file /tmp/dataflow-to-eh.yaml
```

## Next Steps

- [Lab 4: Cleanup](04-cleanup.md)
