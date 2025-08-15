# 🚀 Azure IoT Operations — One‑Shot Lab (Ubuntu 24.04 + K3s + Device Simulation)

![Azure Arc](https://img.shields.io/badge/Azure%20Arc-Enabled-0078D4)
![Azure IoT](https://img.shields.io/badge/Azure%20IoT-Operations-0078D4?logo=microsoft-azure&logoColor=white)
![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420)
![K3s](https://img.shields.io/badge/Kubernetes-K3s-326CE5)


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



## ⚠️ Prerequisite: Azure CLI Login

Before running the deployment script, ensure you are logged in to Azure CLI:

```bash
az login
```

You will use your own user credentials for all Azure operations inside the VM (no managed identity required).


## 🧪 Quick start

```bash
git clone https://github.com/matthansen0/azure-iot-ops-lab.git
cd azure-iot-ops-lab
chmod +x deploy.sh destroy.sh

# Deploy the VM and copy the install script (does NOT run the install automatically)
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

### SSH into the VM and run the install script manually

```bash
ssh azureuser@<VM_PUBLIC_IP>
sudo bash /usr/local/bin/aio-install.sh
```

The script will prompt you to authenticate with Azure using a device code. Follow the instructions in your browser.

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

Because the VM uses a **system‑assigned** identity, deleting the VM deletes its identity; RG‑scoped role assignments are removed with the RG. (If you granted extra roles at broader scopes, remove those first.)

---


## 🔐 Lab Authentication

- All Azure operations inside the VM are performed using your own user credentials (via `az login --use-device-code`).
- No managed identity is required for the VM.

---

## 🧰 Troubleshooting

- General AIO health & config checks:  
  - `az iot ops check`  
  - `az iot ops support create-bundle`  
- If a run failed during AIO init/create and you see “multiple extensions” errors, delete the lab RGs with `destroy.sh` and redeploy (fastest in a lab).

---

## 💸 Cost & limits

Expect charges for the VM and Azure resources in the Ops Resource Group (Storage, Event Hubs created by the quickstart). Power off the VM when not in use, and use `destroy.sh` when you’re done and want to delete everything.