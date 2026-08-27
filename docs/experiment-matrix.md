# Experiment Matrix

Legend:

- ✅ completed
- 🟡 in progress / partial
- ⬜ planned
- ⚠️ observed but confounded or not part of the primary baseline

## Local Mac / Ollama

| Experiment | Model | Storage | Resource Envelope | Repetitions | Status |
|---|---|---|---|---:|---|
| Runtime + model bootstrap | 1B | `emptyDir` | 2 CPU / 4 GiB | manual | ✅ |
| Pod replacement with ephemeral model storage | 1B | `emptyDir` | 2 CPU / 4 GiB | manual | ✅ |
| PVC persistence check | 1B | PVC | 2 CPU / 4 GiB | manual | ✅ |
| Pilot recovery timing | 1B | PVC | 2 CPU / 4 GiB | 10 | ✅ archived |
| Millisecond recovery baseline | 1B | PVC | 2 CPU / 4 GiB | 10 | ✅ |
| 3B resource test with 1B concurrently resident | 1B + 3B | PVC | 2 CPU / 4 GiB | manual | ⚠️ cgroup OOM |
| Clean 3B resource test | 3B | PVC | 2 CPU / 4 GiB | manual | ✅ |
| Millisecond recovery baseline | 3B | PVC | 2 CPU / 4 GiB | 10 | ✅ |
| Model-presence readiness | 3B | PVC | 2 CPU / 4 GiB | manual | ✅ insufficient by design |
| Inference-aware readiness | 3B | PVC | 2 CPU / 4 GiB | manual rollout | ✅ |
| EndpointSlice readiness observation | 3B | PVC | 2 CPU / 4 GiB | manual rollout | ✅ |
| Automated inference-aware readiness rollouts | 3B | PVC | 2 CPU / 4 GiB | 10 | ✅ 

---
10 runs
0 traffic-gap samples
mean non-serving duration 47.627 s

## Local Next Steps

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Cold-node reschedule to `opscart-m03` | 1B / 3B | Ollama | ⬜ |
| Explicit warm-vs-cold cache comparison | 1B / 3B | Ollama | ⬜ |
| Multi-model residency pressure | 1B + 3B | Ollama | ⬜ controlled follow-up |

## Cloud CPU

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Recovery baseline | 1B | Ollama | ⬜ |
| Recovery baseline | 3B | Ollama | ⬜ |
| Recovery baseline | 7B/8B | Ollama | ⬜ |
| Larger model if feasible | >8B | Ollama | ⬜ |
| Same-node warm recovery | selected | Ollama | ⬜ |
| Cold-node recovery | selected | Ollama | ⬜ |
| Cold model acquisition | selected | Ollama | ⬜ |
| Inference-aware readiness | selected | Ollama | ⬜ |

## GPU

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Functional recovery | 3B | Ollama | ⬜ |
| Functional recovery | 7B/8B | Ollama | ⬜ |
| Readiness gap | selected | Ollama | ⬜ |
| CPU vs GPU comparison | selected | Ollama | ⬜ |

## Runtime Comparison

| Experiment | Model | Runtime | Status |
|---|---|---|---|
| Recovery baseline | selected | vLLM | ⬜ |
| Recovery baseline | selected | llama.cpp | ⬜ |
| Readiness behavior | selected | vLLM | ⬜ |
| Readiness behavior | selected | llama.cpp | ⬜ |

## Primary Comparison Dimensions

```text
platform
  local Mac / cloud CPU / cloud GPU

runtime
  Ollama / vLLM / llama.cpp

model
  1B / 3B / 7B-or-8B / larger where feasible

storage
  ephemeral / persistent / cold acquisition

recovery locality
  same node / cold node

readiness
  none-or-runtime-level / model-presence / inference-aware
```

Results should only be compared directly when the remaining experimental conditions are controlled or explicitly documented.
