# Kubernetes LLM Recovery Lab

Experimental study of recovery behavior for self-hosted LLM inference workloads on Kubernetes.

The project focuses on the gap between **Kubernetes workload recovery** and **functional LLM inference recovery**. A pod may be `Running` or even `Ready` while the requested model is not yet capable of serving inference because the model artifact is missing, model weights are still being loaded, the inference process has not initialized successfully, memory pressure interferes with startup, or readiness semantics are too weak.

The repository is intentionally runtime-neutral. Ollama is the first runtime used to establish and validate the methodology. Planned runtime comparisons include vLLM and llama.cpp.

## Research Questions

1. How quickly does Kubernetes recover an LLM-serving workload after pod replacement?
2. How long after Kubernetes recovery does successful inference become available?
3. How does model size affect functional recovery under controlled resource conditions?
4. How does model storage strategy affect recovery?
5. Can Kubernetes readiness accurately represent inference readiness?
6. Can inference-aware readiness keep a replacement replica out of Service traffic until it can actually execute inference?
7. How do these behaviors change across runtimes, model sizes, CPU/GPU hardware, resource envelopes, and warm/cold recovery conditions?

## Current Scope

### Runtime

- Ollama

### Models

- `llama3.2:1b`
- `llama3.2:3b`
- `llama3.1:8b` — CPU larger-model validation and GPU validation
- `qwen3:14b` — GPU cross-family/right-sized validation

### Platforms

- Local three-node Minikube cluster using the Docker driver
- Azure single-node Minikube/Docker environment for CPU recovery, readiness, larger-model, and warm/cold cache baselines
- Azure two-node kubeadm/containerd environment for cold-node recovery and same-topology cold controls
- Azure single-node kubeadm/containerd GPU environment on `Standard_NC8as_T4_v3` with one NVIDIA T4 (16 GiB VRAM)
- PVC-backed model storage for the original controlled baselines and GPU experiments
- Pre-staged node-local model artifacts for the two-node cold-recovery experiment

### Resource Envelopes

**Local and Azure CPU 1B/3B controlled recovery experiments**

- Ollama CPU limit: 2 CPUs
- Ollama memory limit: 4 GiB

**Azure CPU 8B larger-model validation**

- CPU request: 4 CPUs
- Memory request: 8 GiB
- CPU limit: 8 CPUs
- Memory limit: 16 GiB
- Model storage: 20 GiB PVC

**Azure GPU Llama 3B/8B recovery**

- CPU request: 500m
- Memory request: 1 GiB
- CPU limit: 2 CPUs
- Memory limit: 4 GiB
- GPU request/limit: 1 NVIDIA GPU
- Model data and reusable CUDA ComputeCache persisted under `/root/.ollama`

**Azure GPU Qwen3 14B right-sized recovery**

- CPU request: 500m
- Memory request: 4 GiB
- CPU limit: 2 CPUs
- Memory limit: 20 GiB
- GPU request/limit: 1 NVIDIA GPU
- `think=false` for the measured recovery request

The CPU 8B experiment is intentionally treated as a larger-model validation rather than a controlled 3B → 8B scaling point because both the model family and resource envelope changed. The GPU Qwen3 14B result is also treated as a right-sized cross-family validation, not as a fixed-envelope model-size scaling point.

## Recovery States

The experiments distinguish these stages:

```text
Pod replacement
    |
    v
Kubernetes container Running
    |
    v
Kubernetes Ready
    |
    v
Inference runtime reachable
    |
    v
Model artifact available
    |
    v
Model loaded / inference process initialized
    |
    v
Successful inference
```

`Running`, `Ready`, runtime reachability, model presence, model residency, and successful inference are treated as separate states.

## Current Findings

### Azure 3B Warm vs Node-Level Cold Cache, 10 Runs per Condition

