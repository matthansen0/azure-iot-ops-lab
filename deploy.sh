#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via flags)
SUBSCRIPTION=""
LOCATION="eastus2"
COMPUTE_RG="rg-aioCompute"
OPS_RG="rg-aioOps"
VM_NAME="aio24"
VNET_NAME="${VM_NAME}-vnet"
SUBNET_NAME="subnet"
NSG_NAME="${VM_NAME}-nsg"
NIC_NAME="${VM_NAME}-nic"
PIP_NAME="${VM_NAME}-pip"
VM_SIZE="Standard_D4s_v5"
IMAGE_URN="Ubuntu2404" 
ADMIN_USERNAME="azureuser"
SSH_PUBLIC_KEY="$HOME/.ssh/id_rsa.pub"
ENABLE_ACCEL_NET=true

# AIO params
STORAGE_ACCOUNT=""
SCHEMA_REGISTRY="aioqs-sr"
SCHEMA_NAMESPACE="aioqs-ns"
CLUSTER_NAME="aio-k3s"
AIO_NAMESPACE_NAME="myqsnamespace"

# Fabric RTI params
ENABLE_FABRIC="false"
FABRIC_WORKSPACE_NAME=""
FABRIC_CAPACITY_ID=""
FABRIC_EVENTHOUSE_NAME="aio-eventhouse"
FABRIC_DATABASE_NAME="aio-rti-db"
FABRIC_EVENTSTREAM_NAME="aio-eventstream"

usage() {
  cat <<EOF
Usage: $0 --subscription <SUB_ID> --location <region> [options]

Required:
  --subscription            Azure Subscription ID
  --location                Azure region (e.g., eastus)
  --storage-account         Globally unique name for Storage Account (lowercase/numbers)

Optional:
  --compute-rg              Compute resource group (default: $COMPUTE_RG)
  --ops-rg                  Ops resource group for AIO (default: $OPS_RG)
  --vm-name                 VM name (default: $VM_NAME)
  --vm-size                 VM size (default: $VM_SIZE)
  --admin-username          VM admin username (default: $ADMIN_USERNAME)
  --ssh-public-key          Path to SSH pub key (default: $SSH_PUBLIC_KEY)
  --cluster-name            AIO/Arc cluster name (default: $CLUSTER_NAME)
  --schema-registry         Schema Registry name (default: $SCHEMA_REGISTRY)
  --schema-namespace        Schema Registry namespace (default: $SCHEMA_NAMESPACE)
  --aio-namespace           Device Registry namespace (default: $AIO_NAMESPACE_NAME)

Fabric RTI Options:
  --enable-fabric           Enable Fabric RTI integration (default: false)
  --fabric-workspace        Fabric workspace name (required if --enable-fabric)
  --fabric-capacity-id      Fabric capacity ID (REQUIRED - run fabric/fabric-preflight.sh to find)
  --fabric-eventhouse       Eventhouse name (default: $FABRIC_EVENTHOUSE_NAME)
  --fabric-database         KQL database name (default: $FABRIC_DATABASE_NAME)
  --fabric-eventstream      Eventstream name (default: $FABRIC_EVENTSTREAM_NAME)

IMPORTANT: Run './fabric/fabric-preflight.sh' BEFORE deploying with Fabric to verify access!
EOF
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --compute-rg) COMPUTE_RG="$2"; shift 2;;
    --ops-rg) OPS_RG="$2"; shift 2;;
    --vm-name) VM_NAME="$2"; shift 2;;
    --vm-size) VM_SIZE="$2"; shift 2;;
    --admin-username) ADMIN_USERNAME="$2"; shift 2;;
    --ssh-public-key) SSH_PUBLIC_KEY="$2"; shift 2;;
    --storage-account) STORAGE_ACCOUNT="$2"; shift 2;;
    --schema-registry) SCHEMA_REGISTRY="$2"; shift 2;;
    --schema-namespace) SCHEMA_NAMESPACE="$2"; shift 2;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --aio-namespace) AIO_NAMESPACE_NAME="$2"; shift 2;;
    --enable-fabric) ENABLE_FABRIC="true"; shift 1;;
    --fabric-workspace) FABRIC_WORKSPACE_NAME="$2"; shift 2;;
    --fabric-capacity-id) FABRIC_CAPACITY_ID="$2"; shift 2;;
    --fabric-eventhouse) FABRIC_EVENTHOUSE_NAME="$2"; shift 2;;
    --fabric-database) FABRIC_DATABASE_NAME="$2"; shift 2;;
    --fabric-eventstream) FABRIC_EVENTSTREAM_NAME="$2"; shift 2;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -z "$SUBSCRIPTION" || -z "$LOCATION" || -z "$STORAGE_ACCOUNT" ]] && usage

