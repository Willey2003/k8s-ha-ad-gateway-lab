#!/usr/bin/env bash
# AD PHASE 1b - let PODS resolve corp.example too. Run once on a manager:  sudo ./ad-1b-coredns.sh
# Adds a corp.example server block to CoreDNS that forwards only to the DCs.
# CoreDNS reloads the config by itself (reload plugin) within ~30s; no restart needed.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
BK=/root/coredns-cm-backup-$(date +%Y%m%d-%H%M%S).yaml
kubectl -n kube-system get cm coredns -o yaml > "$BK"; echo "backup: $BK"
CUR=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
if grep -q '^corp.example:53' <<<"$CUR"; then echo "corp.example block already present"; exit 0; fi
NEW="$CUR
corp.example:53 {
    errors
    cache 30
    forward . 10.10.5.251 10.10.5.252
}"
kubectl -n kube-system create cm coredns --from-literal=Corefile="$NEW" --dry-run=client -o yaml | kubectl apply -f -
echo "waiting 45s for CoreDNS to reload..."; sleep 45
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5 | grep -i reload || true
kubectl run dns-check-$RANDOM --rm -i --restart=Never --image=docker.io/library/busybox:1.36 -- \
  sh -c 'nslookup k8s-api.corp.example; nslookup kubernetes.default.svc.cluster.local' 2>&1 | grep -E 'Name:|Address' | grep -v '#53'
echo "undo: kubectl apply -f $BK"