| Metric | Warm | Cold | Change |
|---|---:|---:|---:|
| Kubernetes Ready | 1.883 s | 1.834 s | -2.59% |
| Runtime reachable | 2.460 s | 2.378 s | -3.31% |
| Functional recovery | 7.582 s | 8.092 s | +6.72% |
| Ready → inference | 5.699 s | 6.258 s | +9.79% |
| Model load | 3.952 s | 4.606 s | +16.56% |
| Ollama total | 4.992 s | 5.586 s | +11.90% |


### Azure 3B Cold-Node Recovery

A separate two-node Azure kubeadm/containerd topology was used to measure first-use recovery from Node A to Node B while keeping the model artifact pre-staged on the target and verifying that the model was not resident before the first measured inference.

The preserved first-use cross-node observation produced:

| Metric | Cross-Node First Use |
|---|---:|
| Kubernetes Ready | 2.356 s |
| Runtime reachable | 2.562 s |
| Functional recovery | 10.160 s |
| Ready → inference | 7.804 s |
| Request wall time | 7.371 s |
| Model load | 5.747 s |
| Ollama total | 7.256 s |

A 10-run same-topology cold control was then executed on Node B. Before each run, the Ollama Deployment was scaled to zero, absence of a model-serving process was verified, and node-level Linux filesystem/page caches were dropped.

| Metric | Same-Topology Cold Control Mean | Cross-Node First Use | Difference |
|---|---:|---:|---:|
| Kubernetes Ready | 1.700 s | 2.356 s | +38.57% |
| Runtime reachable | 2.401 s | 2.562 s | +6.70% |
| Functional recovery | 9.665 s | 10.160 s | +5.13% |
| Ready → inference | 7.964 s | 7.804 s | -2.01% |
| Request wall time | 7.042 s | 7.371 s | +4.67% |
| Model load | 5.621 s | 5.747 s | +2.24% |
| Ollama total | 6.927 s | 7.256 s | +4.74% |

Because the cross-node condition contains one first-use observation, these differences are descriptive rather than evidence of a statistically established node-relocation penalty. In this setup, once the model artifact was already available on the destination node, cold model loading accounted for most of the inference-recovery interval.

### Local 1B vs 3B Recovery Baseline

Ten repeated same-node PVC-backed pod replacements were measured for each model using the same local CPU-only environment and the same 2 CPU / 4 GiB Ollama resource envelope.

| Metric | Llama 3.2 1B | Llama 3.2 3B | Change |
|---|---:|---:|---:|
| Kubernetes Ready | 1.657 s | 1.962 s | +18.41% |
| Runtime reachable | 2.429 s | 2.437 s | +0.32% |
| Functional recovery | 11.112 s | 16.272 s | +46.44% |
| Ready → inference | 9.455 s | 14.310 s | +51.35% |
| Model load | 5.508 s | 8.596 s | +56.08% |
| Ollama total | 8.462 s | 13.566 s | +60.32% |

The 3B model used approximately **2.725 GiB mean post-inference memory**.

In this environment, Kubernetes and runtime recovery changed relatively little between 1B and 3B, while model loading and functional inference recovery increased substantially.

These values are environment-specific and are not presented as a universal model-size scaling law.

### Azure CPU 1B vs 3B Recovery Validation

The same recovery methodology was repeated on an Azure Linux VM. Both models used the same 2 CPU / 4 GiB Ollama resource envelope and PVC-backed model storage.

| Metric | Llama 3.2 1B | Llama 3.2 3B |
|---|---:|---:|
| Kubernetes Ready | 1.606 s | 1.689 s |
| Runtime reachable | 2.186 s | 2.171 s |
| Functional recovery | 5.433 s | 7.734 s |
| Ready → inference | 3.827 s | 6.045 s |
| Model load | 2.161 s | 3.962 s |
| Ollama total | 3.123 s | 5.437 s |

The Azure environment reduced inference-dependent recovery substantially compared with the local environment, while Kubernetes and runtime recovery changed much less.