# Validate Fabric params if enabled
if [[ "$ENABLE_FABRIC" == "true" ]]; then
  if [[ -z "$FABRIC_WORKSPACE_NAME" ]]; then
    echo "Error: --fabric-workspace is required when --enable-fabric is set"
    usage
  fi
  if [[ -z "$FABRIC_CAPACITY_ID" ]]; then
    echo "Error: --fabric-capacity-id is required when --enable-fabric is set"
    echo ""
    echo "Run './fabric/fabric-preflight.sh --list-capacities' to find your capacity ID"
    echo ""
    exit 1
  fi
fi


# Preemptive Azure login check
if ! az account show &>/dev/null; then
  echo "You are not logged in to Azure CLI. Please complete login."
  az login || { echo "Azure login failed. Exiting."; exit 1; }
fi

# Check for SSH key, generate if missing
if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "SSH key not found: $SSH_PUBLIC_KEY"
  echo "Generating a new SSH key pair..."
  ssh-keygen -t rsa -b 4096 -f "${SSH_PUBLIC_KEY%.*}" -N ""
fi

echo "==> Setting subscription"
az account set --subscription "$SUBSCRIPTION"

echo "==> Global provider registration"
for rp in Microsoft.ExtendedLocation Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.IoTOperations Microsoft.DeviceRegistry Microsoft.Storage Microsoft.Network; do
  az provider register -n "$rp" -o none || true
done

echo "==> Create resource groups"
az group create -n "$COMPUTE_RG" -l "$LOCATION" -o none
az group create -n "$OPS_RG" -l "$LOCATION" -o none

echo "==> Create VNet, subnet, NSG"


# Create VNet with retry
for i in {1..5}; do
  if az network vnet create -g "$COMPUTE_RG" -n "$VNET_NAME" -l "$LOCATION" \
    --address-prefixes 10.10.0.0/16 --subnet-name "$SUBNET_NAME" --subnet-prefix 10.10.1.0/24 -o none; then
    break
  fi
  echo "VNet creation failed (attempt $i). Retrying in 10s..."
  sleep 10
  if [[ $i -eq 5 ]]; then
    echo "VNet creation failed after 5 attempts. Exiting."
    exit 1
  fi
done

# Create NSG with retry
for i in {1..5}; do
  if az network nsg create -g "$COMPUTE_RG" -n "$NSG_NAME" -l "$LOCATION" -o none; then
    break
  fi
  echo "NSG creation failed (attempt $i). Retrying in 10s..."
  sleep 10
  if [[ $i -eq 5 ]]; then
    echo "NSG creation failed after 5 attempts. Exiting."
    exit 1
  fi
done

# Wait for VNet to be available
for i in {1..10}; do
  if az network vnet show -g "$COMPUTE_RG" -n "$VNET_NAME" &>/dev/null; then
    break
  fi
  echo "Waiting for VNet to be available..."
  sleep 5
done

# Wait for NSG to be available
for i in {1..10}; do
  if az network nsg show -g "$COMPUTE_RG" -n "$NSG_NAME" &>/dev/null; then
    break
  fi
  echo "Waiting for NSG to be available..."
  sleep 5
done


# Extra wait for NSG propagation before creating rules
for i in {1..10}; do
  if az network nsg show -g "$COMPUTE_RG" -n "$NSG_NAME" &>/dev/null; then
    break
  fi
  echo "Waiting for NSG to be fully propagated before rule creation..."
  sleep 5
done

