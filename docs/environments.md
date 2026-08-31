# Experiment Environments

## Local Mac / Minikube Baseline

### Host

- Host OS: macOS
- Kubernetes environment: Minikube
- Driver: Docker
- Cluster shape: three nodes

### Cluster Nodes

- `opscart` — control plane
- `opscart-m02` — primary LLM worker
- `opscart-m03` — additional worker reserved for later cold-node/rescheduling experiments

### Effective `opscart-m02` Limits

Kubernetes reported approximately 8 CPUs and ~10 GiB memory.

The underlying Docker container was actually limited to:

- 4 CPUs
- 8 GiB memory

For result interpretation, the Docker limits are treated as the effective worker capacity.

### LLM Container

Controlled 1B/3B resource envelope:

```yaml
requests:
  cpu: "500m"
  memory: "1Gi"
limits:
  cpu: "2"
  memory: "4Gi"
```

### Storage

Controlled recovery baseline:

- Kubernetes PVC
- 5 GiB
- ReadWriteOnce
- mounted at `/root/.ollama`

Initial exploratory storage:

- `emptyDir`

### Hardware

- CPU-only inference
- no discrete GPU acceleration

### Models

- `llama3.2:1b`
- `llama3.2:3b`

### Runtime

- Ollama

### Interpretation Boundary

The local Mac/Minikube results are intended to validate the measurement methodology, recovery-state distinction, storage behavior, readiness semantics, and initial model-size trends.

They are not intended to represent production recovery times.

Repeated same-node PVC-backed recovery may benefit from warm page cache, filesystem cache, container image layers, or storage cache. The local results are therefore described as same-node repeated recovery rather than guaranteed cold-start measurements.

## Azure Cloud CPU Environment

### Host

- Cloud provider: Microsoft Azure
- Region: East US 2
- VM name: `k8s-llm-cpu-01`
- VM size: `Standard_D16s_v5`
- Host CPUs: 16 vCPU
- Host memory: approximately 62.8 GiB
- OS: Ubuntu 22.04.5 LTS
- Kernel: `6.8.0-1064-azure`
- Architecture: `x86_64`
- OS disk: 256 GiB Premium SSD

### Kubernetes Environment

- Minikube profile: `llm-cloud`
- Minikube version: `v1.38.1`
- Kubernetes version: `v1.35.1`
- Minikube topology: single node / control plane
- Container runtime: Docker
- Namespace: `llm-recovery-lab`

The Minikube Docker container was not configured with a CPU quota and had approximately 50 GiB of available memory, so the Ollama container resource limits were treated as the controlled workload boundary for the 1B/3B recovery experiments.

### Azure 1B/3B Controlled Resource Envelope

The Azure 1B and 3B recovery experiments used the same Ollama container envelope as the local controlled baseline:

```yaml
limits:
  cpu: "2"
  memory: "4Gi"
```

The corresponding requests remained lower than the limits.

### Azure 1B/3B Storage

Controlled recovery storage:

- Kubernetes PVC
- 5 GiB
- ReadWriteOnce
- mounted at `/root/.ollama`

The first Azure 1B attempt used a deployment configuration that did not persist the model artifact across pod replacement. That dataset was archived as invalid and is not used in the controlled baseline.

The valid Azure 1B and 3B runs use PVC-backed model storage.

### Azure 1B/3B Models

- `llama3.2:1b`
- `llama3.2:3b`

### Azure 8B Larger-Model Validation

The larger-model validation used:

- Model: `llama3.1:8b`
- Runtime: Ollama
- Storage: 20 GiB PVC
- Strategy: `Recreate`

Resource envelope:

```yaml
requests:
  cpu: "4"
  memory: "8Gi"
limits:
  cpu: "8"
  memory: "16Gi"
```

The 8B experiment is not treated as a controlled continuation of the 1B/3B model-size progression because both the model family and resource envelope changed.