Across both environments, Kubernetes/runtime recovery consistently preceded successful inference, and the Ready → inference gap increased from 1B to 3B under the same 2 CPU / 4 GiB resource envelope.

### Azure 8B Larger-Model Validation

`llama3.1:8b` was tested in the Azure environment using an expanded 8 CPU / 16 GiB container limit and a 20 GiB PVC.

Ten pod-replacement trials completed successful inference.

| Metric | Llama 3.1 8B |
|---|---:|
| Kubernetes Ready | 1.861 s |
| Runtime reachable | 2.413 s |
| Functional recovery | 6.477 s |
| Ready → inference | 4.616 s |
| Request wall time | 4.049 s |
| Model load | 3.657 s |
| Ollama total | 3.934 s |
| Mean post-inference memory | ~5.28 GiB |

This result is **not** used as a pure 3B → 8B model-size comparison. The 8B workload uses Llama 3.1 rather than Llama 3.2 and receives a substantially larger CPU/memory envelope.

The result instead demonstrates that a larger model can remain within a similar functional-recovery range when additional compute and memory are provided.

### Model Artifact Presence vs Runtime Residency

The Azure 8B evidence captures both an idle/unloaded state and an active/resident state.

After the model had been unloaded from active runtime memory:

```text
ollama list:
llama3.1:8b    ~4.9 GB

ollama ps:
no resident model

cgroup memory.current:
~14 MiB
```

After a new inference request:

```text
ollama ps:
llama3.1:8b resident

reported runtime size:
~5.7 GB

cgroup memory.current:
~5.27 GiB
```

This directly illustrates an important distinction:

```text
model artifact present on persistent storage
!=
model resident in runtime memory
!=
successful inference
```

The final captured 8B pod also recorded `oom_kill 0`. This is evidence for that captured pod, not a claim that every deleted pod in the repeated experiment had its cgroup OOM counters inspected individually.

### Accelerator Validation

The Azure 8B environment was checked for discrete GPU exposure.

Observed evidence:

- no matching PCI GPU/display device was detected,
- `nvidia-smi` was not installed,
- no GPU device files were exposed inside the Ollama container,
- Ollama/llama.cpp logs reported an `AMX` device and CPU compute buffers.

The Azure 8B experiment is therefore treated as a CPU execution experiment with AMX-related runtime behavior observed in the logs. The `ollama ps` `CPU/GPU` percentage field is not used as evidence of a discrete GPU.

## Azure T4 GPU Recovery Findings

The GPU phase used Ollama on an Azure `Standard_NC8as_T4_v3` VM with one NVIDIA T4. GPU execution was independently confirmed through Kubernetes `nvidia.com/gpu=1` allocation, `nvidia-smi` process/VRAM evidence, Ollama `100% GPU` placement, and CUDA runtime logs.

### Llama 3.2 3B: CUDA ComputeCache Persistence

The first 10-run GPU baseline persisted the model artifact but left CUDA ComputeCache in the disposable container filesystem. Kubernetes/runtime recovery was fast, but first inference was not:

| Metric | Ephemeral CUDA cache | Persistent CUDA cache |
|---|---:|---:|
| Kubernetes Ready | ~5.790 s | ~5.721 s |
| Runtime reachable | ~5.911 s | ~5.845 s |
| Functional recovery | ~69.748 s | ~9.259 s |
| Ready → inference | ~63.958 s | ~3.538 s |
| Ollama load | ~34.497 s | ~3.142 s |
| Ollama total | ~63.683 s | ~3.271 s |

The reusable cache was redirected to `/root/.ollama/cuda-compute-cache`, which is on persistent model storage. A full Deployment deletion and recreation retained the model artifact and cache and produced a first request of ~3.55 s. This supports a narrower conclusion than “GPU is fast”: accelerator/runtime initialization state can dominate functional recovery when it is discarded with the pod.

### Llama 3.1 8B GPU Validation

