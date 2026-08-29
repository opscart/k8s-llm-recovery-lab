# Azure VM Provisioning for Cold-Node LLM Recovery

This document records the Azure infrastructure used for the two-node cold-node recovery experiment. It intentionally excludes subscription IDs, public IPs, MAC addresses, SSH keys, and other account-specific identifiers.

## Topology

| Role | VM | Purpose |
|---|---|---|
| Source | `k8s-llm-cpu-01` | Starts with the model actively serving |
| Target | `k8s-llm-cpu-02` | Receives the workload during cold-node recovery |

Both VMs use the same Azure region, VNet, subnet, NSG, VM size, OS image family, and storage class.

## VM Configuration

| Setting | Value |
|---|---|
| Region | `eastus2` |
| VM size | `Standard_D16s_v5` |
| OS | Ubuntu Server 22.04 LTS Gen2 |
| Publisher | `Canonical` |
| Offer | `0001-com-ubuntu-server-jammy` |
| SKU | `22_04-lts-gen2` |
| Exact image version | `22.04.202608060` |
| OS disk size | 256 GiB |
| OS disk SKU | `Premium_LRS` |
| Node A observed disk tier | `P15` |
| Accelerated networking | Disabled |
| IP forwarding | Disabled |

## Network Configuration

| Setting | Value |
|---|---|
| VNet | `k8s-llm-cpu-01VNET` |
| Subnet | `k8s-llm-cpu-01Subnet` |
| NSG | `k8s-llm-cpu-01NSG` |
| Private IP allocation | Dynamic |
| Public IP SKU | Standard |
| Public IP allocation | Static |
| IP version | IPv4 |

## Azure CLI Variables

```bash
RG="rg-k8s-llm-recovery"
LOCATION="eastus2"

VM02="k8s-llm-cpu-02"
NIC02="k8s-llm-cpu-02VMNic"
PIP02="k8s-llm-cpu-02PublicIP"

VNET="k8s-llm-cpu-01VNET"
SUBNET="k8s-llm-cpu-01Subnet"
NSG="k8s-llm-cpu-01NSG"
```

## Create the Target Public IP

```bash
az network public-ip create \
  --resource-group "$RG" \
  --name "$PIP02" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static \
  --version IPv4
```

## Create the Target NIC

```bash
az network nic create \
  --resource-group "$RG" \
  --name "$NIC02" \
  --location "$LOCATION" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --network-security-group "$NSG" \
  --public-ip-address "$PIP02" \
  --accelerated-networking false
```

The target NIC was provisioned successfully with dynamic private IP allocation, accelerated networking disabled, IP forwarding disabled, and the same VNet, subnet, and NSG as Node A.

## Create the Target VM

```bash
az vm create \
  --resource-group "$RG" \
  --name "$VM02" \
  --location "$LOCATION" \
  --nics "$NIC02" \
  --size Standard_D16s_v5 \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202608060 \
  --admin-username opscart \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --os-disk-size-gb 256 \
  --storage-sku Premium_LRS
```

Use the actual SSH public-key path for the environment if it differs from `~/.ssh/id_rsa.pub`.

## Verify the Target VM

```bash
az vm show \
  --resource-group "$RG" \
  --name "$VM02" \
  --show-details \
  --query '{
    name:name,
    powerState:powerState,
    privateIps:privateIps,
    vmSize:hardwareProfile.vmSize
  }' \
  -o json
```

The public IP is intentionally excluded from repository-facing verification output.

## Provisioning Result

Node B was successfully created and entered the `VM running` state.

Confirmed properties:

```text
VM: k8s-llm-cpu-02
region: eastus2
VM size: Standard_D16s_v5
private IP allocation: Dynamic
OS disk: 256 GiB Premium_LRS
network: same VNet/subnet as Node A
accelerated networking: False
IP forwarding: False
```

The assigned private IP is not hard-coded in experiment scripts because it may change if the NIC is recreated.

## Reproducibility Note

This setup matches Node A and Node B in the dimensions most relevant to the experiment: Azure region, VM SKU, OS image build, storage class and size, VNet/subnet, NSG, and NIC behavior.

The two machines are still separate Azure compute instances. Results should therefore be described as a controlled same-SKU, same-network node-relocation experiment, not as two identical physical hosts.

## Cost Control

Deallocate VMs when they are not needed:

```bash
az vm deallocate \
  --resource-group "$RG" \
  --name "$VM02"
```

Managed disks and static public IP resources may continue to incur charges while a VM is deallocated.
