#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.35}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35.1-1.1}"
DEVICE_PLUGIN_VERSION="${DEVICE_PLUGIN_VERSION:-v0.20.0}"
MODEL_MOUNT="${MODEL_MOUNT:-/var/lib/llm-recovery/ollama}"
DATA_DEVICE="${DATA_DEVICE:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "run with sudo"
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found; verify Azure NVIDIA driver first"

nvidia-smi

if [[ -n "$DATA_DEVICE" ]]; then
  [[ -b "$DATA_DEVICE" ]] || fail "DATA_DEVICE is not a block device: $DATA_DEVICE"
  mkdir -p "$MODEL_MOUNT"

  if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    mkfs.ext4 -F "$DATA_DEVICE"
  fi

  UUID="$(blkid -s UUID -o value "$DATA_DEVICE")"
  [[ -n "$UUID" ]] || fail "could not determine filesystem UUID for $DATA_DEVICE"

  if ! grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID $MODEL_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  mount -a
else
  echo "DATA_DEVICE not set; disk formatting/mount skipped."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_PLANE_SCRIPT="$SCRIPT_DIR/prepare-kubeadm-control-plane.sh"
[[ -x "$CONTROL_PLANE_SCRIPT" ]] || fail "missing executable: $CONTROL_PLANE_SCRIPT"

KUBERNETES_MINOR="$KUBERNETES_MINOR" KUBERNETES_VERSION="$KUBERNETES_VERSION" "$CONTROL_PLANE_SCRIPT"

export KUBECONFIG=/etc/kubernetes/admin.conf

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
kubectl label node "$NODE_NAME" llm-recovery-role=gpu --overwrite

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg

install -m 0755 -d /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey   | gpg --dearmor --yes   -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list   | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g'   > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd
systemctl restart kubelet

kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=180s

for _ in $(seq 1 120); do
  GPU="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  [[ "$GPU" == "1" ]] && break
  sleep 1
done

GPU="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
[[ "$GPU" == "1" ]] || fail "Kubernetes did not advertise nvidia.com/gpu=1"

mkdir -p "$MODEL_MOUNT"
chmod 0755 "$MODEL_MOUNT"

echo "GPU node preparation completed."
nvidia-smi
kubectl get nodes -o wide
kubectl get node "$NODE_NAME" -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

