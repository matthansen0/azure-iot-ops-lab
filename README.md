# 🚀 Azure IoT Operations Lab (Ubuntu 24.04 + K3s + Device Simulation)

![Azure Arc](https://img.shields.io/badge/Azure%20Arc-Enabled-0078D4)
![Azure IoT](https://img.shields.io/badge/Azure%20IoT-Operations-0078D4?logo=microsoft-azure&logoColor=white)
![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420)
![K3s](https://img.shields.io/badge/Kubernetes-K3s-326CE5)

Spin up an Ubuntu VM and let it **self‑provision** an end‑to‑end **Azure IoT Operations** (AIO) lab: K3s, Arc connect, AIO foundation, the **embedded quickstarts** (devices, assets, data flow), and a simulator — all from **Azure Cloud Shell** with two scripts. Tear it down with one more.

## 🖼️ Architecture Diagram

![Diagram](media/diagram.png)

---

## ✨ What this automates

- **Arc‑enable** a K3s cluster and turn on **cluster‑connect** + **custom locations** features.  
- Deploy **Azure IoT Operations** (foundation + instance).  
- Run the two **official AIO quickstarts** end‑to‑end (this repo embeds their steps):
  - **[Deploy AIO (quickstart)](https://learn.microsoft.com/azure/iot-operations/)** 
  - **[Configure your cluster (quickstart)](https://learn.microsoft.com/azure/iot-operations/get-started-end-to-end-sample/quickstart-configure)**

> [!NOTE]
> *There is existing automated builds in the above documentation to run this in Codespaces, but the purpose of this repo is to build it out in a VM for a longer-term lab.*

---

## ⚠️ Prerequisite: Azure CLI Login

The assumption is that this deployment will be done from bash in Azure Cloud Shell. Even if you are in Cloud Shell already, it's a good idea before running the deployment script to make sure that you've logged in to Azure CLI, to set the subscription and get a refreshed token:

```bash
az login
```

---

## 🔒 Lab Security notes

- This lab uses your own Azure user credentials for all operations.
- SSH access to the VM is opened via a Network Security Group (NSG) rule.
- A local SSH key pair is generated on your local machine for authentication.

## 🧪 Quick start

```bash
git clone https://github.com/matthansen0/azure-iot-ops-lab.git
cd azure-iot-ops-lab
chmod +x *.sh
```

*Deploy the VM and copy the install script*

```bash
./deploy.sh \
  --subscription "<SUB_ID>" \
  --location "eastus2" \
  --compute-rg "rg-aioCompute" \
  --ops-rg "rg-aioOps" \
  --vm-name "aio24" \
  --ssh-public-key "$HOME/.ssh/id_rsa.pub" \
  --storage-account "aio$(date +%s)" \
  --schema-registry "aioqs-sr" \
  --schema-namespace "aioqs-ns"
```

### With Fabric RTI Integration (Optional)

To enable automatic creation of Microsoft Fabric Real-Time Intelligence resources for data visualization:

```bash
./deploy.sh \
  --subscription "<SUB_ID>" \
  --location "eastus2" \
  --compute-rg "rg-aioCompute" \
  --ops-rg "rg-aioOps" \
  --vm-name "aio24" \
  --ssh-public-key "$HOME/.ssh/id_rsa.pub" \
  --storage-account "aio$(date +%s)" \
  --schema-registry "aioqs-sr" \
  --schema-namespace "aioqs-ns" \
  --enable-fabric \
  --fabric-workspace "aio-fabric-workspace"
```

This will create:
- A Fabric workspace
- An Eventhouse for real-time analytics
- A KQL database for storing oven telemetry
- An Eventstream for data ingestion

> [!NOTE]
> Fabric integration requires appropriate Fabric capacity and permissions. See [Fabric RTI Integration](#-fabric-rti-integration) for details.

### SSH into the VM and run the install script

```bash
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP>
```

```bash
sudo bash /usr/local/bin/aio-install.sh
```

The script will prompt you to authenticate with Azure using a device code, and will take between 30-45 minutes to complete.

![Install Script](media/install-script.png)

### Verify (optional)

```bash
# On the VM (or via Arc)
kubectl get nodes
kubectl get pods -n azure-iot-operations
kubectl get pods -n azure-arc-containerstorage
kubectl get pods -n cert-manager

# In Azure
az iot ops list -g rg-aioOps -o table
```

> View install logs on the VM:
>
> ```bash
> tail -40 /var/log/aio-install.log
> ```

> [!TIP]
> You will be able to see finalized progress of the deployment once there is device messages being sent into the IoT Hub.

---

## 🗑️ Clean up

```bash
./destroy.sh --compute-rg "rg-aioCompute" --ops-rg "rg-aioOps"
```

---

## 🤝 Contributing

Contributions are welcome! If you have suggestions, bug reports, or improvements, please open an issue or submit a pull request. For major changes, please open an issue first to discuss what you would like to change.

Please ensure your pull request adheres to the existing style and includes relevant documentation or examples where appropriate.

---

## 📝 To-Do

- [x] Add "next steps" automation for data ingestion and visualization (Fabric RTI)
- [ ] Add support for password Azure-managed SSH key resources for VM login
- [ ] Add cost estimation or resource summary
- [x] Create architecture diagram

---

## 📊 Fabric RTI Integration

This lab now supports automatic integration with Microsoft Fabric Real-Time Intelligence (RTI) for data visualization and analytics.

### What gets created

When you enable Fabric integration (`--enable-fabric`), the following resources are automatically provisioned:

| Resource | Description |
|----------|-------------|
| **Fabric Workspace** | Container for all Fabric items |
| **Eventhouse** | Real-time analytics engine (similar to Azure Data Explorer) |
| **KQL Database** | Time-series database for storing oven telemetry |
| **Eventstream** | Data ingestion pipeline from AIO to Fabric |

### Prerequisites for Fabric

1. **Fabric Capacity**: You need access to a Fabric capacity (F2 or higher, or trial capacity)
2. **Permissions**: Your Azure AD account must have permission to create Fabric workspaces
3. **Fabric Enabled**: Fabric must be enabled for your tenant

### Data Flow Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   OPC PLC       │────▶│   AIO Broker    │────▶│   Dataflow      │
│   Simulator     │     │   (MQTT)        │     │   (Transform)   │
│   (Oven)        │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   KQL Database  │◀────│   Eventhouse    │◀────│   Eventstream   │
│   (Query/View)  │     │   (Storage)     │     │   (Ingest)      │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Manual Fabric Setup (Alternative)

If you prefer to set up Fabric manually or the automatic setup fails:

```bash
# SSH into the VM
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP>

# Test Fabric API connectivity
sudo /usr/local/bin/fabric-api.sh test

# Run full Fabric deployment
sudo /usr/local/bin/fabric-dataflow.sh deploy
```

### Validating the Integration

Run the test suite to validate your Fabric API integration:

```bash
# Quick connectivity test (no resources created)
./fabric/fabric-api.sh test

# Full integration test (creates and deletes test resources)
./fabric/test-fabric-integration.sh all
```

### Querying Oven Data in Fabric

Once data is flowing, you can query it in the KQL database:

```kql
// Get recent oven telemetry
OvenTelemetry
| where timestamp > ago(1h)
| project timestamp, temperature, fill_weight, energy_use
| order by timestamp desc
| take 100

// Analyze temperature trends
OvenTelemetry
| where timestamp > ago(24h)
| summarize avg_temp = avg(temperature), 
            max_temp = max(temperature),
            min_temp = min(temperature)
  by bin(timestamp, 1h)
| render timechart
```
