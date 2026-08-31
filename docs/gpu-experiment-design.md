# GPU Recovery Experiment Design

## Objective

Extend the Kubernetes LLM Recovery Lab from CPU-only Ollama experiments to GPU-backed inference while preserving the existing recovery-state model.

The completed T4 phase asked:

> How does GPU-backed execution change the gap between Kubernetes workload recovery and successful LLM inference, and which accelerator/runtime states dominate that gap after pod replacement?

The phase intentionally retained Ollama for the initial CPU-to-GPU comparison. It then added a larger Llama model and a cross-family Qwen model after the 3B baseline was frozen.

## Scope

### Serving runtime

- Ollama

Ollama was retained because it was already used for the CPU baselines.

### Executed models

- `llama3.2:3b` — initial CPU/GPU overlap and CUDA-cache A/B
- `llama3.1:8b` — larger-model GPU validation
- `qwen3:14b` — cross-family/right-sized GPU validation

The Qwen3 14B condition is not treated as a fixed-envelope scaling point because host-memory diagnostics required a larger memory limit to reach the mmap-enabled loading path.

## Hardware Target

The completed environment used:

```text
Region: South Central US
VM SKU: Standard_NC8as_T4_v3
GPU: NVIDIA Tesla T4
GPU count: 1
GPU memory: 16 GiB
vCPU: 8
System memory: 56 GiB
OS: Ubuntu 22.04.5 LTS
Kernel: 6.8.0-1064-azure
Kubernetes: 1.35.1
Container runtime: containerd 2.2.1
NVIDIA driver: 610.57.04
Reported CUDA compatibility: 13.3
```

The model/data disk was a 128 GiB Premium SSD mounted at `/var/lib/llm-recovery/ollama`. The Ollama image remained pinned by digest.

The original design considered smaller T4 and A10 options. They are retained only as planning history; all reported GPU measurements in this phase come from the `Standard_NC8as_T4_v3` environment above.

## Environment Isolation

The GPU environment should be treated as a new experimental environment.

Do not reuse CPU measurements as if only the accelerator changed unless all material differences are documented.

Record at minimum:

- Azure region
- VM SKU
- CPU model
- system memory
- GPU model
- GPU memory
- NVIDIA driver version
- CUDA version visible to the runtime
- OS image
- kernel version
- Kubernetes version
- container runtime
- Ollama image digest
- model identifier
- model artifact size
- quantization or precision
- workload CPU and memory requests/limits
- GPU resource request
- storage type and size
- node topology
- cache/locality condition

## GPU Validation Before Measurement

Do not begin recovery measurements until GPU exposure is independently verified.

Capture:

```bash
nvidia-smi
```

and record:

- GPU name
- driver version
- reported CUDA compatibility
- total GPU memory
- initial GPU memory usage

Inside the serving container, verify that GPU devices are visible.

For Kubernetes, capture:

```bash
kubectl describe node
kubectl get pods -A -o wide
kubectl get pod -n llm-recovery-lab -l app=ollama -o yaml
```

Verify that the pod receives the expected GPU resource and that the runtime actually executes inference on the GPU.

Runtime-reported GPU usage alone should not be treated as the only evidence. Host/device evidence and runtime logs should also be preserved.

## Recovery States

The existing timing model remains unchanged:

```text
T0  failure/replacement initiation
T1  Kubernetes Ready
T2  inference runtime reachable
T3  first post-recovery inference request begins
T4  successful inference completes
```

Derived metrics remain:

```text
pod_recovery        = T1 - T0
runtime_recovery    = T2 - T0
ready_to_runtime    = T2 - T1
functional_recovery = T4 - T0
ready_to_inference  = T4 - T1
request_wall_time   = T4 - T3
```

For Ollama, continue recording:

- total duration
- load duration
- prompt evaluation duration
- token evaluation duration

## Additional GPU-Specific Evidence

The GPU phase should also capture accelerator state around recovery.

Where practical, record:

### Before replacement

- GPU memory used
- model residency state
- model-serving process state

### After Kubernetes Ready but before first measured inference

- GPU memory used
- whether the model is resident in GPU memory
- runtime reachability

### After successful inference

- GPU memory used
- model residency
- runtime-reported processor placement
- inference timing fields

The purpose is to distinguish:

```text
model artifact present
!=
runtime reachable
!=
model resident in host memory
!=
model resident in GPU memory
!=
successful inference
```

## Phase 1: Llama 3B Baseline and CUDA-Cache Isolation

The first 10-run baseline used persistent model storage but default ephemeral CUDA ComputeCache. It produced mean Ready → inference of ~63.958 s.

After the reusable CUDA cache was redirected to persistent storage using `CUDA_CACHE_PATH=/root/.ollama/cuda-compute-cache`, a second 10-run series produced mean Ready → inference of ~3.538 s and mean functional recovery of ~9.259 s.

Additional diagnostics showed:

