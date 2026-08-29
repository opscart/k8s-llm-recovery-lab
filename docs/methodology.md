# Experimental Methodology

## Objective

The experiments measure the difference between Kubernetes infrastructure recovery and application-level LLM recovery.

The primary application-level recovery condition is:

> The requested model successfully completes an inference request.

Pod `Running`, Kubernetes `Ready`, runtime HTTP availability, model-file presence, model residency, and successful inference are treated as distinct states.

## Timing Model

- **T0 — failure initiation:** pod replacement is requested.
- **T1 — Kubernetes Ready:** replacement container is reported ready under the readiness semantics used by that experiment.
- **T2 — runtime reachable:** the inference runtime responds to a lightweight HTTP endpoint.
- **T3 — inference request start:** first post-recovery model request begins.
- **T4 — inference completion:** the model completes the request successfully.

Derived metrics:

```text
pod_recovery        = T1 - T0
runtime_recovery    = T2 - T0
ready_to_runtime    = T2 - T1
functional_recovery = T4 - T0
ready_to_inference  = T4 - T1
request_wall_time   = T4 - T3
```

For Ollama, the scripts additionally capture:

- `total_duration`
- `load_duration`
- `prompt_eval_duration`
- `eval_duration`
- post-inference cgroup memory where applicable

## Runtime and Model Separation

The Ollama container image provides the serving runtime. Model artifacts are downloaded separately into `/root/.ollama`.

The following states can therefore recover independently:

```text
Kubernetes pod
→ Ollama runtime
→ model artifact
→ model residency / loaded inference process
→ successful inference
```

This distinction is central to the project:

