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

## 🧪 Quick start (Azure Cloud Shell)

```bash
git clone https://github.com/matthansen0/azure-iot-ops-lab.git
cd azure-iot-ops-lab
chmod +x deploy.sh destroy.sh

./deploy.sh \
  --subscription "<SUB_ID>" \
  --location "eastus" \
  --compute-rg "rg-aioCompute" \
  --ops-rg "rg-aioOps" \
  --vm-name "aio24" \
  --ssh-public-key "$HOME/.ssh/id_rsa.pub" \
  --storage-account "aio$(date +%s)" \
  --schema-registry "aioqs-sr" \
  --schema-namespace "aioqs-ns"
```

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

```bash
./destroy.sh --compute-rg "rg-aioCompute" --ops-rg "rg-aioOps"
```

Because the VM uses a **system‑assigned** identity, deleting the VM deletes its identity; RG‑scoped role assignments are removed with the RG. (If you granted extra roles at broader scopes, remove those first.)

---

## 🔐 Lab Authentication

- `deploy.sh` enables a **System‑Assigned Managed Identity** on the VM and grants it rights on the **Ops RG**.  
- On first boot, `cloud-init` runs inside the VM and uses **`az login --identity`** to perform all control‑plane actions (Arc connect, AIO resources, quickstarts).  
- You can tighten RBAC later (e.g., use the Arc Onboarding + AIO Onboarding roles), but **Contributor on the Ops RG** keeps the sample simple for a lab environment.

---

## 🧰 Troubleshooting

- General AIO health & config checks:  
  - `az iot ops check`  
  - `az iot ops support create-bundle`  
- If a run failed during AIO init/create and you see “multiple extensions” errors, delete the lab RGs with `destroy.sh` and redeploy (fastest in a lab).

---

## 💸 Cost & limits

Expect charges for the VM and Azure resources in the Ops Resource Group (Storage, Event Hubs created by the quickstart). Power off the VM when not in use, and use `destroy.sh` when you’re done and want to delete everything.