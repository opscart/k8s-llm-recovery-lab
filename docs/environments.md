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

## Planned GPU Environment

GPU validation remains a future phase.

The GPU environment should record:

- GPU model
- VRAM
- driver version
- CUDA/ROCm version where applicable
- runtime version
- model precision/quantization
- Kubernetes device-plugin configuration
- container CPU/memory limits
- storage configuration

Representative models, rather than every local model, may be repeated on GPU.

## Planned Cold-Recovery Topology

Future experiments should distinguish:

1. same-node repeated recovery,
2. cold-node rescheduling,
3. persistent/shared model storage,
4. cold model acquisition,
5. already-resident/warm model serving.

`opscart-m03` can be used for an initial local same-cluster cold-node experiment, while a future cloud topology can provide a cleaner larger-scale cold-node validation.