```text
runtime recovery
!=
model artifact availability
!=
model residency
!=
functional inference recovery
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
- first inference still incurred model-loading and initialization cost.

Interpretation:

```text
model artifact persistence != model already loaded for inference
```

## Pilot Recovery Measurement

The first repeated recovery script used integer-second timestamps. It validated the workflow but was too coarse for the final baseline.

The pilot script and CSV are retained under archive paths as provenance and are not used as the primary controlled baseline.

## Millisecond Recovery Baseline

A second script version used millisecond timestamps and separated runtime reachability from inference completion.

Controlled recovery experiments use a 15-second inter-run cooldown. The next run's T0 is recorded only after the cooldown, so the cooldown is excluded from recovery arithmetic.

The cooldown does **not** imply a cold-cache state.

## Local Mac Controlled Recovery

### 1B Controlled Baseline

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

### 3B Confounder and Correction

The first 3B inference attempt failed with:

```text
llama-server process has terminated: signal: killed
```

The pod and Ollama parent process remained running. Cgroup evidence showed `oom_kill 1`.

`ollama ps` revealed that an older 1B continuous probe had kept the 1B model resident while the 3B model was being loaded.

The correct interpretation was:

```text
1B resident + 3B load + 4 GiB cgroup limit
→ child inference process OOM-killed
```

The old probe was removed, both models were unloaded, and the 3B model was retested alone. Under the same 4 GiB limit, the 3B request succeeded and `oom_kill` remained zero.

This corrected experiment is the valid 3B resource result.

### 3B Controlled Recovery Baseline

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

The local 1B → 3B comparison suggests that model size affected functional recovery much more than Kubernetes/runtime recovery under the same resource envelope.

This is an environment-specific observation, not a universal scaling law.

## Azure Cloud CPU Validation

The same timing model was repeated on an Azure Linux VM using Minikube.

### Azure 1B and 3B Controlled Baselines

The Azure 1B and 3B experiments used:

- Runtime: Ollama
- Models: `llama3.2:1b` and `llama3.2:3b`
- CPU limit: 2 CPUs
- Memory limit: 4 GiB
- Storage: PVC
- Repetitions: 10 per model
- Same Azure host and Minikube node

Observed mean values:

| Metric | Azure 1B | Azure 3B |
|---|---:|---:|
| Kubernetes Ready | 1.606 s | 1.689 s |
| Runtime reachable | 2.186 s | 2.171 s |
| Functional recovery | 5.433 s | 7.734 s |
| Ready → inference | 3.827 s | 6.045 s |
| Model load | 2.161 s | 3.962 s |
| Ollama total | 3.123 s | 5.437 s |

The Azure environment reduced inference-dependent recovery substantially compared with the local Mac environment, while Kubernetes and runtime recovery changed much less.

Cross-platform comparisons are interpreted as environment comparisons rather than pure hardware benchmarks because CPU implementation, storage path, virtualization, topology, and cache behavior differ.

## Azure 8B Larger-Model Validation

`llama3.1:8b` was evaluated separately on the same Azure host using:

- CPU request: 4 CPUs
- Memory request: 8 GiB
- CPU limit: 8 CPUs
- Memory limit: 16 GiB
- Storage: 20 GiB PVC
- Repetitions: 10

Observed mean values:

| Metric | Mean |
|---|---:|
| Kubernetes Ready | ~1.861 s |
| Runtime reachable | ~2.413 s |
| Functional recovery | ~6.477 s |
| Ready → inference | ~4.616 s |
| Request wall | ~4.049 s |
| Model load | ~3.657 s |
| Ollama total | ~3.934 s |
| Memory after inference | ~5.28 GiB |

This experiment is classified as a **larger-model validation**, not a controlled 3B → 8B model-size comparison.

Two variables changed:

- the model family changed from Llama 3.2 to Llama 3.1,
- the resource envelope increased from 2 CPU / 4 GiB to 8 CPU / 16 GiB.

The 8B result therefore demonstrates recovery behavior for a larger, right-sized deployment rather than a pure model-size effect.

## Model Artifact Presence vs Runtime Residency

The Azure 8B experiment captured both unloaded and resident runtime states.

In the unloaded state:

- `ollama list` still showed the `llama3.1:8b` artifact,
- `ollama ps` showed no resident model,
- cgroup `memory.current` was approximately 14 MiB.

After a new inference request:

- `ollama ps` showed `llama3.1:8b` resident,
- Ollama reported approximately 5.7 GB runtime size,
- cgroup `memory.current` was approximately 5.27 GiB.

This provides direct evidence for:

```text
model artifact present
!=
model resident in runtime memory
```

The final captured pod recorded `oom_kill 0`. This applies to that captured pod only and is not treated as a per-run OOM audit of all deleted pods.

## Accelerator Validation

The Azure 8B environment was explicitly checked for discrete GPU exposure.

Observed evidence:

- no matching PCI GPU/display device was detected,
- `nvidia-smi` was unavailable,
- no GPU device files were exposed inside the Ollama container,
- Ollama/llama.cpp logs reported an `AMX` device,
- Ollama logs also reported CPU compute buffers.

The experiment is treated as CPU execution with AMX-related runtime behavior observed in the logs.

The `ollama ps` `CPU/GPU` percentage field is not treated as evidence of discrete-GPU execution.

## Readiness Experiment

### No Functional Readiness

Initially, Kubernetes could report the pod ready before the model had proven that it could execute inference.

### Model-Presence Readiness

A probe based on:

```bash
ollama list | grep -q "llama3.2:3b"
```

was tested and found insufficient because a model can be present on persistent storage before being loaded or usable.

### Inference-Aware Readiness

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

Observed rollout behavior:

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

## Automated Readiness Rollouts

The readiness rollout script samples EndpointSlice state approximately every 0.5 seconds.

A traffic gap is defined as any sampled interval where zero endpoints satisfy:

```text
ready=true AND serving=true
```

### Local 3B Readiness

- Runs: 10
- Mean new-endpoint non-serving duration: 47.627 s
- Median: 50.388 s
- Minimum: 34.252 s
- Maximum: 68.984 s
- Traffic-gap samples: 0
- Runs containing a sampled traffic gap: 0/10

### Azure 3B Readiness

- Runs: 10
- Mean new-endpoint non-serving duration: 10.968 s
- Median: 10.852 s
- Minimum: 10.278 s
- Maximum: 11.437 s
- Traffic-gap samples: 0
- Runs containing a sampled traffic gap: 0/10

Across all 20 measured rollouts, no sampled interval contained zero endpoints satisfying both `ready=true` and `serving=true`.

This is a sampled EndpointSlice result, not a packet-level or continuous-time availability guarantee.

## Known Readiness Dataset Issues

### Arithmetic Bug

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

This affected the derived non-serving-duration summary field but did not invalidate the raw EndpointSlice observations.

### macOS Timestamp Formatting

The first readiness script attempted to use GNU `%N` formatting with macOS `date`, producing malformed human-readable timestamps.

The authoritative timing field is `timestamp_ms`, generated with Python.

The original raw dataset remains unchanged for provenance.

## Warm vs Cold Cache Experiment

The original recovery baselines repeatedly used the same node and did not explicitly control host cache state.

A dedicated Azure 3B experiment was therefore added to isolate the effect of node-level Linux filesystem/page-cache state while keeping the following constant:

- Azure VM
- Minikube node
- Ollama runtime
- `llama3.2:3b`
- 2 CPU / 4 GiB limit
- PVC-backed model storage
- recovery timing model
- inference request
- 10 repetitions per condition

### Warm Condition

Before each measured pod deletion:

1. the current 3B model was invoked with an inference request,
2. `ollama ps` was checked,
3. the model had to be resident,
4. `/proc/meminfo` `Cached` was recorded,
5. only then was T0 recorded and the pod deleted.

The warm condition therefore explicitly verified:

```text
precondition_model_resident=true
```

The warm-up operation occurs before T0 and is excluded from recovery timing.

### Cold Filesystem/Page-Cache Condition

Before each measured pod deletion:

1. `ollama stop llama3.2:3b` was issued,
2. the script waited until `ollama ps` no longer showed the model,
3. host filesystems were synchronized with `sync`,
4. Linux caches were dropped with:

```bash
echo 3 > /proc/sys/vm/drop_caches
```

5. the cache drop was verified,
6. `/proc/meminfo` `Cached` was recorded,
7. only then was T0 recorded and the pod deleted.

The cold condition therefore explicitly verified:

```text
precondition_model_resident=false
drop_caches_success=true
```

The cache treatment is performed before T0 and is excluded from recovery timing.

### Cache Treatment Scope

`drop_caches` is a **node-level Linux filesystem/page-cache treatment**.

It is not described as a model-only cache flush.

It can affect:

- model-file pages,
- filesystem cache,
- dentries,
- inode cache,
- other filesystem-backed reads used by the runtime.

Therefore the experiment is described as:

> warm condition vs node-level cold filesystem/page-cache condition

It is not described as:

> warm model cache vs cold model cache

### Warm vs Cold Results

Ten runs were collected per condition.

| Metric | Warm Mean | Cold Mean | Change |
|---|---:|---:|---:|
| Kubernetes Ready | 1.883 s | 1.834 s | -2.59% |
| Runtime reachable | 2.460 s | 2.378 s | -3.31% |
| Ready → runtime | 0.577 s | 0.544 s | -5.65% |
| Functional recovery | 7.582 s | 8.092 s | +6.72% |
| Ready → inference | 5.699 s | 6.258 s | +9.79% |
| Request wall | 5.108 s | 5.699 s | +11.57% |
| Model load | 3.952 s | 4.606 s | +16.56% |
| Prompt evaluation | 0.816 s | 0.772 s | -5.36% |
| Token evaluation | 0.222 s | 0.203 s | -8.17% |
| Ollama total | 4.992 s | 5.586 s | +11.90% |

The cold treatment reduced mean node `Cached` from approximately 2.21 GB before treatment to approximately 0.74 GB after treatment, corresponding to a mean reduction of 66.20%.

The main observation is:

> On the same Azure node, explicit node-level cold filesystem/page-cache treatment increased inference-dependent recovery, especially model load, while Kubernetes and runtime recovery remained comparatively stable.

This is an environment-specific result and is not presented as a universal cache penalty.

### Post-Inference Memory Observation

Mean post-inference cgroup memory differed between the two cache conditions:

- warm: ~2.831 GiB
- cold: ~3.998 GiB

This difference is recorded descriptively only.

No causal interpretation is assigned to cache state because the current experiment was not designed to isolate runtime-memory accounting behavior.

### Same-topology cold-node control

To separate node-relocation effects from changes introduced by the new
kubeadm/containerd topology, we executed 10 repeated cold-start controls on
the target worker itself.

For each run, the Ollama Deployment was scaled to zero, absence of a
model-serving process was verified, Linux filesystem/page caches were dropped,
and the Deployment was restarted on the same worker using the same node-local
model artifact, pinned Ollama image, model, resource limits, and PVC.

The 10-run control produced a mean functional recovery time of 9.665 s and a
mean Ready-to-inference interval of 7.964 s. Mean model-load time was 5.621 s.

The preserved first-use cross-node recovery completed inference in 10.160 s,
approximately 5.1% above the same-topology control mean. Model-load time was
approximately 2.2% higher, while Ready-to-inference was approximately 2.0%
lower.

Because the cross-node condition currently contains one first-use observation,
these differences are descriptive rather than evidence of a statistically
established node-relocation penalty. The results indicate that, when the model
artifact is already available on the destination node, cold model loading
accounts for most of the observed inference-recovery interval in this setup.

## Derived Analysis

Raw recovery measurements remain under `results/`.

Derived statistics remain under `analysis/`.

Current analysis scripts include:

- `analysis/analyze_recovery.py`
- `analysis/analyze_readiness.py`
- `analysis/analyze_cache_recovery.py`
- `analysis/analyze_cold_node_recovery.py`

Generated summaries include:

- `analysis/recovery-cross-platform-summary.csv`
- `analysis/readiness-cross-platform-summary.csv`
- `analysis/cache-recovery-summary.csv`
- `analysis/cold-node-recovery-summary.csv`

Derived files should be regenerated from raw CSV evidence rather than edited manually.

The repository separation is:

```text
results/     = raw experimental evidence
analysis/    = derived statistics
README.md    = concise findings
docs/        = methodology and interpretation
```

## Repetition Policy

Current controlled experiments use 10 repetitions to validate instrumentation, observe variability, identify obvious outliers, and compute basic descriptive statistics.

Ten runs are not presented as proof of universal statistical behavior.

## Cache and Locality Limitations

Repeated same-node recovery can benefit from:

- Linux page cache,
- filesystem cache,
- storage cache,
- container image layers,
- runtime initialization effects.

The warm/cold experiment explicitly controls one part of this by dropping
node-level Linux caches.

The Azure kubeadm experiment additionally includes:

- one preserved first-use cross-node recovery observation from Node A to Node B,
- a 10-run same-topology cold control on Node B.

The current cold-node experiment does not yet measure:

- repeated fresh-node cross-node recovery,
- fresh-node image acquisition,
- cold model download,
- shared-storage behavior across nodes,
- GPU memory residency effects.

The single first-use cross-node observation is therefore treated descriptively
and is not used to establish a statistically significant node-relocation
penalty.

## Evidence Preservation

The repository preserves:

- original manifests,
- experiment-specific scripts,
- raw CSV measurements,
- corrected/new script versions,
- pilot or invalid data under archive paths,
- environment evidence,
- derived analysis outputs.

When a methodology changes materially, the earlier artifact is retained instead of silently overwritten.

## Interpretation Rules

- **Running:** container is executing.
- **Ready:** configured Kubernetes readiness condition has passed.
- **Runtime reachable:** serving runtime HTTP endpoint responds.
- **Model present:** artifact is visible to the runtime.
- **Model resident:** the runtime reports the model as actively loaded.
- **Functional recovery:** requested model successfully completes the defined inference.
- **Traffic eligible:** EndpointSlice reports `ready=true` and `serving=true`.
- **Warm cache condition:** model residency is explicitly established before T0.
- **Cold filesystem/page-cache condition:** model residency is removed and node-level Linux caches are dropped before T0.

## Next Methodology Extensions

The next useful extensions are:

1. representative GPU validation,
2. repeated fresh-node cross-node recovery where justified,
3. cold model acquisition,
4. runtime comparisons across Ollama, vLLM, and llama.cpp,
5. controlled larger-model comparison under a common resource policy where feasible,
6. separation of cold-recovery measurements from steady-state generation performance.
