# Experimental Methodology

## Objective

The experiments measure the difference between Kubernetes infrastructure recovery and application-level LLM recovery.

The primary application-level recovery condition is:

> The requested model successfully completes an inference request.

Pod `Running`, Kubernetes `Ready`, runtime HTTP availability, and model-file presence are not treated as equivalent to functional recovery.

## Timing Model

- **T0 — failure initiation:** pod replacement is requested.
- **T1 — Kubernetes Ready:** replacement container is reported ready under the readiness semantics used by that experiment.
- **T2 — runtime reachable:** the inference runtime responds to a lightweight HTTP endpoint.
- **T3 — inference request start:** first post-recovery model request begins.
- **T4 — inference completion:** the model completes the request successfully.

Derived metrics:

```text
pod_recovery          = T1 - T0
runtime_recovery      = T2 - T0
ready_to_runtime      = T2 - T1
functional_recovery   = T4 - T0
ready_to_inference    = T4 - T1
request_wall_time     = T4 - T3
```

For Ollama, the scripts additionally capture `total_duration`, `load_duration`, `prompt_eval_duration`, and `eval_duration`.

## Runtime and Model Separation

The Ollama container image provides the serving runtime. Model artifacts are downloaded separately into `/root/.ollama`.

This means the following states can recover independently:

```text
Kubernetes pod
→ Ollama runtime
→ model artifact
→ loaded inference process
→ successful inference
```

## Storage Experiment

### `emptyDir`

The first deployment used `emptyDir` for `/root/.ollama`.

After pod deletion:

- the Deployment recreated the pod,
- Ollama started successfully,
- Kubernetes reported the pod `Running`,
- `ollama list` was empty,
- inference could not resume without pulling the model again.

Interpretation:

```text
runtime recovery != model artifact recovery
```

### PVC

The storage was changed to a PVC mounted at `/root/.ollama`.

After pod replacement:

- the replacement pod started,
- the model remained visible,
- no re-download was required,
- first inference still incurred model-loading cost.

Interpretation:

```text
model artifact persistence != model already loaded for inference
```

## Pilot Recovery Measurement

The first repeated recovery script used integer-second timestamps. It validated the workflow but was too coarse for the final baseline.

The pilot script and CSV are retained under archive paths as provenance and are not used as the primary controlled baseline.

## Millisecond Recovery Baseline

A second script version used millisecond timestamps and separated runtime reachability from inference completion.

Ten repeated PVC-backed pod replacements were collected for `llama3.2:1b`.

The script used a 15-second inter-run cooldown. The next run's T0 was recorded only after the cooldown, so the cooldown is excluded from recovery arithmetic.

The cooldown does **not** imply a cold-cache state.

## Derived Local Recovery Analysis

The raw 1B and 3B recovery CSVs are analyzed by:


`analysis/analyze_recovery.py`
The script computes:

- mean
- median
- standard deviation
- minimum
- maximum
- 1B → 3B percentage change

Generated output:

`analysis/local-mac-recovery-summary.csv`

This derived file should be regenerated from the raw CSV evidence rather than edited manually.


The important separation is:

```text
results/     = raw experimental evidence
analysis/    = derived statistics
README.md    = concise findings
docs/        = methodology/explanation
```


## 1B Controlled Baseline

Configuration:

- Runtime: Ollama
- Model: `llama3.2:1b`
- CPU limit: 2 CPUs
- Memory limit: 4 GiB
- Storage: PVC
- Worker: `opscart-m02`
- Hardware: CPU only
- Repetitions: 10

Observed mean values:

| Metric | Mean |
|---|---:|
| Kubernetes Ready | ~1.66 s |
| Runtime reachable | ~2.43 s |
| Functional recovery | ~11.11 s |
| Ready → inference | ~9.45 s |
| Model load | ~5.51 s |
| Ollama total | ~8.46 s |

## 3B Confounder and Correction

The first 3B inference attempt failed with:

```text
llama-server process has terminated: signal: killed
```

The pod and Ollama parent process remained running. Cgroup evidence showed `oom_kill 1`.

However, `ollama ps` revealed that the old 1B continuous probe had kept the 1B model resident while the 3B model was being loaded.

The correct interpretation was:

```text
1B resident + 3B load + 4 GiB cgroup limit
→ child inference process OOM-killed
```

The old probe was removed, both models were unloaded, and 3B was retested alone. Under the same 4 GiB limit, the 3B request succeeded and `oom_kill` remained zero.

This corrected experiment is the valid 3B resource result.

## 3B Controlled Recovery Baseline

Configuration:

- Runtime: Ollama
- Model: `llama3.2:3b`
- CPU limit: 2 CPUs
- Memory limit: 4 GiB
- Storage: PVC
- Worker: `opscart-m02`
- Other models: not resident
- Hardware: CPU only
- Repetitions: 10

Observed mean values:

