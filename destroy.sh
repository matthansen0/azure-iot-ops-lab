#!/usr/bin/env bash
set -euo pipefail
COMPUTE_RG="rg-aioCompute"
OPS_RG="rg-aioOps"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compute-rg) COMPUTE_RG="$2"; shift 2;;
    --ops-rg) OPS_RG="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

echo "==> Deleting resource groups (this removes AIO + VM infra)"
az group delete -n "$COMPUTE_RG" --yes --no-wait || true
az group delete -n "$OPS_RG" --yes --no-wait || true
echo "Requested deletion. You can watch with: az group show -n $COMPUTE_RG; az group show -n $OPS_RG"
