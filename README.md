
# 🚀 Azure IoT Operations — All-in-One Lab

![Azure Arc](https://img.shields.io/badge/Azure%20Arc-Enabled-0078D4)
![Azure IoT](https://img.shields.io/badge/Azure%20IoT-Operations-0078D4?logo=microsoft-azure&logoColor=white)
![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420)
![K3s](https://img.shields.io/badge/Kubernetes-K3s-326CE5)

**Ubuntu 24.04 + K3s + Device Simulation:**

Spin up an Ubuntu VM and let it **self‑provision** an end‑to‑end **Azure IoT Operations** (AIO) lab: K3s, Arc connect, AIO foundation, the **embedded quickstarts** (devices, assets, data flow), and a simulator — all from **Azure Cloud Shell** with two scripts. Tear it down with one more.



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



## 🧪 Quick start (Bicep deployment)

```bash
git clone https://github.com/matthansen0/azure-iot-ops-lab.git
cd azure-iot-ops-lab
```

1. Edit `infra/main.parameters.json` and set at least:
  - `adminPassword`: Set your desired VM password (required)
  - (Optional) Change `location`, `vmSize`, or other parameters as needed

2. Create the resource group (if it doesn't exist):
  ```bash
  az group create --name rg-aioLab --location eastus2
  ```

3. Deploy everything with one command:
  ```bash
  az deployment group create \
    --resource-group rg-aioLab \
    --template-file infra/main.bicep \
    --parameters @infra/main.parameters.json
  ```

> [!TIP]
> Make sure you're back in the repo root before running the ``az deployment`` command above. If you drop down into the infra folder to modify the parameters and don't go back the file paths will no match up with the command.

> **Manual Parameter Editing (if needed):**
> Edit `infra/main.parameters.json` to customize:
> - `location`: Azure region (e.g., "eastus2")
> - `vmName`: VM name (e.g., "aio24")
> - `adminUsername`: VM admin username (default: "azureuser")
> - `adminPassword`: Password for the VM (required)
> - `vmSize`: VM size (default: "Standard_D4s_v5")



### Verify (optional)

```bash
# On the VM (or via Arc)
kubectl get nodes
kubectl get pods -n azure-iot-operations
kubectl get pods -n azure-arc-containerstorage
kubectl get pods -n cert-manager

# In Azure
az iot ops list -g rg-aioLab -o table
```

> View progress logs on the VM:
>
> ```bash
> sudo journalctl -u cloud-final -f
> sudo tail -f /var/log/aio-install.log
> ```

> [!TIP]
> You will be able to see finalized progress of the deployment once there is device messages being sent into the IoT Hub. 

---

## 🗑️ Clean up



> [!NOTE]
> To remove all resources, simply delete the resource group:
> ```bash
> az group delete --name rg-aioLab
> ```

Because the VM uses a **system‑assigned** identity, deleting the VM deletes its identity; RG‑scoped role assignments are removed with the RG. (If you granted extra roles at broader scopes, remove those first.)

---

## 🔐 Lab Authentication

- The Bicep deployment enables a **System‑Assigned Managed Identity** on the VM and grants it rights on the **Ops RG**.  
- On first boot, `cloud-init` runs inside the VM and uses **`az login --identity`** to perform all control‑plane actions (Arc connect, AIO resources, quickstarts).  
- You can tighten RBAC later (e.g., use the Arc Onboarding + AIO Onboarding roles), but **Contributor on the Ops RG** keeps the sample simple for a lab environment.

---

## 🧰 Troubleshooting

- General AIO health & config checks:  
  - `az iot ops check`  
  - `az iot ops support create-bundle`  
- If a run failed during AIO init/create and you see “multiple extensions” errors, delete the lab resource group and redeploy (fastest in a lab).

---

## 💸 Cost & limits

Expect charges for the VM and Azure resources in the Ops Resource Group (Storage, Event Hubs created by the quickstart). Power off the VM when not in use, and delete the resource group when you’re done and want to delete everything.