| Metric | Mean |
|---|---:|
| Kubernetes Ready | ~1.96 s |
| Runtime reachable | ~2.44 s |
| Functional recovery | ~16.27 s |
| Ready → inference | ~14.31 s |
| Model load | ~8.60 s |
| Ollama total | ~13.57 s |
| Memory after inference | ~2.73 GiB |

The local 1B→3B comparison suggests that model size affected functional recovery much more than Kubernetes/runtime recovery. This is an environment-specific observation, not a universal scaling law.

## Readiness Experiment

### No functional readiness

Initially, Kubernetes could report the pod ready before the model had proven that it could execute inference.

### Model-presence readiness

A probe based on:

```bash
ollama list | grep -q "llama3.2:3b"
```

was tested and found insufficient because a model can be present on persistent storage before being loaded or usable.

### Inference-aware readiness

The Ollama image did not contain `curl` or `wget`.

Instead of rebuilding the runtime image solely to add an HTTP client, a lightweight `python:3.12-alpine` helper sidecar was added.

The helper:

1. exposes `GET /ready` on port 8080,
2. calls Ollama on localhost,
3. executes a minimal inference request,
4. returns HTTP 200 only if inference completes successfully.

The Ollama container's Kubernetes readiness probe points to this helper.

## Readiness Helper Implementation Correction

The first helper used a single-line `python -c` expression containing a class definition and failed with a Python `SyntaxError`.

It was replaced by a multiline Python script written inside the helper container at startup.

The failed implementation is development history, not experiment evidence.

## EndpointSlice Evidence

During rolling replacement, endpoint IP presence alone was found to be insufficient for determining traffic eligibility.

The authoritative EndpointSlice conditions used are:

- `ready`
- `serving`
- `terminating`

Traffic eligibility is defined as:

```text
ready=true AND serving=true
```

A successful rollout showed:

```text
old endpoint:
ready=true
serving=true

new endpoint while readiness inference is incomplete:
ready=false
serving=false

new endpoint after readiness inference succeeds:
ready=true
serving=true

old endpoint during termination:
ready=false
serving=false
terminating=true
```

This is the traffic-gating behavior the readiness experiment is intended to validate.

## Automated Readiness Rollouts

The readiness rollout script samples EndpointSlice state approximately every 0.5 seconds.

Raw dataset columns include:

```text
run
timestamp_ms
timestamp_utc
ip
role
ready
serving
terminating
```

The summary dataset is intended to contain rollout start, old/new pod and IP, new pod first seen, new pod Running, new endpoint first seen, new endpoint ready, old endpoint not ready, old endpoint removed, non-serving duration, and traffic-gap sample count.

A traffic gap is any sampled interval where zero endpoints satisfy:

```text
ready=true AND serving=true
```

## Known Readiness Dataset Issues

### Arithmetic bug

The first readiness rollout script used incorrect Bash arithmetic when calculating new endpoint non-serving duration.

Incorrect:

```bash
NEW_ENDPOINT_NONSERVING=$(
  (NEW_ENDPOINT_READY - NEW_ENDPOINT_FIRST_SEEN)
)
```

Correct:

```bash
NEW_ENDPOINT_NONSERVING=$((NEW_ENDPOINT_READY - NEW_ENDPOINT_FIRST_SEEN))
```

This affects the derived non-serving-duration summary field. It does not invalidate the raw EndpointSlice observations.

### macOS timestamp formatting

The first readiness script attempted to use GNU `%N` formatting with macOS `date`, producing malformed human-readable timestamps such as:

```text
2026-08-27T04:10:40.3NZ
```

The authoritative timing field is `timestamp_ms`, generated with Python.

Future script versions should generate ISO timestamps using Python. The original raw dataset should remain unchanged for provenance.

## Repetition Policy

Current controlled experiments use 10 repetitions to validate instrumentation, observe variability, identify obvious outliers, and compute basic descriptive statistics.

Ten runs are not presented as proof of universal statistical behavior.

## Cache Limitation

The current local recovery tests repeatedly use the same worker. The host may retain Linux page cache, filesystem cache, container image layers, and storage cache.

Therefore the local results are described as:

> same-node repeated PVC-backed recovery

They are not described as guaranteed cold starts.

## Evidence Preservation

The repository preserves original manifests, experiment-specific scripts, raw CSV measurements, corrected/new script versions, and pilot data under archive paths.

When a methodology changes materially, the earlier artifact is retained instead of silently overwritten.

## Interpretation Rules

- **Running**: container is executing.
- **Ready**: configured Kubernetes readiness condition has passed.
- **Runtime reachable**: serving runtime HTTP endpoint responds.
- **Model present**: artifact is visible to the runtime.
- **Functional recovery**: requested model successfully completes the defined inference.
- **Traffic eligible**: EndpointSlice reports `ready=true` and `serving=true`.

## Next Methodology Extensions

The same core timing model will be extended to larger cloud CPU systems, larger models, cold-node recovery, cold model acquisition, GPU validation, and runtime comparisons across Ollama, vLLM, and llama.cpp.
