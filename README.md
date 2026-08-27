# Kubernetes LLM Recovery Lab

Experimental study of recovery behavior for self-hosted LLM inference workloads on Kubernetes.

The project focuses on the gap between **Kubernetes workload recovery** and **functional LLM inference recovery**. A pod may be `Running` or even `Ready` while the requested model is not yet capable of serving inference because model artifacts are missing, model weights are still loading, memory pressure prevents the inference process from starting, or readiness semantics are too weak.

The repository is intentionally runtime-neutral. Ollama is the first runtime used to establish the methodology. Planned runtime comparisons include vLLM and llama.cpp.

## Research Questions

1. How quickly does Kubernetes recover an LLM-serving workload after pod replacement?
2. How long after Kubernetes recovery does successful inference become available?
3. How does model size affect functional recovery?
4. How does model storage strategy affect recovery?
5. Can Kubernetes readiness accurately represent inference readiness?
6. Can inference-aware readiness keep a replacement replica out of Service traffic until it can actually execute inference?
7. How do these behaviors change across runtimes, model sizes, CPU/GPU hardware, and warm/cold recovery conditions?

## Current Scope

### Runtime
- Ollama

### Models
- `llama3.2:1b`
- `llama3.2:3b`

### Platform
- Local three-node Minikube cluster using Docker driver
- CPU-only inference
- PVC-backed model storage for the controlled recovery baselines

Cloud CPU, larger-model, GPU, cold-node, and multi-runtime experiments are planned next.

## Current Local Environment

Effective LLM worker limits:

- Worker: `opscart-m02`
- Minikube driver: Docker
- Docker CPU limit: 4 CPUs
- Docker memory limit: 8 GiB
- Ollama CPU limit: 2 CPUs
- Ollama memory limit: 4 GiB
- Accelerator: CPU only

Kubernetes reported more CPU/memory than the Docker container was actually allowed to use, so the Docker limits are treated as the effective machine boundary.

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
Model available / loaded
    |
    v
Successful inference
```

`Running`, `Ready`, runtime reachability, model presence, and successful inference are treated as separate states.

## Current Findings


### Local 1B vs 3B Recovery Baseline

Ten repeated PVC-backed pod replacements were measured for each model using the same local CPU-only environment.

| Metric | Llama 3.2 1B | Llama 3.2 3B | Change |
|---|---:|---:|---:|
| Kubernetes Ready | 1.657 s | 1.962 s | +18.41% |
| Runtime reachable | 2.429 s | 2.437 s | +0.32% |
| Functional recovery | 11.112 s | 16.272 s | +46.44% |
| Ready → inference | 9.455 s | 14.310 s | +51.35% |
| Model load | 5.508 s | 8.596 s | +56.08% |
| Ollama total | 8.462 s | 13.566 s | +60.32% |

The 3B model used approximately **2.725 GiB mean post-inference memory**.

In this environment, Kubernetes/runtime recovery changed relatively little between 1B and 3B, while model loading and functional inference recovery increased substantially.

These values are specific to the local Minikube CPU-only environment and should not be generalized beyond this configuration without additional cloud CPU/GPU validation.


### Inference-Aware Readiness Rollouts

Ten rolling replacements of the 3B Ollama workload were measured with inference-aware readiness enabled.

| Metric | Result |
|---|---:|
| Runs | 10 |
| Mean new-endpoint non-serving duration | 47.627 s |
| Median | 50.388 s |
| Minimum | 34.252 s |
| Maximum | 68.984 s |
| Traffic-gap samples | 0 |
| Runs containing a traffic gap | 0/10 |

During every sampled interval, at least one EndpointSlice endpoint remained `ready=true` and `serving=true`.

The replacement replica remained non-serving until the readiness helper completed a real inference request. This aligned Service traffic eligibility with functional model readiness rather than container startup alone.

The absolute readiness durations are specific to the current CPU-only local environment.

### Ephemeral model storage

With `/root/.ollama` backed by `emptyDir`:

```text
pod replacement
→ Ollama runtime returns
→ model artifact is lost
→ inference cannot resume until the model is restored
```

### PVC-backed model storage

With `/root/.ollama` backed by a PVC:

```text
pod replacement
→ Ollama runtime returns
→ model artifact survives
→ first inference still incurs model-loading cost
```

### 1B vs 3B recovery

Ten repeated same-node PVC-backed recovery runs were collected for each model.

| Metric | Llama 3.2 1B | Llama 3.2 3B |
|---|---:|---:|
| Kubernetes Ready | ~1.66 s | ~1.96 s |
| Runtime reachable | ~2.43 s | ~2.44 s |
| Functional recovery | ~11.11 s | ~16.27 s |
| Ready → successful inference | ~9.45 s | ~14.31 s |
| Model load | ~5.51 s | ~8.60 s |
| First Ollama request total | ~8.46 s | ~13.57 s |

These values are environment-specific. The current observation is that Kubernetes/runtime recovery remained relatively similar while functional recovery increased with model size.

### Concurrent model residency

During one experiment, the 1B model remained resident while the 3B model was loaded under a 4 GiB container memory limit.

The Ollama parent process and Kubernetes pod remained running, while the `llama-server` child process was cgroup OOM-killed. `/sys/fs/cgroup/memory.events` recorded `oom_kill 1`.

After the 1B probe was removed and the 3B model was tested alone under the same 4 GiB limit, inference succeeded.

This case is treated as a **multi-model residency pressure observation**, not evidence that 3B alone requires more than 4 GiB.

### Inference-aware readiness

A model-presence probe based on `ollama list` was insufficient because a model artifact can exist on the PVC before it is actually usable for inference.

A lightweight helper sidecar was then introduced. The helper performs a minimal inference request and exposes `/ready` for the Ollama container's Kubernetes readiness probe.

During rolling replacement, EndpointSlice state showed the intended behavior:

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

This demonstrates that the replacement replica can be withheld from Service traffic until actual inference succeeds.

## Repository Layout

```text
.
├── analysis/
├── docs/
├── manifests/
│   ├── readiness/
│   ├── runtimes/
│   │   ├── llama-cpp/
│   │   ├── ollama/
│   │   └── vllm/
│   └── storage/
├── results/
│   ├── archive/
│   ├── cloud-cpu/
│   ├── cloud-gpu/
│   └── local-mac/
└── scripts/
    ├── archive/
    ├── readiness/
    ├── recovery/
    └── utilities/
```

## Evidence Policy

Raw measurements and the scripts that produced them are preserved in the repository.

Pilot data is retained under `results/archive/`, while controlled baselines remain under the platform/runtime/model path that produced them.

When methodology changes materially, a new script is created rather than overwriting the earlier one.

## Next Phases

1. Larger Linux cloud CPU host.
2. 1B / 3B / 7B-or-8B model-size progression.
3. Warm same-node vs cold-node recovery.
4. Persistent/shared storage vs cold model acquisition.
5. Representative GPU validation.
6. Runtime comparison across Ollama, vLLM, and llama.cpp.

See:
- `docs/methodology.md`
- `docs/environments.md`
- `docs/experiment-matrix.md`

## Status

Work in progress. Current results establish the local CPU baseline and the first inference-aware readiness mitigation. Broader claims require additional model sizes, hardware classes, recovery conditions, and inference runtimes.