- 4 CPU / 8 GiB host resources alone did not materially change the slow baseline,
- same-process model unload/reload was ~3.2–3.3 s,
- already-resident inference was ~0.04 s for the small control prompt,
- full Deployment recreation remained fast when the model and CUDA cache persisted.

## Phase 2: Llama 8B Validation

`llama3.1:8b` was tested with persistent CUDA ComputeCache under the same 2 CPU / 4 GiB workload limit used by the GPU 3B condition.

Ten runs produced mean Ready → inference of ~3.840 s and mean functional recovery of ~9.470 s. The model used approximately 5.15 GiB of GPU process memory.

## Phase 3: Qwen3 14B Cross-Family and Host-Memory Validation

Qwen3 14B fit fully in T4 VRAM but exposed a host-memory loading threshold:

- 4 GiB limit: mmap disabled, ~40 s diagnostic load
- 16 GiB limit: mmap still disabled, ~22 s diagnostic load
- 20 GiB limit: `load_mode = mmap`

The formal 20 GiB, persistent-CUDA-cache, `think=false` 10-run series produced mean Ready → inference of ~5.280 s and mean functional recovery of ~10.826 s.

## Deferred GPU Cold Filesystem/Page-Cache Control

The CPU phase already includes a controlled Linux filesystem/page-cache warm/cold comparison. The T4 phase did not repeat that exact control after the stronger CUDA-cache and host-memory effects were isolated. A GPU host-page-cache control remains a possible follow-up if needed to support a cache-layer decomposition claim.

## Future Runtime Comparison

A future vLLM phase would answer a different question:

> How much of LLM recovery behavior is attributable to the serving runtime rather than Kubernetes, model size, cache persistence, or hardware?

A llama.cpp comparison remains optional.

## Repetition Policy

Use 10 repetitions for the controlled baseline unless a different repetition count is justified before execution.

As in the existing methodology, 10 runs are used for descriptive statistics and instrumentation validation. They are not treated as proof of universal behavior.

## Evidence Paths

Executed repository paths include:

```text
docs/gpu-experiment-design.md
docs/gpu-azure-provisioning.md

results/cloud-gpu/
  environment/
    gpu-environment.txt
  ollama/
    llama3.2-3b/
      diagnostics/
      recovery/
    llama3.1-8b/
      recovery/
    qwen3-14b/
      recovery/

manifests/runtimes/ollama/
  ollama-gpu.yaml
  ollama-gpu-qwen14b.yaml

manifests/storage/
  ollama-gpu-local-pv.yaml

scripts/cloud/
  capture-gpu-environment.sh

scripts/recovery/
  ollama-llama32-3b-cloud-gpu-recovery.sh
```

The GPU recovery script became parameterized through `MODEL`, `RUNS`, `OUT`, and optional `THINK=false`, while the historical filename was retained to avoid unnecessary path churn.

## Azure Quota and Capacity Preparation

GPU VM availability is subscription- and region-specific.

Before provisioning, verify:

1. total regional vCPU quota,
2. GPU VM-family vCPU quota,
3. VM SKU availability in the intended region,
4. actual regional capacity.

A quota of zero for the required GPU family will prevent VM creation even if the SKU exists in the region.

Request quota for the exact VM family and region before the execution window.

Candidate quota families include:

```text
NCasT4_v3
NVadsA10_v5
```

Quota approval does not guarantee that Azure has immediate physical capacity for the requested SKU. If quota is available but deployment still fails, check SKU restrictions and regional capacity or use another approved region.

## Cost Control

GPU infrastructure should exist only during active experiment windows.

Before VM creation:

- finalize manifests,
- finalize recovery scripts,
- define the model,
- define the number of repetitions,
- prepare evidence-capture commands.

After measurements:

1. copy and verify raw evidence,
2. push evidence to the research branch,
3. deallocate or delete the GPU VM,
4. remove unused managed disks/public IPs if the environment is no longer required.

Do not retain an expensive GPU VM solely for convenience between experiment phases.

## Interpretation Boundaries

The completed GPU phase supports claims only about the tested Azure T4/Ollama environment and the documented resource/cache conditions.

Do not claim:

- universal CPU-to-GPU recovery acceleration,
- universal CUDA-cache effects across runtimes or GPU architectures,
- that model fit in VRAM implies adequate host-memory sizing,
- that the Qwen3 14B right-sized result is directly comparable to the 3B/8B fixed-memory conditions as a pure model-size scaling point,
- a complete GPU cache decomposition because Linux filesystem/page-cache cold treatment was not repeated on the T4,
- vLLM or llama.cpp behavior before those runtimes are measured,
- a pure hardware effect when CPU and GPU environments differ in region, host CPU, storage, topology, or container runtime.

The strongest completed findings are narrower: functional recovery can lag Kubernetes readiness; accelerator/runtime cache persistence can dominate fresh-pod recovery; and host-memory limits can change the model-loading path even when the model fits in GPU VRAM.

