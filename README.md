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
chmod +x deploy.sh destroy.sh get-insights.sh
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

## 📊 Next Steps: Get Insights


After deploying and running the lab, a Log Analytics workspace is automatically created for you in the ops resource group. You can quickly get started with the Azure IoT Operations "Get Insights" tutorial:

1. You will exit SSH, and go back to the cloud shell, then run the provided script to check for required extensions, find your Log Analytics workspace, and run a sample query:

*Default resource group is rg-aioOps; workspace name is always 'aio-laworkspace' (created by deploy.sh)*

  ```bash
  ./get-insights.sh rg-aioOps
  ```


2. Explore more insights and queries as described in the official docs:
   https://learn.microsoft.com/en-us/azure/iot-operations/end-to-end-tutorials/tutorial-get-insights

The script will output the latest IoT Operations logs from your deployment. You can modify the query or use the Azure Portal for deeper analysis.

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
- [ ] Add cost estimation or resource summary
- [ ] Create architecture diagram
