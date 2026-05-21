# Lab 1: Explore Your AIO Deployment

After the automated install completes, explore what was deployed across Azure and Kubernetes.

## Prerequisites

- Completed deployment (`deploy.sh` finished, install log shows "All done")
- Access to the [Azure Portal](https://portal.azure.com)

## 1. Azure Portal — Resource Group Overview

1. Open the [Azure Portal](https://portal.azure.com) and navigate to your ops resource group (default: **rg-aioOps**).
2. You should see these resources:
   - **Connected Cluster** (`aio-k3s`) — the Arc-enabled K3s cluster
   - **Azure IoT Operations instance** (`aio-k3s-instance`) — the AIO deployment
   - **Custom Location** — the bridge between Arc and AIO resources
   - **Schema Registry** and **Storage Account** — backing store for message schemas
   - **Device Registry namespace** — logical isolation for assets

> **Tip:** Click the **Connected Cluster** resource, then **Extensions** in the left nav to see all Arc extensions (IoT Operations, cert-manager, secret store, etc.).

## 2. Azure IoT Operations Instance

1. Click the **Azure IoT Operations** instance resource.
2. On the **Overview** blade, note:
   - **Provisioning state** — should be `Succeeded`
   - **Version** — the AIO version installed
   - **Extended location** — the custom location linking to your cluster
3. In the left nav, explore:
   - **MQTT Broker** — broker configuration, listeners, authentication, and authorization
   - **Data flow profiles** — the default profile and its instance count
   - **Data flow endpoints** — the local MQTT endpoint (named `default`) and any others

## 3. Connected Cluster Details

1. Go back to the resource group and click the **Connected Cluster**.
2. In the left nav, explore:
   - **Overview** — cluster connectivity status, Arc agent version, K8s version
   - **Extensions** — all installed extensions with their version and provisioning state
   - **Custom locations** — the custom location tied to this cluster

## 4. Assets and OPC PLC Simulator

1. From the resource group, open the **Azure IoT Operations** instance.
2. Navigate to **Assets** (or **Namespace assets**) — you should see the quickstart assets created by the Bicep deployment.
3. Click an asset to view its datasets, data points, and the OPC UA endpoint it connects to.

> The OPC PLC simulator generates sample telemetry (temperature, pressure, etc.) that flows through these assets into the MQTT broker.

## 5. AIO Health Status (Portal)

AIO 2603+ surfaces unified health states directly in the portal:

1. Open the **Azure IoT Operations** instance.
2. Check the **Overview** page for the instance health status badge.
3. Navigate to **MQTT Broker** — each broker resource shows its health state: **Available**, **Degraded**, **Unavailable**, or **Unknown**.

## 6. (Optional) CLI Deep Dive

SSH into the VM for a Kubernetes-level view:

```bash
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP>
sudo -i
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

```bash
# Namespaces and pods
kubectl get namespaces | grep -E 'azure|cert-manager'
kubectl get pods -n azure-iot-operations

# AIO custom resources
kubectl get broker,brokerlistener,dataflowprofile,dataflowendpoint,asset -n azure-iot-operations

# Health states
kubectl get broker -n azure-iot-operations -o jsonpath='{range .items[*]}{.metadata.name}: {.status.health.state}{"\n"}{end}'

# Instance tree view
az iot ops show --name <CLUSTER_NAME>-instance -g <OPS_RG> --tree

# Comprehensive health check
az iot ops check
az iot ops check --svc broker --detail-level 1
```

## Next Steps

- [Lab 2: Observability & Monitoring](02-observability.md)
