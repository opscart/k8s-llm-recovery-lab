# GPU Recovery Experiment Design

## Objective

Extend the Kubernetes LLM Recovery Lab from CPU-only Ollama experiments to GPU-backed inference while preserving the existing recovery-state model.

The first GPU phase is designed to answer a narrow question:

> How does GPU-backed execution change the gap between Kubernetes workload recovery and successful LLM inference when the serving runtime and model are kept as comparable as practical?

The initial GPU experiment does not attempt to compare every serving runtime or every model. It establishes a GPU baseline that can later support controlled runtime comparisons.

## Scope

### Initial serving runtime

- Ollama

Ollama is retained for the first GPU phase because it is the runtime already used for the CPU baselines. This reduces the number of variables that change in the initial CPU-to-GPU comparison.

### Initial model

- `llama3.2:3b`

This model is preferred for the first GPU experiment because it already has:

- local CPU recovery baselines,
- Azure CPU recovery baselines,
- inference-aware readiness evidence,
- warm vs node-level cold filesystem/page-cache measurements,
- cold-node recovery evidence.

### Optional second model

After the 3B GPU baseline is frozen, a second model may be added to test whether the recovery behavior is model-specific.

A second model should be selected before execution and should be documented with:

- model family,
- parameter count,
- quantization or precision,
- artifact size,
- runtime-visible model size,
- expected VRAM requirement.

The second-model phase must not be mixed into the initial CPU-to-GPU comparison.

## Hardware Target

### Preferred first option

Azure `NCasT4_v3` using an NVIDIA T4 GPU.

A practical starting SKU is:

```text
Standard_NC4as_T4_v3
```

Relevant properties:

- 4 vCPU
- 28 GiB system memory
- 1 NVIDIA T4 GPU
- 16 GB GPU memory

The T4 provides enough GPU memory for the existing 3B baseline and can support a later 7B/8B-class validation depending on the selected quantization and runtime behavior.

### Alternative

Azure `NVadsA10_v5` using NVIDIA A10 GPUs.

This family provides fractional or full A10 GPU allocation. GPU memory depends on the selected VM size:

```text
Standard_NV6ads_A10_v5   -> 4 GB GPU memory
Standard_NV12ads_A10_v5  -> 8 GB GPU memory
Standard_NV18ads_A10_v5  -> 12 GB GPU memory
Standard_NV36ads_A10_v5  -> 24 GB GPU memory
```

For this study, avoid selecting a fractional GPU solely because it is the cheapest option if the memory allocation would force a different model or quantization from the intended experiment.

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

## Phase 1: GPU Ollama Baseline

Configuration:

```text
Runtime: Ollama
Model: llama3.2:3b
Hardware: NVIDIA GPU
Recovery locality: same node
Artifact: persistent/pre-staged
Repetitions: 10
```

The first baseline should avoid intentional cache dropping.

This establishes the repeated GPU recovery behavior using the same general methodology as the previous CPU baseline.

## Phase 2: GPU Cold Recovery

After Phase 1 is frozen, test an explicitly cold condition.

The exact cold treatment must be defined before execution because CPU page-cache clearing does not necessarily clear GPU model state by itself.

At minimum:

1. remove the active model from runtime residency,
2. verify no model-serving process retains the model,
3. verify GPU memory has returned to the expected idle state,
4. apply the selected filesystem/page-cache treatment if that dimension is being tested,
5. record all precondition evidence before T0.

Do not describe the experiment as a GPU cold start unless the accelerator-residency state is explicitly verified.

## Phase 3: CPU vs GPU Comparison

The strongest initial comparison is:

```text
same serving runtime
same model
same recovery definition
CPU environment vs GPU environment
```

This remains an environment comparison rather than a pure accelerator benchmark unless CPU architecture, storage, topology, runtime image, and all other relevant dimensions are matched.

Primary comparisons:

- Kubernetes Ready
- runtime reachable
- functional recovery
- Ready to inference
- model load
- request wall
- Ollama total

The key question is whether GPU execution primarily changes the inference-dependent portion of recovery while Kubernetes/runtime startup remains comparatively stable.

## Phase 4: Runtime Comparison

Only after the Ollama GPU baseline is frozen should another serving runtime be introduced.

Candidate:

- vLLM

The runtime comparison should use the same GPU and, where feasible, the same model family, precision/quantization, storage condition, and recovery trigger.

This phase answers a different question:

> How much of LLM recovery behavior is attributable to the serving runtime rather than Kubernetes, model size, or hardware?

A later llama.cpp comparison is optional.

## Repetition Policy

Use 10 repetitions for the controlled baseline unless a different repetition count is justified before execution.

As in the existing methodology, 10 runs are used for descriptive statistics and instrumentation validation. They are not treated as proof of universal behavior.

## Evidence Paths

Planned repository paths:

```text
docs/gpu-experiment-design.md

results/cloud-gpu/
  ollama/
    llama3.2-3b/
      recovery/

manifests/runtimes/ollama/
  ollama-gpu.yaml

scripts/cloud/
  capture-gpu-environment.sh

scripts/recovery/
  ollama-llama32-3b-cloud-gpu-recovery.sh
```

Create runtime-specific directories such as `manifests/runtimes/vllm/` only when that runtime phase actually begins.

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

The first GPU experiment will support claims about the tested Azure GPU environment only.

Do not claim:

- universal CPU-to-GPU recovery acceleration,
- universal GPU model-load behavior,
- vLLM behavior before vLLM is measured,
- cold GPU recovery without explicit GPU-residency preconditions,
- a pure hardware effect when other environment variables differ.

The intended result is a controlled extension of the existing recovery methodology, not a general LLM inference benchmark.
