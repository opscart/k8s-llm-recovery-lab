# Qwen2.5-Coder 14B AWQ on the T4 Lab Node

## Scope

This phase deploys one OpenAI-compatible vLLM endpoint on the single `Standard_NC8as_T4_v3` node:

```text
Model: Qwen/Qwen2.5-Coder-14B-Instruct-AWQ
GPU: NVIDIA Tesla T4, 16 GiB
Runtime: vLLM v0.29.0
Exposure: Kubernetes ClusterIP only
```

RAG ingestion, retrieval, repository credentials, pull-request automation, pipeline reruns, and AKS mutation are intentionally outside this phase. They must not be enabled until the model endpoint passes controlled evaluation.

## Immutable inputs

| Artifact | Pin |
| --- | --- |
| vLLM image | `vllm/vllm-openai@sha256:c2914767605584b6d8f45686b82de173ecc99e781897aa3d0a66dacd72c51ae1` |
| vLLM release | `v0.29.0` |
| Model | `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` |
| Model revision | `eb3172f06a6d6b3a15f08947b0668d782e4d2d2c` |

The selected vLLM release uses CUDA 13.0.3 and builds for Turing compute capability 7.5. Its compatibility table lists AWQ support for Turing. The model revision contains approximately 9.3 GiB of repository content.

Upstream references:

- [vLLM v0.29.0 release](https://github.com/vllm-project/vllm/releases/tag/v0.29.0)
- [vLLM v0.29.0 build versions](https://github.com/vllm-project/vllm/blob/v0.29.0/docker/versions.json)
- [vLLM quantization compatibility](https://github.com/vllm-project/vllm/blob/v0.29.0/docs/features/quantization/README.md)
- [Qwen model snapshot](https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-AWQ/tree/eb3172f06a6d6b3a15f08947b0668d782e4d2d2c)

## T4-safe starting configuration

The manifest starts conservatively:

| Setting | Value | Reason |
| --- | --- | --- |
| Activation dtype | FP16 | T4 does not provide native BF16 support |
| Weight quantization | AWQ 4-bit | Fits 14B weights on the 16-GiB GPU |
| Maximum context | 8,192 tokens | Preserves room for runtime overhead and KV cache |
| Concurrent sequences | 1 | Establishes a reliable baseline before throughput tuning |
| GPU memory utilization | 0.88 | Leaves headroom instead of allocating nearly all VRAM |
| Execution | Eager | Avoids initial CUDA graph memory pressure during bring-up |
| Shared memory | 2 GiB | Provides container-local `/dev/shm` without host IPC |

Do not increase context length or concurrency until `nvidia-smi` measurements show safe headroom under realistic prompts.

## Offline checks

Run these on the workstation while the VM is deallocated:

```bash
bash -n \
  scripts/cloud/stage-qwen25-coder-awq.sh \
  scripts/cloud/deploy-qwen25-coder-awq.sh

git diff --check
```

If `kubectl` is available locally, client-side validation can also be run without contacting a cluster:

```bash
kubectl apply --dry-run=client -f manifests/storage/qwen25-coder-gpu-local-pv.yaml
kubectl apply --dry-run=client -f manifests/runtimes/vllm/qwen25-coder-14b-awq-config.yaml
kubectl apply --dry-run=client -f manifests/runtimes/vllm/qwen25-coder-14b-awq-stage.yaml
kubectl apply --dry-run=client -f manifests/runtimes/vllm/qwen25-coder-14b-awq.yaml
```

## Paid-session sequence

### 1. Start and inspect

```bash
scripts/cloud/azure/start-gpu-vm.sh
scripts/cloud/azure/gpu-vm-status.sh
```

After SSH access is available, verify the GPU and identify the attached 128-GiB model disk:

```bash
nvidia-smi
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
```

Never infer the data-device name from an example.

### 2. Bootstrap the node once

After replacing the placeholder with the verified block device:

```bash
sudo DATA_DEVICE=/dev/<verified-device> scripts/cloud/prepare-gpu-node.sh
```

The script may format `DATA_DEVICE` when it has no filesystem. It refuses to run without a working host NVIDIA driver.

### 3. Stage the immutable model snapshot

```bash
sudo scripts/cloud/stage-qwen25-coder-awq.sh
```

The staging Job requests no GPU. It pulls the pinned vLLM image and pinned model revision into the retained local volume. It refuses to download if `/var/lib/llm-recovery/ollama` is not a mounted filesystem, preventing an accidental 10-GiB model download onto the OS disk.

When the script reports success, the vLLM server has not started. This is a safe checkpoint to deallocate the VM:

```bash
scripts/cloud/azure/deallocate-gpu-vm.sh
```

### 4. Deploy vLLM

When ready for the inference test, start the VM and run:

```bash
scripts/cloud/azure/start-gpu-vm.sh
sudo scripts/cloud/deploy-qwen25-coder-awq.sh
```

The server reads the staged snapshot with Hugging Face offline mode enabled. The Service is `ClusterIP`; port 8000 is not exposed through the VM public IP.

Inspect placement and memory before sending a request:

```bash
kubectl get pods -n llm-recovery-lab -o wide
nvidia-smi
```

### 5. Run the controlled inference gate

Run one bounded code-review request through a localhost-only port-forward:

```bash
scripts/readiness/qwen25-coder-vllm-smoke-test.sh
```

The test does not expose a NodePort or public endpoint. It records:

- the exact Git commit and pod manifest
- `/v1/models` output
- the fixed request and raw response
- the extracted answer
- GPU memory before and after inference
- a short vLLM log tail

Evidence is written beneath `results/vllm-smoke/<UTC-run-id>/`. Review `answer.txt` manually; successful HTTP inference does not establish that the model's recommendations are correct.

After preserving the evidence, deallocate immediately:

```bash
scripts/cloud/azure/deallocate-gpu-vm.sh
```

Do not connect the endpoint to repositories, pipelines, or AKS clusters until this gate is reviewed.

## Failure handling

The scripts preserve a failed staging Job and its logs. Do not delete it until its error output has been captured:

```bash
kubectl logs job/stage-qwen25-coder-14b-awq \
  -n llm-recovery-lab \
  --all-containers=true
```

If vLLM does not become Ready, the deployment script prints pod placement and the last 200 log lines. Capture those diagnostics before changing memory or model settings.
