# Azure IoT Operations Lab

## What this repo does

Automated lab that provisions an Ubuntu 24.04 VM and self-installs an end-to-end **Azure IoT Operations** (AIO) environment: K3s → Arc connect → AIO foundation → AIO instance → OPC PLC simulator → quickstart Bicep.

## Repo structure

- `deploy.sh` — Runs from the operator's machine (Cloud Shell). Creates Azure networking, VM with managed identity, assigns roles, and injects `cloud-init-aio.tmpl.yaml` as custom-data. The AIO install runs automatically via cloud-init.
- `destroy.sh` — Tears down both resource groups.
- `vm/cloud-init-aio.tmpl.yaml` — Cloud-init template that runs **inside the VM** after first boot. Installs K3s, Arc-connects, deploys AIO, and runs the quickstart.
- `labs/` — Hands-on lab guides for exploring the deployment, observability, data flows, and cleanup.
- Quickstart assets (Bicep, OPC PLC YAML) are pulled at runtime from [Azure-Samples/explore-iot-operations](https://github.com/Azure-Samples/explore-iot-operations).

## Template substitution

`deploy.sh` uses `sed` to replace `@@PLACEHOLDER@@` tokens in the cloud-init template before passing it to `az vm create --custom-data`. Current tokens:

`@@SUBSCRIPTION@@`, `@@LOCATION@@`, `@@OPS_RG@@`, `@@CLUSTER_NAME@@`, `@@STORAGE_ACCOUNT@@`, `@@SCHEMA_REGISTRY@@`, `@@SCHEMA_NAMESPACE@@`, `@@AIO_NAMESPACE_NAME@@`, `@@CUSTOM_LOCATIONS_OID@@`

When adding new parameters, update **both** `deploy.sh` (args, sed, usage) and the cloud-init template (`/etc/aio.env` + the install script).

## Key conventions

- All scripts target **bash** (Ubuntu 24.04 on the VM, bash/Cloud Shell on the operator side).
- Cloud-init yaml must stay valid YAML — the embedded bash script lives under `write_files[].content: |`.
- The `az iot ops` CLI extension is the primary tooling; use `--allow-preview True` when installing.
- Both `deploy.sh` and cloud-init register Azure resource providers — keep them aligned.
- The lab uses **two resource groups**: one for compute infra (`rg-aioCompute`), one for AIO/Arc resources (`rg-aioOps`).