# Restrict SSH to current IP
MYIP=$(curl -s https://ifconfig.me || echo "0.0.0.0")
az network nsg rule create -g "$COMPUTE_RG" --nsg-name "$NSG_NAME" -n allow_ssh_from_me \
  --priority 1000 --access Allow --protocol Tcp --direction Inbound \
  --source-address-prefixes "${MYIP}/32" --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 22 -o none

echo "==> Public IP + NIC"

# Create Public IP and wait for it to be available
az network public-ip create -g "$COMPUTE_RG" -n "$PIP_NAME" -l "$LOCATION" --sku Standard --zone 1 2 3 -o none
for i in {1..10}; do
  if az network public-ip show -g "$COMPUTE_RG" -n "$PIP_NAME" &>/dev/null; then
    break
  fi
  echo "Waiting for Public IP to be available..."
  sleep 5
done

# Create NIC and wait for it to be available
az network nic create -g "$COMPUTE_RG" -n "$NIC_NAME" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$PIP_NAME" \
  $( [[ "$ENABLE_ACCEL_NET" == "true" ]] && echo --accelerated-networking true ) -o none
for i in {1..10}; do
  if az network nic show -g "$COMPUTE_RG" -n "$NIC_NAME" &>/dev/null; then
    break
  fi
  echo "Waiting for NIC to be available..."
  sleep 5
done

echo "==> Prepare cloud-init from template"
TMP_CI="$(mktemp)"
sed -e "s|@@SUBSCRIPTION@@|$SUBSCRIPTION|g" \
    -e "s|@@LOCATION@@|$LOCATION|g" \
    -e "s|@@OPS_RG@@|$OPS_RG|g" \
    -e "s|@@CLUSTER_NAME@@|$CLUSTER_NAME|g" \
    -e "s|@@STORAGE_ACCOUNT@@|$STORAGE_ACCOUNT|g" \
    -e "s|@@SCHEMA_REGISTRY@@|$SCHEMA_REGISTRY|g" \
    -e "s|@@SCHEMA_NAMESPACE@@|$SCHEMA_NAMESPACE|g" \
    -e "s|@@AIO_NAMESPACE_NAME@@|$AIO_NAMESPACE_NAME|g" \
    -e "s|@@ENABLE_FABRIC@@|$ENABLE_FABRIC|g" \
    -e "s|@@FABRIC_WORKSPACE_NAME@@|$FABRIC_WORKSPACE_NAME|g" \
    -e "s|@@FABRIC_CAPACITY_ID@@|$FABRIC_CAPACITY_ID|g" \
    -e "s|@@FABRIC_EVENTHOUSE_NAME@@|$FABRIC_EVENTHOUSE_NAME|g" \
    -e "s|@@FABRIC_DATABASE_NAME@@|$FABRIC_DATABASE_NAME|g" \
    -e "s|@@FABRIC_EVENTSTREAM_NAME@@|$FABRIC_EVENTSTREAM_NAME|g" \
    vm/cloud-init-aio.tmpl.yaml > "$TMP_CI"

echo "==> Create VM (Ubuntu 24.04 LTS)"
az vm create \
  -g "$COMPUTE_RG" -n "$VM_NAME" \
  --location "$LOCATION" \
  --nics "$NIC_NAME" \
  --image "$IMAGE_URN" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USERNAME" \
  --ssh-key-values "$SSH_PUBLIC_KEY" \
  --custom-data "$TMP_CI" \
  --public-ip-sku Standard \
  -o jsonc | jq '{name: .name, publicIp: .publicIpAddress, fqdns: .fqdns}'

echo "==> Enable managed boot diagnostics on VM (post-create)"
az vm boot-diagnostics enable --resource-group "$COMPUTE_RG" --name "$VM_NAME" -o none

# Get VM public IP for later use
VM_PUBLIC_IP=$(az vm list-ip-addresses -g "$COMPUTE_RG" -n "$VM_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)

# Copy Fabric scripts to VM if Fabric is enabled
if [[ "$ENABLE_FABRIC" == "true" ]]; then
  echo "==> Copying Fabric integration scripts to VM"
  sleep 10  # Wait for VM to be fully ready
  
  # Wait for SSH to be available
  for i in {1..30}; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${SSH_PUBLIC_KEY%.*}" "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" "echo 'SSH ready'" &>/dev/null; then
      break
    fi
    echo "Waiting for SSH to be available... (attempt $i)"
    sleep 10
  done
  
  # Copy Fabric scripts
  if [[ -d "fabric" ]]; then
    scp -o StrictHostKeyChecking=no -i "${SSH_PUBLIC_KEY%.*}" \
      fabric/fabric-api.sh \
      fabric/fabric-dataflow.sh \
      fabric/fabric-eventstream-setup.sh \
      "${ADMIN_USERNAME}@${VM_PUBLIC_IP}:/tmp/" || echo "Warning: Could not copy Fabric scripts"
    
    ssh -o StrictHostKeyChecking=no -i "${SSH_PUBLIC_KEY%.*}" "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" \
      "sudo mv /tmp/fabric-*.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/fabric-*.sh" || \
      echo "Warning: Could not install Fabric scripts"
  fi
fi

echo "==> Done. Now login and run the AIO install script."
echo "Via SSH: ssh -i ~/.ssh/id_rsa ${ADMIN_USERNAME}@${VM_PUBLIC_IP}"
echo "or Serial Console: az serial-console connect -g $COMPUTE_RG -n $VM_NAME"

if [[ "$ENABLE_FABRIC" == "true" ]]; then
  echo ""
  echo "==> Fabric RTI integration is enabled."
  echo "    After AIO installation, Fabric resources will be created automatically."
  echo "    You can also manually run: sudo /usr/local/bin/fabric-dataflow.sh deploy"
fi