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

- The VM uses a **system-assigned managed identity** with Owner role on the ops resource group. This enables fully automated (non-interactive) AIO installation via cloud-init.
- SSH access to the VM is opened via a Network Security Group (NSG) rule restricted to your current IP.
- A local SSH key pair is generated on your local machine for authentication.

## 🧪 Quick start

```bash
git clone https://github.com/matthansen0/azure-iot-ops-lab.git
cd azure-iot-ops-lab
chmod +x *.sh
```

*Deploy — the install runs automatically after VM creation:*

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

The script creates the VM with a managed identity, assigns it roles, and cloud-init automatically begins the AIO installation. No manual SSH or device-code login is needed.

### Monitor progress

```bash
# Follow the install log (takes ~30-45 minutes)
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP> 'sudo tail -f /var/log/aio-install.log'
```

### Verify (optional)

```bash
# On the VM (or via Arc)
ssh -i ~/.ssh/id_rsa azureuser@<VM_PUBLIC_IP>
sudo -i
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
kubectl get pods -n azure-iot-operations
kubectl get pods -n cert-manager

# From any machine with Azure CLI
az iot ops list -g rg-aioOps -o table
az iot ops check
```

> View install logs on the VM:
>
> ```bash
> tail -40 /var/log/aio-install.log
> ```

---

## 📖 Lab Guides

Once the deployment is complete, work through the hands-on labs:

| Lab | Topic |
|-----|-------|
| [Lab 1: Explore](labs/01-explore.md) | Tour K8s resources, AIO custom resources, the Azure portal, and health checks |
| [Lab 2: Observability](labs/02-observability.md) | Verify the OTel collector, view Prometheus metrics, optionally add Azure Monitor + Grafana |
| [Lab 3: Data Flows](labs/03-dataflow.md) | Create a data flow endpoint and route OPC PLC data to Event Hubs |
| [Lab 4: Cleanup](labs/04-cleanup.md) | Tear down all resources |

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

- [ ] Add "next steps" automation for data ingestion and visualization
- [ ] Add support for password Azure-managed SSH key resources for VM login
