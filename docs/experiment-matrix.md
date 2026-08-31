# Experiment Matrix

Status values:

- `completed` — controlled experiment or validation completed
- `archived` — retained for provenance but not used as the primary controlled result
- `observed` — useful observation, but confounded or outside the primary baseline
- `planned` — not yet executed

## Local Mac / Ollama

| Experiment | Model | Storage | Resource Envelope | Repetitions | Status |
|---|---|---|---|---:|---|
| Runtime + model bootstrap | 1B | `emptyDir` | 2 CPU / 4 GiB | manual | completed |
| Pod replacement with ephemeral model storage | 1B | `emptyDir` | 2 CPU / 4 GiB | manual | completed |
| PVC persistence check | 1B | PVC | 2 CPU / 4 GiB | manual | completed |
| Pilot recovery timing | 1B | PVC | 2 CPU / 4 GiB | 10 | archived |
| Millisecond recovery baseline | 1B | PVC | 2 CPU / 4 GiB | 10 | completed |
| 3B resource test with 1B concurrently resident | 1B + 3B | PVC | 2 CPU / 4 GiB | manual | observed — cgroup OOM under concurrent residency |
| Clean 3B resource test | 3B | PVC | 2 CPU / 4 GiB | manual | completed |
| Millisecond recovery baseline | 3B | PVC | 2 CPU / 4 GiB | 10 | completed |
| Model-presence readiness | 3B | PVC | 2 CPU / 4 GiB | manual | completed — insufficient readiness semantics |
| Inference-aware readiness | 3B | PVC | 2 CPU / 4 GiB | manual rollout | completed |
| EndpointSlice readiness observation | 3B | PVC | 2 CPU / 4 GiB | manual rollout | completed |
| Automated inference-aware readiness rollouts | 3B | PVC | 2 CPU / 4 GiB | 10 | completed |

Local automated readiness summary:

- Runs: 10
- Mean new-endpoint non-serving duration: 47.627 s
- Traffic-gap samples: 0
- Runs containing a sampled traffic gap: 0/10

## Azure Cloud CPU / Ollama

| Experiment | Model | Storage | Resource Envelope | Repetitions | Status |
|---|---|---|---|---:|---|
| Recovery baseline | Llama 3.2 1B | PVC | 2 CPU / 4 GiB | 10 | completed |
| Recovery baseline | Llama 3.2 3B | PVC | 2 CPU / 4 GiB | 10 | completed |
| Inference-aware readiness rollouts | Llama 3.2 3B | PVC | 2 CPU / 4 GiB | 10 | completed |
| Larger-model recovery validation | Llama 3.1 8B | 20 GiB PVC | 8 CPU / 16 GiB limit | 10 | completed |
| Model artifact vs runtime residency evidence | Llama 3.1 8B | 20 GiB PVC | 8 CPU / 16 GiB limit | manual | completed |
| Accelerator validation | Llama 3.1 8B | 20 GiB PVC | 8 CPU / 16 GiB limit | manual | completed — no discrete GPU exposed; AMX observed in runtime logs |
| Same-node warm cache condition | Llama 3.2 3B | PVC | 2 CPU / 4 GiB | 10 | completed |
| Same-node cold filesystem/page-cache condition | Llama 3.2 3B | PVC | 2 CPU / 4 GiB | 10 | completed |
| First-use cross-node recovery, Node A → Node B | Llama 3.2 3B | pre-staged node-local artifact | 2 CPU / 4 GiB | 1 | completed — descriptive first-use observation |
| Same-topology cold control on Node B | Llama 3.2 3B | pre-staged node-local artifact | 2 CPU / 4 GiB | 10 | completed |
| Cold model acquisition | selected | cold acquisition | selected | planned | planned |
| Larger model beyond 8B | >8B | selected | selected | planned | planned |

Azure 3B automated readiness summary:

- Runs: 10
- Mean new-endpoint non-serving duration: 10.968 s
- Traffic-gap samples: 0
- Runs containing a sampled traffic gap: 0/10

Azure 8B larger-model validation summary:

- Runs: 10
- Successful inference runs: 10/10
- Mean Kubernetes Ready: 1.861 s
- Mean runtime reachable: 2.413 s
- Mean functional recovery: 6.477 s
- Mean Ready → inference: 4.616 s
- Mean model load: 3.657 s
- Mean Ollama total: 3.934 s
- Mean post-inference memory: approximately 5.28 GiB

The 8B experiment is not treated as a controlled 3B → 8B model-size comparison because both the model family and resource envelope changed.


Azure cold-node recovery summary:

- First-use cross-node observations: 1
- First-use cross-node functional recovery: 10.160 s
- First-use cross-node Ready → inference: 7.804 s
- First-use cross-node model load: 5.747 s
- Same-topology cold-control runs: 10
- Same-topology control mean functional recovery: 9.665 s
- Same-topology control mean Ready → inference: 7.964 s
- Same-topology control mean model load: 5.621 s

The cross-node observation is descriptive because the first-use condition currently has `n=1`.

## Optional Local Follow-Ups

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Cold-node reschedule to `opscart-m03` | 1B / 3B | Ollama | planned |
| Explicit warm-vs-cold cache comparison | 1B / 3B | Ollama | completed |
| Controlled multi-model residency pressure follow-up | 1B + 3B | Ollama | planned |

## GPU

