# Inference-Aware Readiness Helper Overhead

This experiment quantifies the steady-state overhead of the
inference-aware readiness design used in the paper.

## Environment

- Kubernetes context: `opscart`
- Namespace: `ollama-recovery-lab`
- Model: `llama3.2:3b`
- Runtime: Ollama
- Ollama resource limit: 2 CPU / 4 GiB
- Readiness period: 5 seconds
- Measurement window: 300 seconds per condition

## Conditions

### Inference-aware readiness

The original readiness configuration was retained:

`GET /ready` -> readiness-helper -> `POST /api/generate`

The helper performs a minimal one-token inference request.

During the 300-second window:

- scheduled probes: 60
- Ollama mean CPU: 545.171 mCPU
- helper mean CPU: 1.737 mCPU

Probe-triggered inference latency, n=60:

- mean: 1252.873 ms
- median: 1145.000 ms
- sample SD: 697.834 ms
- minimum: 348.170 ms
- maximum: 2790.000 ms

### Lightweight readiness

For the comparison condition, the readiness probe retained the
same 5-second period but directly queried Ollama `/api/tags`.

No inference requests were issued during the lightweight measurement
window. Model residency throughout this window was not independently
verified by the archived measurements.

During the 300-second window:

- `/api/tags` requests: 60
- `/api/generate` requests: 0
- Ollama mean CPU: 2.224 mCPU
- helper mean CPU: 0.416 mCPU

## Comparison

The inference-aware configuration increased mean Ollama CPU
consumption by 542.947 mCPU relative to the lightweight condition.

Within the configured 2-CPU resource limit, this corresponds to
approximately 27.147% of the available CPU capacity.

Across the 300-second window, the inference-aware condition consumed
approximately 162.884 additional CPU-seconds, or approximately
2.715 incremental CPU-seconds per scheduled probe.

These values characterize this specific model, runtime, hardware,
resource envelope, prompt, and five-second probe cadence. They should
not be interpreted as universal readiness-probe costs.

Memory values are retained in the raw evidence but are not used for
the primary A/B comparison because the two conditions ran in different
replacement pods and their resident-memory states were not identical.

## Evidence

- `probe-on/` contains the inference-aware condition.
- `lightweight-probe/` contains the `/api/tags` comparison condition.
- `environment/` contains deployment and environment snapshots.
- `comparison-summary.txt` contains derived A/B metrics.
- `scripts/measurement/measure-readiness-helper-window.sh` reproduces
  the fixed-window cgroup CPU and memory collection.
