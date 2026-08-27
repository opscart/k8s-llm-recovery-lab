#!/usr/bin/env bash
set -euo pipefail

# Ubuntu bootstrap for Kubernetes LLM recovery experiments.
#
# Installs:
#   - Docker Engine
#   - kubectl
#   - minikube
#   - git / jq / Python tooling
#
# Creates a SINGLE-NODE Minikube cluster by default.
# This is intentional for the first cloud CPU baseline.
#
# Override:
#   MINIKUBE_PROFILE=llm-cloud \
#   MINIKUBE_CPUS=14 \
#   MINIKUBE_MEMORY_MB=56000 \
#   MINIKUBE_DISK_SIZE=200g \
#   K8S_VERSION=v1.35.1 \
#   ./bootstrap-minikube.sh
#
# For later cold-node experiments, create a separate multi-node profile
# rather than changing the baseline cluster.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as the normal SSH user, not root."
  exit 1
fi

PROFILE="${MINIKUBE_PROFILE:-llm-cloud}"
NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
DISK_SIZE="${MINIKUBE_DISK_SIZE:-200g}"
K8S_VERSION="${K8S_VERSION:-}"

HOST_CPUS="$(nproc)"
HOST_MEM_MB="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"

# Reserve capacity for Ubuntu/Docker.
DEFAULT_CPUS=$(( HOST_CPUS > 4 ? HOST_CPUS - 2 : HOST_CPUS ))
DEFAULT_MEM_MB=$(( HOST_MEM_MB * 80 / 100 ))

MINIKUBE_CPUS="${MINIKUBE_CPUS:-$DEFAULT_CPUS}"
MINIKUBE_MEMORY_MB="${MINIKUBE_MEMORY_MB:-$DEFAULT_MEM_MB}"

echo "============================================================"
echo "Ubuntu cloud CPU bootstrap"
echo "============================================================"
echo "Host CPUs              : $HOST_CPUS"
echo "Host memory            : ${HOST_MEM_MB} MiB"
echo "Minikube profile       : $PROFILE"
echo "Minikube CPUs          : $MINIKUBE_CPUS"
echo "Minikube memory        : ${MINIKUBE_MEMORY_MB} MiB"
echo "Minikube disk          : $DISK_SIZE"
echo "Namespace              : $NAMESPACE"
echo "Kubernetes version     : ${K8S_VERSION:-minikube default}"
echo

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  git \
  gnupg \
  jq \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv

echo
echo "== Installing Docker Engine =="

# Remove conflicting distro packages if present.
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

echo
echo "== Installing kubectl =="

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) KUBECTL_ARCH="amd64" ;;
  arm64) KUBECTL_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture for this script: $ARCH"
    exit 1
    ;;
esac

KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
curl -fLO \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
curl -fLO \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl.sha256"

echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl kubectl.sha256

echo
echo "== Installing Minikube =="

case "$ARCH" in
  amd64) MINIKUBE_ARCH="amd64" ;;
  arm64) MINIKUBE_ARCH="arm64" ;;
esac

curl -fLO \
  "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${MINIKUBE_ARCH}"
sudo install \
  "minikube-linux-${MINIKUBE_ARCH}" \
  /usr/local/bin/minikube
rm -f "minikube-linux-${MINIKUBE_ARCH}"

echo
echo "== Versions =="
docker --version || sudo docker --version
kubectl version --client
minikube version

echo
echo "== Starting Minikube =="

START_ARGS=(
  start
  --profile "$PROFILE"
  --driver=docker
  --cpus="$MINIKUBE_CPUS"
  --memory="$MINIKUBE_MEMORY_MB"
  --disk-size="$DISK_SIZE"
)

if [[ -n "$K8S_VERSION" ]]; then
  START_ARGS+=(--kubernetes-version="$K8S_VERSION")
fi

# The docker-group membership added above is not active in this shell yet.
# `sg docker` gives only this command the required group.
printf -v START_CMD '%q ' minikube "${START_ARGS[@]}"
sg docker -c "$START_CMD"

minikube profile "$PROFILE"
kubectl config use-context "$PROFILE"

echo
echo "== Creating experiment namespace =="
kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace="$NAMESPACE" >/dev/null

echo
echo "== Baseline environment evidence =="

mkdir -p "$HOME/llm-cloud-environment"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "ubuntu=$(lsb_release -ds)"
  echo "kernel=$(uname -r)"
  echo "architecture=$(uname -m)"
  echo "host_cpus=$(nproc)"
  echo "host_memory_kib=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  echo "docker=$(docker --version 2>/dev/null || sudo docker --version)"
  echo "kubectl_client=$(/usr/local/bin/kubectl version --client -o yaml | tr '\n' ' ')"
  echo "minikube=$(minikube version --short)"
} | tee "$HOME/llm-cloud-environment/environment.txt"

kubectl get nodes -o wide \
  | tee "$HOME/llm-cloud-environment/nodes.txt"

kubectl describe node \
  | tee "$HOME/llm-cloud-environment/node-describe.txt" >/dev/null

sg docker -c "docker info" \
  > "$HOME/llm-cloud-environment/docker-info.txt"

echo
echo "============================================================"
echo "Bootstrap complete"
echo "============================================================"
echo
echo "NOTE: log out and SSH back in once so your normal shell picks up"
echo "the docker group membership."
echo
echo "After reconnecting:"
echo "  minikube profile $PROFILE"
echo "  kubectl get nodes -o wide"
echo "  kubectl config set-context --current --namespace=$NAMESPACE"
echo
echo "Environment evidence:"
echo "  $HOME/llm-cloud-environment/"
