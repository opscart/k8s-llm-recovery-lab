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

Initial controlled resource envelope:

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
- no GPU acceleration

### Models

- `llama3.2:1b`
- `llama3.2:3b`

### Runtime

- Ollama

## Interpretation Boundary

The local Mac/Minikube results are intended to validate the measurement methodology, recovery-state distinction, storage behavior, readiness semantics, and initial model-size trends.

They are not intended to represent production recovery times.

## Planned Cloud CPU Environment

Target characteristics:

- Linux VM
- approximately 16 vCPU
- 32–64 GiB RAM
- fast SSD
- Kubernetes or a reproducible single-node/multi-node Kubernetes environment

Planned model progression:

- 1B
- 3B
- 7B/8B-class quantized model
- potentially larger models if resources permit

The exact VM SKU, CPU model, disk configuration, Kubernetes version, container runtime, and network characteristics must be recorded before results are collected.

## Planned GPU Environment

GPU validation follows the cloud CPU phase.

The GPU environment must record:

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

`opscart-m03` can be used for an initial local same-cluster cold-node experiment, while cloud infrastructure should provide a cleaner larger-scale validation.
