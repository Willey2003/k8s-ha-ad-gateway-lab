#!/usr/bin/env bash
# Undo STEP 1 on "manager" (use only if step 1 went wrong):
#   sudo ./vip-rollback.sh
# Restores /etc/kubernetes and the ConfigMaps from the latest backup and removes kube-vip.
# On any worker already switched by step 2, restore with:
#   sudo cp -a /etc/kubernetes/kubelet.conf.pre-vip /etc/kubernetes/kubelet.conf && sudo systemctl restart kubelet
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
BK=$(readlink -f /root/k8s-vip-backup-latest)
[[ -f $BK/etc-kubernetes.tgz ]] || { echo "No backup found" >&2; exit 1; }
echo "== Restoring from $BK"
rm -f /etc/kubernetes/manifests/kube-vip.yaml
tar -C / -xzf "$BK/etc-kubernetes.tgz"
crictl stop $(crictl ps --name kube-apiserver -q) >/dev/null 2>&1 || true
for _ in $(seq 1 60); do curl -s --max-time 3 --cacert /etc/kubernetes/pki/ca.crt https://10.10.1.14:6443/livez | grep -qx ok && break; sleep 2; done
export KUBECONFIG=/etc/kubernetes/admin.conf
for f in cm-kubeadm-config cm-kube-proxy cm-cluster-info; do
  grep -vE '^\s+(resourceVersion|uid|creationTimestamp):' "$BK/$f.yaml" | kubectl replace -f -
done
kubectl -n kube-system rollout restart ds kube-proxy
ip -4 addr del 10.10.1.20/32 dev ens34 2>/dev/null || true
kubectl get nodes
echo "Rolled back to 10.10.1.14."