It is classified as a larger-model validation.

### Azure 8B Runtime State Evidence

The final captured 8B pod showed two distinct runtime states.

Idle / unloaded state:

- `ollama list` still showed the `llama3.1:8b` model artifact on persistent storage
- `ollama ps` showed no resident model
- cgroup `memory.current` was approximately 14 MiB

After a new inference request:

- `ollama ps` showed `llama3.1:8b` resident
- Ollama reported approximately 5.7 GB runtime size
- cgroup `memory.current` was approximately 5.27 GiB

This evidence supports the distinction between:

```text
model artifact present
!=
model resident in runtime memory
!=
successful inference
```

The final captured pod recorded:

```text
oom 0
oom_kill 0
oom_group_kill 0
```

This OOM evidence applies to the captured final pod and is not interpreted as a per-run OOM audit of all deleted pods.

### Accelerator Validation

The Azure 8B environment was explicitly checked for discrete GPU exposure.

Observed evidence:

- no matching PCI GPU/display device was detected
- `nvidia-smi` was not installed
- no `/dev/nvidia*` or `/dev/dri/*` GPU device files were exposed inside the Ollama container
- Ollama/llama.cpp logs reported an `AMX` device
- Ollama logs also reported CPU compute buffers

The Azure 8B experiment is therefore treated as CPU execution with AMX-related runtime behavior observed in the logs.

The `ollama ps` `CPU/GPU` percentage field is not used as evidence of a discrete GPU.

### Azure Interpretation Boundary

The Azure results are environment-specific.

They provide a larger Linux cloud CPU validation of the recovery methodology and demonstrate that the separation between Kubernetes/runtime recovery and successful inference persists outside the local Mac environment.

Cross-platform local-vs-Azure comparisons are not treated as pure hardware benchmarks because the host CPU, storage path, cache behavior, topology, and virtualization environment differ.

Repeated pod replacement on the same Minikube node may also benefit from warm host or storage cache.


## Azure Two-Node Cold-Recovery Environment

The cold-node phase used a separate kubeadm/containerd topology rather than the earlier single-node Minikube/Docker environment.

### Nodes

| Role | VM | Kubernetes Role |
|---|---|---|
| Source | `k8s-llm-cpu-01` | kubeadm control plane and schedulable source worker |
| Target | `k8s-llm-cpu-02` | kubeadm worker and cold-recovery target |

Both VMs used the same Azure region, `Standard_D16s_v5` VM size, Ubuntu 22.04 image family, 256 GiB Premium SSD OS-disk class, VNet/subnet, and NSG.

### Kubernetes and Runtime

- Kubernetes: `v1.35.1`
- Cluster bootstrap: kubeadm
- Container runtime: containerd
- Namespace: `llm-recovery-lab`
- Serving runtime: Ollama
- Model: `llama3.2:3b`
- Workload limit: 2 CPU / 4 GiB
- Model artifact placement: pre-staged node-local storage on both nodes

The two-node experiment deliberately excluded model download from T0-T4. Before the first measured relocation, Node B was Kubernetes `Ready`, the model artifact was present, the model was not resident, and node-level Linux filesystem/page caches were dropped.

### Cold-Recovery Evidence Boundary

The initial Node A → Node B measurement is preserved as a one-shot first-use observation because Node B is no longer a pristine first-use target after serving the model.

A separate 10-run same-topology cold control was executed on Node B by scaling Ollama to zero, verifying no serving process remained, dropping node-level Linux filesystem/page caches, and restarting the same workload on the same worker.

The cross-node result is therefore descriptive (`n=1`) and is not treated as evidence of a statistically established node-relocation penalty.

## Planned GPU Environment

The GPU phase used a dedicated Azure kubeadm/containerd environment rather than the earlier CPU Minikube environment.

### Host