With the same 2 CPU / 4 GiB workload limit and persistent CUDA ComputeCache, 10 recovery runs produced:

| Metric | Mean |
|---|---:|
| Kubernetes Ready | ~5.630 s |
| Runtime reachable | ~5.751 s |
| Functional recovery | ~9.470 s |
| Ready → inference | ~3.840 s |
| Ollama load | ~3.433 s |
| Ollama total | ~3.580 s |
| GPU process memory | ~5.15 GiB |

### Qwen3 14B Host-Memory Threshold

Qwen3 14B fit fully in T4 VRAM, but the serving runtime remained sensitive to the container host-memory envelope. At a 4 GiB limit, Ollama logged that mmap was disabled due to host-memory pressure and model load was ~40 s in diagnostic runs. At 16 GiB the mmap-disabled path remained and load was still ~22 s. At a 20 GiB limit, Ollama switched to `load_mode = mmap`.

The formal 10-run, 20 GiB, persistent-CUDA-cache condition produced:

| Metric | Mean |
|---|---:|
| Kubernetes Ready | ~5.546 s |
| Runtime reachable | ~5.667 s |
| Functional recovery | ~10.826 s |
| Ready → inference | ~5.280 s |
| Ollama load | ~4.720 s |
| Ollama total | ~5.010 s |
| GPU process memory | ~9.34 GiB |

The Qwen result shows that fitting a model in VRAM does not by itself guarantee fast recovery; host-memory sizing can change the runtime loading path and dominate first-inference latency.

## Inference-Aware Readiness

A model-presence readiness probe based on `ollama list` was insufficient because a model artifact can exist on the PVC before it is actually usable for inference.

A lightweight helper sidecar was introduced. The helper performs a minimal real inference request and exposes `/ready` for the Ollama container's Kubernetes readiness probe.

During rolling replacement, EndpointSlice conditions were sampled to determine whether at least one Service endpoint remained both:

```text
ready=true
serving=true
```

### Readiness Results

| Metric | Local 3B | Azure CPU 3B |
|---|---:|---:|
| Runs | 10 | 10 |
| Mean new-endpoint non-serving duration | 47.627 s | 10.968 s |
| Median | 50.388 s | 10.852 s |
| Minimum | 34.252 s | 10.278 s |
| Maximum | 68.984 s | 11.437 s |
| Traffic-gap samples | 0 | 0 |
| Runs containing a sampled traffic gap | 0/10 | 0/10 |

In all 20 measured rollouts, no sampled interval contained zero endpoints satisfying both `ready=true` and `serving=true`.

This is a **sampled EndpointSlice observation**, not a packet-level or continuous-time availability guarantee.

The replacement replica remained non-serving until the inference-aware readiness helper completed a successful inference request. This aligned Service traffic eligibility with functional model readiness rather than container startup alone.

The rollout behavior observed was:

```text
old replica:
ready=true
serving=true

new replica while inference readiness is not satisfied:
ready=false
serving=false

new replica after successful readiness inference:
ready=true
serving=true

old replica during termination:
ready=false
serving=false
terminating=true
```

## Storage Findings

### Ephemeral Model Storage

With `/root/.ollama` backed by `emptyDir`:

```text
pod replacement
→ Ollama runtime returns
→ model artifact is lost
→ inference cannot resume until the model is restored
```

### PVC-Backed Model Storage

With `/root/.ollama` backed by a PVC:

```text
pod replacement
→ Ollama runtime returns
→ model artifact survives
→ first inference still incurs model-loading / initialization cost
```

Persistent model storage therefore solves artifact persistence, but it does not eliminate functional inference recovery time.

## Concurrent Model Residency Observation

During one local experiment, the 1B model remained resident while the 3B model was loaded under a 4 GiB container memory limit.

The Ollama parent process and Kubernetes pod remained running, while the `llama-server` child process was cgroup OOM-killed. `/sys/fs/cgroup/memory.events` recorded `oom_kill 1`.

