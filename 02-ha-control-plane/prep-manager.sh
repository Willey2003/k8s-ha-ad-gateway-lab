#!/usr/bin/env bash
# Prepare a fresh Ubuntu 24.04 VM to join as an extra control-plane node.
# Mirrors the existing "manager" (10.10.1.14) exactly. Run on the NEW VM:
#   sudo ./prep-manager.sh
# It does NOT join the cluster - that is a separate step.
set -euo pipefail

K8S_MINOR=v1.32
K8S_PKG=1.32.13-1.1
CRIO_PKG=1.32.1-1.1

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

echo "== Swap off (now and on reboot)"
swapoff -a
sed -ri '/\sswap\s/s/^([^#])/#\1/' /etc/fstab
systemctl mask swap.target >/dev/null

echo "== Never suspend (matters on Desktop images)"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null

echo "== Kernel modules and sysctls"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "== Package repos (same as manager)"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg >/dev/null
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/$K8S_MINOR/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

echo "== Install pinned versions"
apt-get update -qq
apt-get install -y -qq --allow-downgrades \
  cri-o="$CRIO_PKG" kubelet="$K8S_PKG" kubeadm="$K8S_PKG" kubectl="$K8S_PKG" >/dev/null
apt-mark hold cri-o kubelet kubeadm kubectl >/dev/null
systemctl enable --now crio kubelet

echo "== Checks"
echo "swap entries: $(swapon --show --noheadings | wc -l) (want 0)"
crio --version | head -1
kubeadm version -o short
for ep in 10.10.1.12 10.10.1.13 10.10.1.19; do
  timeout 3 bash -c "</dev/tcp/$ep/2379" && echo "etcd $ep:2379 reachable" || echo "etcd $ep:2379 NOT reachable" >&2
done
timeout 3 bash -c "</dev/tcp/10.10.1.14/6443" && echo "manager API reachable" || echo "manager API NOT reachable" >&2
echo "Done. Ready for the control-plane join step."
