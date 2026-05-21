# Lab 2: Observability & Monitoring

The automated install deploys an OpenTelemetry (OTel) Collector and configures AIO to ship metrics to it. This lab walks through checking observability from the Azure Portal and optionally adding cloud-side monitoring with Azure Monitor and Grafana.

## Prerequisites

- Completed deployment with OTel collector running
- Access to the [Azure Portal](https://portal.azure.com)

## 1. Check AIO Health in the Portal

1. Open the [Azure Portal](https://portal.azure.com) and navigate to your ops resource group (default: **rg-aioOps**).
2. Click the **Azure IoT Operations** instance.
3. On the **Overview** page, check the health status badge — it should show **Available**.
4. Navigate to **MQTT Broker** in the left nav — each broker and listener resource shows its own health state.
5. Navigate to **Data flow profiles** — profiles and their runtime instances also report health.

> AIO 2603+ provides unified health states (**Available** / **Degraded** / **Unavailable** / **Unknown**) surfaced on both Azure Resource Manager and Kubernetes custom resources.

## 2. Review Extensions and Monitoring

1. From the resource group, open the **Connected Cluster** resource.
2. In the left nav, click **Extensions**.
3. You should see extensions including:
   - `microsoft.iotoperations` — the core AIO extension
   - `microsoft.azure.certificatemanager` — cert-manager
   - `microsoft.azure.secretstore` — secret store
4. If you later add Azure Monitor (see section 4), additional extensions appear here.

## 3. Verify the OTel Collector (CLI)

SSH into the VM to verify the edge-local observability stack:

```bash
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP>
sudo -i
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Check the collector pod
kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=opentelemetry-collector

# Check collector logs
kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=opentelemetry-collector --tail=20

# View Prometheus metrics locally
kubectl port-forward -n azure-iot-operations svc/aio-otel-collector 8889:8889 &
curl -s http://localhost:8889/metrics | grep -i "aio\|mqtt\|broker\|dataflow" | head -30
```

## 4. (Optional) Add Azure Monitor + Managed Grafana

This adds cloud-side dashboards with Azure Monitor for Prometheus and Managed Grafana. This section requires CLI access.

### Create monitoring resources

```bash
source /etc/aio.env

# Register additional providers
for rp in Microsoft.AlertsManagement Microsoft.Monitor Microsoft.Dashboard Microsoft.Insights Microsoft.OperationalInsights; do
  az provider register --namespace "$rp" -o none
done

# Azure Monitor workspace
AZ_MONITOR_ID=$(az monitor account create \
  --name "${CLUSTER_NAME}-monitor" \
  --resource-group "$OPS_RG" \
  --location "$LOCATION" \
  --query id -o tsv)

# Managed Grafana instance
GRAFANA_ID=$(az grafana create \
  --name "${CLUSTER_NAME}-grafana" \
  --resource-group "$OPS_RG" \
  --query id -o tsv)

# Log Analytics workspace
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace create \
  -g "$OPS_RG" \
  -n "${CLUSTER_NAME}-logs" \
  --query id -o tsv)
```

### Enable metrics collection on the Arc cluster

```bash
az k8s-extension create \
  --name azuremonitor-metrics \
  --cluster-name "$CLUSTER_NAME" \
  --resource-group "$OPS_RG" \
  --cluster-type connectedClusters \
  --extension-type Microsoft.AzureMonitor.Containers.Metrics \
  --configuration-settings \
    azure-monitor-workspace-resource-id="$AZ_MONITOR_ID" \
    grafana-resource-id="$GRAFANA_ID"

az k8s-extension create \
  --name azuremonitor-containers \
  --cluster-name "$CLUSTER_NAME" \
  --resource-group "$OPS_RG" \
  --cluster-type connectedClusters \
  --extension-type Microsoft.AzureMonitor.Containers \
  --configuration-settings \
    logAnalyticsWorkspaceResourceID="$LOG_ANALYTICS_ID"
```

### Configure Prometheus scraping

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ama-metrics-prometheus-config
  namespace: kube-system
data:
  prometheus-config: |
    scrape_configs:
      - job_name: otel
        scrape_interval: 1m
        static_configs:
          - targets:
            - aio-otel-collector.azure-iot-operations.svc.cluster.local:8889
      - job_name: aio-annotated-pod-metrics
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - action: drop
            regex: true
            source_labels:
              - __meta_kubernetes_pod_container_init
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scrape
          - action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            source_labels:
              - __address__
              - __meta_kubernetes_pod_annotation_prometheus_io_port
            target_label: __address__
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: kubernetes_namespace
          - action: keep
            regex: 'azure-iot-operations'
            source_labels:
              - kubernetes_namespace
        scrape_interval: 1m
EOF
```

### View dashboards in Grafana

1. In the Azure Portal, navigate to your resource group and open the **Managed Grafana** resource.
2. Click **Endpoint** on the Overview page to open the Grafana UI.
3. Go to **Dashboards** > **Import**.
4. Import the AIO dashboard JSON from the [explore-iot-operations samples](https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/observability/grafana-dashboard).
5. When prompted, select your managed Prometheus data source.
6. After import, the dashboard shows broker throughput, data flow latency, and connector health.

## Next Steps

- [Lab 3: Create a Data Flow](03-dataflow.md)
