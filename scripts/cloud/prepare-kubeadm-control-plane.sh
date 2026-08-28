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


POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
API_ADVERTISE_ADDRESS="${API_ADVERTISE_ADDRESS:-}"
CNI_MANIFEST="${CNI_MANIFEST:-}"

require_root

if [[ -z "$API_ADVERTISE_ADDRESS" ]]; then
  API_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')
fi

[[ -n "$API_ADVERTISE_ADDRESS" ]] \
  || fail "could not determine API advertise address"

echo "Preparing kubeadm control plane"
echo "Hostname              : $(hostname)"
echo "API advertise address : $API_ADVERTISE_ADDRESS"
echo "Pod CIDR              : $POD_CIDR"
echo "Kubernetes package    : $KUBERNETES_VERSION"

configure_kernel
install_containerd
install_kubernetes

if [[ -f /etc/kubernetes/admin.conf ]]; then
  fail "/etc/kubernetes/admin.conf already exists; refusing to overwrite an existing cluster"
fi

kubeadm init \
  --kubernetes-version "${KUBERNETES_VERSION%-1.1}" \
  --apiserver-advertise-address "$API_ADVERTISE_ADDRESS" \
  --pod-network-cidr "$POD_CIDR" \
  --cri-socket unix:///run/containerd/containerd.sock

USER_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"

if [[ -n "${SUDO_USER:-}" && -n "$USER_HOME" ]]; then
  mkdir -p "$USER_HOME/.kube"
  cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
fi

echo
echo "Removing the control-plane NoSchedule taint for this two-node research lab..."
kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes \
  "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule- \
  >/dev/null 2>&1 || true

echo
echo "Lab labels"
kubectl --kubeconfig /etc/kubernetes/admin.conf label node "$(hostname)" \
  llm-recovery-role=source \
  --overwrite

if [[ -n "$CNI_MANIFEST" ]]; then
  echo
  echo "Applying supplied CNI manifest: $CNI_MANIFEST"
  kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f "$CNI_MANIFEST"
else
  echo
  echo "CNI was intentionally not installed."
  echo "Set CNI_MANIFEST to a reviewed/pinned CNI manifest before running,"
  echo "or apply the chosen CNI manually after kubeadm init."
fi

JOIN_FILE="/tmp/kubeadm-join-command.sh"

{
  echo '#!/usr/bin/env bash'
  kubeadm token create --print-join-command \
    | sed 's#$# --cri-socket unix:///run/containerd/containerd.sock#'
} >"$JOIN_FILE"

chmod 0700 "$JOIN_FILE"

print_versions

echo
echo "Control-plane preparation completed."
echo
echo "Join command written to:"
echo "  $JOIN_FILE"
echo
echo "Copy the command securely to Node B. Do not commit the join token."
echo
echo "Before joining Node B, verify:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