After the 1B probe was removed and the 3B model was tested alone under the same 4 GiB limit, inference succeeded.

This case is treated as a **multi-model residency pressure observation**, not evidence that the 3B model alone requires more than 4 GiB.

## Repository Layout

```text
.
├── analysis/
├── docs/
├── manifests/
│   ├── readiness/
│   ├── runtimes/
│   │   └── ollama/
│   └── storage/
├── results/
│   ├── archive/
│   ├── cloud-cpu/
│   └── local-mac/
└── scripts/
    ├── archive/
    ├── cloud/
    ├── readiness/
    └── recovery/
```

## Evidence Policy

Raw measurements and the scripts that produced them are preserved in the repository.

Pilot or invalid data is retained under `results/archive/` with explanatory notes rather than silently deleted or reused as controlled evidence.

Controlled baselines remain under the platform/runtime/model path that produced them.

When methodology changes materially, a new script or artifact is created rather than overwriting the earlier evidence.

Derived analysis belongs under `analysis/`; raw measurements remain under `results/`.

## Experimental Boundaries

The current evidence supports several environment-specific observations, but it does not establish universal LLM recovery behavior.

Important boundaries include:

- repeated PVC-backed recovery can benefit from warm host/storage cache unless cache state is explicitly controlled,
- the first-use cross-node condition contains one preserved observation (`n=1`),
- the 10-run same-topology cold control is not equivalent to repeated fresh-node relocation,
- the CPU 8B validation changed both model family and resource envelope,
- the GPU Qwen3 14B right-sized result uses a larger host-memory envelope than the GPU Llama 3B/8B conditions,
- GPU host filesystem/page-cache cold treatment was not independently repeated in the T4 phase,
- readiness observations are sampled rather than continuous,
- only Ollama has been evaluated so far,
- cold model acquisition and shared-storage recovery have not yet been measured,
- CPU-vs-GPU results are environment comparisons rather than pure accelerator benchmarks because host CPU, storage, region, topology, and container-runtime details differ.

Direct comparisons should only be made when experimental conditions are controlled or when differences are explicitly documented.

## Next Phases

1. Derive consolidated GPU and CPU/GPU analysis tables from the preserved raw CSVs.
2. Runtime comparison across Ollama, vLLM, and llama.cpp using controlled model/hardware conditions.
3. Cold model acquisition and shared-storage recovery.
4. Repeated fresh-node cross-node recovery where the additional infrastructure cost is justified.
5. Additional GPU cache controls, including host filesystem/page-cache treatment, only if needed to support a specific claim.
6. Additional steady-state inference measurements kept separate from recovery measurements.

See:

- `docs/methodology.md`
- `docs/environments.md`
- `docs/experiment-matrix.md`
- `docs/gpu-experiment-design.md`

## Status

Work in progress.

The repository now contains:

- local 1B and 3B controlled recovery baselines,
- Azure CPU 1B and 3B recovery validation,
- local and Azure 3B inference-aware readiness rollouts,
- Azure CPU 8B larger-model recovery validation,
- model artifact vs runtime residency evidence,
- Azure 3B warm vs node-level cold filesystem/page-cache recovery analysis,
- one preserved Azure first-use cross-node recovery observation,
- a 10-run same-topology cold control on the Azure target worker,
- Azure T4 GPU environment and accelerator evidence,
- Llama 3B GPU recovery with ephemeral and persistent CUDA ComputeCache conditions,
- Llama 8B GPU recovery with persistent CUDA ComputeCache,
- Qwen3 14B GPU right-sizing/mmap diagnostics and a 10-run right-sized recovery dataset.

The current evidence distinguishes Kubernetes workload recovery, serving-runtime recovery, model-artifact availability, accelerator/runtime cache state, model residency, and successful inference. The next major validation dimension is serving-runtime comparison rather than additional same-runtime model collection.

