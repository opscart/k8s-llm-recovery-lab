#!/usr/bin/env bash

set -euo pipefail

KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.35}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35.1-1.1}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "run this script with sudo"
  fi
}

configure_kernel() {
  swapoff -a
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sysctl --system >/dev/null
}

install_containerd() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gpg containerd

  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml

  sed -i \
    's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

  systemctl enable --now containerd
  systemctl restart containerd
}

install_kubernetes() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https ca-certificates curl gpg

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
    | gpg --dearmor \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF

  apt-get update

  if ! apt-cache madison kubeadm | awk '{print $3}' | grep -Fxq "$KUBERNETES_VERSION"; then
    echo "Requested Kubernetes package version is unavailable:"
    echo "  $KUBERNETES_VERSION"
    echo
    echo "Available kubeadm versions:"
    apt-cache madison kubeadm | head -n 20
    exit 1
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "kubelet=${KUBERNETES_VERSION}" \
    "kubeadm=${KUBERNETES_VERSION}" \
    "kubectl=${KUBERNETES_VERSION}"

  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
}

print_versions() {
  echo
  echo "Installed versions"
  echo "------------------"
  containerd --version
  kubeadm version -o short
  kubectl version --client
}


JOIN_COMMAND="${JOIN_COMMAND:-}"

require_root

echo "Preparing kubeadm worker"
echo "Hostname           : $(hostname)"
echo "Kubernetes package : $KUBERNETES_VERSION"

configure_kernel
install_containerd
install_kubernetes

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  fail "/etc/kubernetes/kubelet.conf already exists; this node appears to be joined already"
fi

print_versions

if [[ -z "$JOIN_COMMAND" ]]; then
  echo
  echo "Worker prerequisites are ready."
  echo
  echo "Run the join command produced on Node A, for example:"
  echo "  sudo kubeadm join <control-plane-private-ip>:6443 ... --cri-socket unix:///run/containerd/containerd.sock"
  echo
  echo "Or rerun this script with JOIN_COMMAND set."
  exit 0
fi

echo
echo "Joining worker to the cluster..."
bash -c "$JOIN_COMMAND"

echo
echo "Worker join command completed."
echo "Return to Node A and verify this node becomes Ready."
