# Azure T4 GPU Provisioning and Bootstrap

## Approved target

```text
Region: South Central US
VM SKU: Standard_NC8as_T4_v3
GPU: NVIDIA T4
GPU count: 1
GPU memory: 16 GiB
vCPU: 8
System memory: 56 GiB
Approved NCASv3_T4 family quota: 8 vCPUs
```

This remains the planned environment until provisioning and environment capture confirm the observed configuration.

## Storage

```text
OS disk: 64 GiB Standard SSD LRS
Model/data disk: 128 GiB Premium SSD LRS
Model mount: /var/lib/llm-recovery/ollama
Temporary disk: scratch only
```

## Exact Ubuntu image

Resolve and review an exact Ubuntu 22.04 Gen2 image before provisioning:

```bash
az vm image list   --location southcentralus   --publisher Canonical   --offer 0001-com-ubuntu-server-jammy   --sku 22_04-lts-gen2   --all   --query "sort_by(@,&version)[-5:].{Version:version,URN:urn}"   -o table
```

Then set:

```bash
export IMAGE_URN='Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:<exact-version>'
```

Do not use `latest` in frozen evidence.

## Preflight only

The provisioning script creates nothing unless `EXECUTE=1`:

```bash
IMAGE_URN="$IMAGE_URN" scripts/cloud/azure/provision-gpu-t4.sh
```

It checks authentication, quota, SKU restrictions, and the exact image URN.

## Provision

After reviewing preflight output:

```bash
IMAGE_URN="$IMAGE_URN" EXECUTE=1 scripts/cloud/azure/provision-gpu-t4.sh
```

The flow creates a dedicated resource group, the T4 VM, a 128-GiB Premium model disk, and applies Azure's NVIDIA GPU Driver Extension.

Azure documents that the GPU driver extension can reboot the VM during installation. After it completes, do not continue until:

```bash
nvidia-smi
```

shows the T4. Record the exact driver version and reported CUDA compatibility.

## Prepare the model disk

First identify the attached 128-GiB disk:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
```

Do not assume a device name.

Then run:

```bash
sudo DATA_DEVICE=/dev/<verified-device>   scripts/cloud/prepare-gpu-node.sh
```

The script formats the selected block device only if no filesystem is detected.

## Kubernetes and GPU integration

The GPU preparation reuses `scripts/cloud/prepare-kubeadm-control-plane.sh` so Kubernetes/containerd stay aligned with the completed CPU kubeadm phase.

It then:

1. labels the node `llm-recovery-role=gpu`
2. installs NVIDIA Container Toolkit
3. configures containerd with `nvidia-ctk`
4. restarts containerd and kubelet
5. applies pinned NVIDIA Kubernetes device plugin `v0.20.0`
6. requires Kubernetes to advertise `nvidia.com/gpu=1`

NVIDIA's current Container Toolkit documentation recommends `nvidia-ctk runtime configure --runtime=containerd` followed by a containerd restart.

## CNI

The reused kubeadm script intentionally does not install a CNI unless `CNI_MANIFEST` is supplied.

Choose and review the CNI before starting the paid VM session. Prefer the same CNI family used in the earlier kubeadm cold-node experiment.

## Deploy the experiment

After Kubernetes and CNI are healthy:

```bash
kubectl create namespace llm-recovery-lab   --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f manifests/storage/ollama-gpu-local-pv.yaml
kubectl apply -f manifests/runtimes/ollama/ollama-gpu.yaml
```

Verify the pod requests one GPU and the node reports one allocatable GPU.

## Evidence

Before timed recovery runs:

```bash
scripts/cloud/capture-gpu-environment.sh
```

Then stage `llama3.2:3b` before measurements. The model download is excluded from the first recovery timing.

## Measurement order

```text
1. 3B GPU baseline, 10 runs
2. 3B warm filesystem/page-cache condition, 10 runs
3. 3B cold filesystem/page-cache condition, 10 runs
4. 8B GPU baseline, 10 runs
```

Warm/cold host-cache state must be kept conceptually separate from VRAM residency.

## Cost control

Temporary stop:

```bash
az vm deallocate   --resource-group rg-k8s-llm-gpu-recovery   --name k8s-llm-gpu-01
```

For final cleanup, delete the dedicated resource group only after raw evidence is verified and pushed.

