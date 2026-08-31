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

This is the environment used for the completed GPU recovery phase. Environment capture confirmed the T4, 8 vCPU / 56 GiB host configuration, Ubuntu 22.04.5, Kubernetes 1.35.1, and the NVIDIA software stack described below.

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
export IMAGE_URN='Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202608060'
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
3. configures containerd with `nvidia-ctk` and sets the NVIDIA runtime as the default runtime for this GPU node
4. restarts containerd and kubelet
5. applies pinned NVIDIA Kubernetes device plugin `v0.20.0`
6. requires Kubernetes to advertise `nvidia.com/gpu=1`

The completed bootstrap required `nvidia-ctk runtime configure --runtime=containerd --set-as-default` followed by containerd and kubelet restarts. Without the default-runtime setting, the NVIDIA device plugin failed to initialize NVML inside its container even though the host driver was healthy.

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

## Observed environment

The captured environment reported:

```text
OS: Ubuntu 22.04.5 LTS
Kernel: 6.8.0-1064-azure
Kubernetes: 1.35.1
Container runtime: containerd 2.2.1
GPU: Tesla T4, 16 GiB
NVIDIA driver: 610.57.04
CUDA compatibility: 13.3
Kubernetes allocatable GPU: nvidia.com/gpu=1
```

GPU use was validated with host `nvidia-smi`, Kubernetes allocation, Ollama `100% GPU` placement, CUDA logs, and VRAM process residency. Raw environment evidence is preserved under `results/cloud-gpu/environment/`.

## Measurement order

The completed measurement sequence differed from the original warm/cold plan after the first T4 baseline exposed a large accelerator-cache effect:

```text
1. Llama 3.2 3B, persistent model + ephemeral CUDA ComputeCache, 10 runs
2. Llama 3.2 3B, persistent CUDA ComputeCache, 10 runs
3. Llama 3.2 3B host CPU/memory diagnostic, 3 runs
4. Llama 3.2 3B same-process unload/reload and full Deployment recreation validations
5. Llama 3.1 8B, persistent CUDA ComputeCache, 10 runs
6. Qwen3 14B host-memory/mmap diagnostics at 4 GiB, 16 GiB, and 20 GiB limits
7. Qwen3 14B right-sized 20 GiB + persistent CUDA ComputeCache, 10 runs
```

The GPU phase did not execute a separate Linux filesystem/page-cache cold series. That dimension remains distinct from CUDA ComputeCache persistence and VRAM residency and can be added later if required by a specific claim.

The model download/pull for each model was completed before the corresponding timed recovery series.

## Cost control

Temporary stop:

```bash
az vm deallocate   --resource-group rg-k8s-llm-gpu-recovery   --name k8s-llm-gpu-01
```

For final cleanup, delete the dedicated resource group only after raw evidence is verified and pushed.

