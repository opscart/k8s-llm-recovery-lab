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
| Same-node warm recovery | selected | PVC | selected | planned | planned |
| Cold-node recovery | selected | selected | selected | planned | planned |
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

## Local Next Steps

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Cold-node reschedule to `opscart-m03` | 1B / 3B | Ollama | planned |
| Explicit warm-vs-cold cache comparison | 1B / 3B | Ollama | completed |
| Controlled multi-model residency pressure follow-up | 1B + 3B | Ollama | planned |

## GPU

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Functional recovery | 3B | Ollama | planned |
| Functional recovery | 7B/8B | Ollama | planned |
| Readiness behavior | selected | Ollama | planned |
| CPU vs GPU comparison | selected | Ollama | planned |

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
- Readiness traffic-gap observations are based on sampled EndpointSlice state rather than continuous packet-level measurement.
- GPU experiments remain planned; the Azure CPU validation did not expose a discrete GPU.