| Experiment | Model | Storage / Cache | Resource Envelope | Repetitions | Status |
|---|---|---|---|---:|---|
| Initial GPU recovery baseline | Llama 3.2 3B | persistent model, ephemeral CUDA ComputeCache | 2 CPU / 4 GiB + 1 T4 | 10 | completed |
| Persistent CUDA ComputeCache recovery | Llama 3.2 3B | persistent model + persistent CUDA ComputeCache | 2 CPU / 4 GiB + 1 T4 | 10 | completed |
| Host CPU/memory diagnostic | Llama 3.2 3B | persistent model + persistent CUDA ComputeCache | 4 CPU / 8 GiB + 1 T4 | 3 | completed — no material improvement over the 2 CPU / 4 GiB envelope before CUDA-cache persistence |
| Same-process unload/reload diagnostic | Llama 3.2 3B | persistent model + CUDA cache, VRAM emptied | 2 CPU / 4 GiB + 1 T4 | 3 | completed |
| Full Deployment recreation validation | Llama 3.2 3B | persistent model + persistent CUDA ComputeCache | 2 CPU / 4 GiB + 1 T4 | manual | completed |
| Persistent CUDA ComputeCache recovery | Llama 3.1 8B | persistent model + persistent CUDA ComputeCache | 2 CPU / 4 GiB + 1 T4 | 10 | completed |
| Same-process unload/reload diagnostic | Llama 3.1 8B | persistent model + CUDA cache, VRAM emptied | 2 CPU / 4 GiB + 1 T4 | manual | completed |
| Host-memory/mmap diagnostic | Qwen3 14B | persistent model + persistent CUDA ComputeCache | 2 CPU / 4 GiB + 1 T4 | manual | observed — mmap disabled; ~40 s load |
| Host-memory/mmap diagnostic | Qwen3 14B | persistent model + persistent CUDA ComputeCache | 2 CPU / 16 GiB + 1 T4 | manual | observed — mmap still disabled; ~22 s load |
| Right-sized recovery | Qwen3 14B | persistent model + persistent CUDA ComputeCache | 2 CPU / 20 GiB + 1 T4 | 10 | completed — mmap enabled |
| GPU host filesystem/page-cache cold control | selected | persistent model + controlled Linux cache | selected | planned | deferred |
| GPU readiness behavior | selected | selected | selected | planned | planned |

GPU repeated-result summary:

| Condition | K8s Ready | Functional Recovery | Ready → Inference | Model Load | Ollama Total |
|---|---:|---:|---:|---:|---:|
| Llama 3B, ephemeral CUDA cache | ~5.790 s | ~69.748 s | ~63.958 s | ~34.497 s | ~63.683 s |
| Llama 3B, persistent CUDA cache | ~5.721 s | ~9.259 s | ~3.538 s | ~3.142 s | ~3.271 s |
| Llama 8B, persistent CUDA cache | ~5.630 s | ~9.470 s | ~3.840 s | ~3.433 s | ~3.580 s |
| Qwen3 14B, 20 GiB right-sized | ~5.546 s | ~10.826 s | ~5.280 s | ~4.720 s | ~5.010 s |

The Qwen3 14B 4 GiB and 16 GiB measurements are diagnostics, not peer 10-run baselines. The 20 GiB condition is the formal right-sized recovery dataset.

## Runtime Comparison

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Recovery baseline | selected | vLLM | planned |
| Recovery baseline | selected | llama.cpp | planned |
| Readiness behavior | selected | vLLM | planned |
| Readiness behavior | selected | llama.cpp | planned |

## Primary Comparison Dimensions

```text
platform
  local Mac / Azure cloud CPU / cloud GPU

runtime
  Ollama / vLLM / llama.cpp

model
  1B / 3B / 8B-class / larger where feasible

storage
  ephemeral / persistent / cold acquisition

resource envelope
  fixed envelope / expanded envelope

recovery locality
  same node / cold node

readiness
  none-or-runtime-level / model-presence / inference-aware

runtime state
  artifact present / model resident / successful inference
```

## Comparison Rules

Results should only be compared directly when the remaining experimental conditions are controlled or explicitly documented.

In particular:

- Local and Azure 1B/3B recovery results use the same 2 CPU / 4 GiB Ollama resource envelope and support controlled within-platform 1B → 3B comparisons.
- Cross-platform local vs Azure comparisons are environment comparisons, not pure hardware benchmarks; host CPU, storage, cache behavior, and platform topology differ.
- The Azure 8B result is a larger-model validation, not a pure model-size scaling point, because it uses Llama 3.1 and an expanded 8 CPU / 16 GiB resource envelope.
- Repeated same-node recovery may benefit from warm page, filesystem, image-layer, or storage caches.
- The GPU Llama 3B/8B conditions used 2 CPU / 4 GiB, while the formal Qwen3 14B condition used 2 CPU / 20 GiB after host-memory diagnostics showed mmap remained disabled at lower limits.
- CUDA ComputeCache persistence is a separate experimental dimension from Linux filesystem/page-cache state and from VRAM residency.
- Readiness traffic-gap observations are based on sampled EndpointSlice state rather than continuous packet-level measurement.
- The dedicated Azure T4 GPU phase is completed for Ollama 3B, 8B, and Qwen3 14B. The earlier Azure CPU 8B accelerator check remains CPU-only evidence and must not be conflated with the dedicated GPU environment.
- The first-use cross-node condition contains one observation and is interpreted descriptively.
- The 10-run same-topology cold control isolates cold startup on the target worker but is not equivalent to repeated fresh-node relocation.
