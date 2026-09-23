#!/usr/bin/env bash
# STEP 3 of the VIP switch. Joins this VM as an extra control-plane node.
# Run on manager-2 / manager-3, passing the join command printed on "manager":
#   sudo ./vip-3-join.sh kubeadm join 10.10.1.20:6443 --token ... --discovery-token-ca-cert-hash ... --control-plane --certificate-key ...
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
[[ ${1:-} == kubeadm && ${2:-} == join ]] || { echo "Pass the full 'kubeadm join ...' command as arguments" >&2; exit 1; }
[[ " $* " == *" --control-plane "* ]] || { echo "Join command must include --control-plane" >&2; exit 1; }

NODE=$(hostname)
IP=$(ip -4 -o route get 10.10.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
KVIP=/home/${SUDO_USER:-labops}/kube-vip-$NODE.yaml
[[ -f $KVIP ]] || { echo "$KVIP not found" >&2; exit 1; }
[[ -f /etc/kubernetes/admin.conf ]] && { echo "This node already has /etc/kubernetes/admin.conf - already joined?" >&2; exit 1; }

echo "== Joining $NODE ($IP) as control plane"
"$@" --apiserver-advertise-address "$IP"

echo "== Starting kube-vip on $NODE"
install -m 0644 "$KVIP" /etc/kubernetes/manifests/kube-vip.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf
for _ in $(seq 1 60); do
  kubectl get pod -n kube-system "kube-apiserver-$NODE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break; sleep 3
done
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide --field-selector spec.nodeName="$NODE"
