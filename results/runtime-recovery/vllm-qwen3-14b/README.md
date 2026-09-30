# vLLM Qwen3 14B AWQ Recovery Experiment

## Runtime and model

- Runtime: vLLM 0.29.0
- Model: Qwen/Qwen3-14B-AWQ
- Revision: 31c69efc29464b6bb0aee1398b5a7b50a99340c3
- Served name: qwen3-14b-awq
- Quantization: AWQ
- Maximum model length: 8192
- Qwen3 thinking disabled for functional recovery requests

## Hardware

- Node: k8s-llm-gpu-01
- GPU: NVIDIA Tesla T4, 16 GiB
- Kubernetes: v1.35.1
- Container runtime: containerd 2.2.1

## Kubernetes resource envelope

Requests:
- CPU: 500m
- Memory: 4 GiB
- GPU: 1

Limits:
- CPU: 2
- Memory: 20 GiB
- GPU: 1

## Experimental condition

The model artifact was already persisted locally before recovery measurement.
The vLLM container image was already present on the node.

The three measured runs therefore represent persistent-artifact,
warm-host-cache pod replacement recovery rather than cold model acquisition.

Functional recovery was defined as the first successful inference returning
exactly:

RECOVERY_OK

Qwen3 thinking was disabled using chat_template_kwargs.enable_thinking=false.

## Runs

n=3

Functional recovery:
- Run 1: 92.694 s
- Run 2: 93.016 s
- Run 3: 92.558 s
- Mean: approximately 92.756 s

Kubernetes Ready:
- Run 1: 92.058 s
- Run 2: 92.343 s
- Run 3: 91.892 s
- Mean: approximately 92.098 s

Ready-to-Inference:
- Run 1: 0.636 s
- Run 2: 0.672 s
- Run 3: 0.666 s
- Mean: approximately 0.658 s

Request wall time:
- Run 1: 0.447 s
- Run 2: 0.482 s
- Run 3: 0.455 s

## Runtime observations

Across the three runs, vLLM consistently:

- loaded approximately 9.44 GiB of model memory;
- exposed approximately 3.91 GiB of KV-cache capacity;
- used the AutoAWQ Marlin linear kernel;
- used TRITON_ATTN because FlashAttention 2 is unavailable on the
  Tesla T4 compute capability;
- allocated approximately 13.9 GiB of the 16 GiB GPU.

Warm-cache model-loading time was approximately 14 s across the three runs.

The service-level recovery interval was substantially longer than the internal
model-loading interval. Kubernetes events showed temporary
Insufficient nvidia.com/gpu scheduling while the previous pod released the
single T4 during replacement.

Accordingly, the measured functional recovery interval includes:
- previous pod termination;
- single-GPU resource handoff;
- replacement pod scheduling and startup;
- vLLM initialization;
- model loading;
- engine initialization;
- readiness;
- first successful inference.

The approximately 92.8 s functional-recovery measurement must therefore not
be interpreted as model-loading time alone.
