# Lab 4: Cleanup

Tear down all lab resources when you're done.

## Option A: Portal Cleanup

1. Open the [Azure Portal](https://portal.azure.com).
2. Search for **Resource groups**.
3. Select **rg-aioOps** and click **Delete resource group**. Type the name to confirm and click **Delete**.
4. Repeat for **rg-aioCompute**.

> **Note:** AIO and Arc resources can take 10-20 minutes to fully clean up. The ops resource group may take longer due to the Arc-connected cluster and IoT Operations instance.

## Option B: Script Cleanup

From your operator machine (Cloud Shell or local terminal):

```bash
./destroy.sh --compute-rg rg-aioCompute --ops-rg rg-aioOps
```

This requests deletion of both resource groups asynchronously.

## What Gets Deleted

| Resource Group | Contains |
|---|---|
| `rg-aioCompute` | VM, VNet, NSG, NIC, Public IP, boot diagnostics |
| `rg-aioOps` | Arc-connected cluster, AIO instance, custom location, schema registry, storage account, and any resources created in the labs (Event Hubs, Monitor workspace, Grafana) |

## Monitor Deletion Progress

```bash
# Check if resource groups still exist
az group show -n rg-aioCompute -o table 2>/dev/null || echo "Compute RG deleted"
az group show -n rg-aioOps -o table 2>/dev/null || echo "Ops RG deleted"

# List any remaining resources
az resource list -g rg-aioOps -o table 2>/dev/null
```

> **Note:** AIO and Arc resources can take 10-20 minutes to fully clean up. The `--no-wait` flag in destroy.sh means the command returns immediately.

## Manual Cleanup (if needed)

If resource group deletion gets stuck:

```bash
# Force-delete the AIO instance first
az iot ops delete --cluster <CLUSTER_NAME> -g rg-aioOps --include-deps --force -y

# Then retry resource group deletion
az group delete -n rg-aioOps --yes
```

## Verify

```bash
# Confirm no leftover resources
az group list --query "[?starts_with(name, 'rg-aio')]" -o table
```