- Cloud provider: Microsoft Azure
- Region: South Central US
- VM: `k8s-llm-gpu-01`
- VM size: `Standard_NC8as_T4_v3`
- vCPU: 8
- System memory: 56 GiB
- GPU: NVIDIA Tesla T4
- GPU memory: 16 GiB
- OS: Ubuntu 22.04.5 LTS
- Exact image version: `22.04.202608060`
- Kernel: `6.8.0-1064-azure`
- Architecture: `x86_64`
- OS disk: 64 GiB Standard SSD
- Model/data disk: 128 GiB Premium SSD mounted at `/var/lib/llm-recovery/ollama`
- Azure temporary disk: scratch only

### GPU Software and Kubernetes

- Kubernetes: `v1.35.1`
- Cluster bootstrap: kubeadm
- Container runtime: containerd `2.2.1`
- NVIDIA driver: `610.57.04`
- Reported CUDA compatibility: `13.3`
- NVIDIA Container Toolkit configured for containerd
- NVIDIA Kubernetes device plugin: `v0.20.0`
- Node label: `llm-recovery-role=gpu`
- Kubernetes allocatable GPU: `nvidia.com/gpu=1`
- CNI: Flannel; the exact resolved image/version should be taken from the captured cluster evidence rather than inferred from the floating download URL used during bootstrap

GPU execution was validated through host `nvidia-smi`, Kubernetes GPU allocation, Ollama runtime placement, CUDA log messages, and per-process VRAM usage.

### Storage and Cache Layout

The local PV maps `/var/lib/llm-recovery/ollama` into the Ollama pod at `/root/.ollama`. Model artifacts therefore survive pod and Deployment recreation.

The first GPU baseline left CUDA ComputeCache at its default container-local path, `/root/.nv/ComputeCache`. That state disappeared with each replacement pod. The cache was later redirected to:

```text
/root/.ollama/cuda-compute-cache
```

using `CUDA_CACHE_PATH`, making the reusable CUDA cache persist with the model data.

### GPU Models and Resource Envelopes

**Llama 3.2 3B and Llama 3.1 8B**

```yaml
requests:
  cpu: "500m"
  memory: "1Gi"
  nvidia.com/gpu: "1"
limits:
  cpu: "2"
  memory: "4Gi"
  nvidia.com/gpu: "1"
```

Observed GPU process memory after inference was approximately 2.56 GiB for Llama 3B and 5.15 GiB for Llama 8B.

**Qwen3 14B right-sized formal condition**

```yaml
requests:
  cpu: "500m"
  memory: "4Gi"
  nvidia.com/gpu: "1"
limits:
  cpu: "2"
  memory: "20Gi"
  nvidia.com/gpu: "1"
```

Qwen3 14B used approximately 9.34 GiB of GPU process memory. Diagnostic runs at 4 GiB and 16 GiB host-memory limits showed Ollama disabling mmap due to host-memory pressure. At 20 GiB, the runtime reported `load_mode = mmap` and the formal recovery runs stabilized near a 5 s request duration.

### GPU Interpretation Boundary

The GPU results are environment-specific. CPU and GPU runs use the same serving runtime and overlapping models, but the Azure region, host CPU, storage topology, Kubernetes/container runtime, and accelerator stack differ. CPU-to-GPU comparisons are therefore environment comparisons rather than pure hardware benchmarks.

The GPU phase did not perform a separate controlled host filesystem/page-cache cold experiment. CUDA ComputeCache persistence, VRAM residency, and host-memory sizing were examined directly; Linux page-cache treatment remains a possible follow-up control.

## Cold-Recovery Status

The Azure two-node cold-recovery topology has been completed.

Completed conditions:

1. one first-use Node A → Node B relocation with the target artifact pre-staged and the target model nonresident,
2. ten same-topology cold controls on Node B with node-level filesystem/page caches dropped before each measured startup.

Not yet measured:

- repeated fresh-node cross-node recovery,
- cold model acquisition,
- shared-storage recovery.
