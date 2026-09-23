#!/usr/bin/env bash
# Failover test for the control-plane VIP. Run on whichever manager currently HOLDS the VIP:
#   sudo ./vip-failover-test.sh
# Temporarily stops kube-vip on this node, checks that another manager takes over
# 10.10.1.20 and the API keeps answering, then puts kube-vip back (it rejoins as standby).
set -euo pipefail
VIP=10.10.1.20
M=/etc/kubernetes/manifests/kube-vip.yaml
PARK=/root/kube-vip.yaml.parked
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
ip -4 addr | grep -q " $VIP/" || { echo "$(hostname) does not hold the VIP - run this on the holder" >&2; exit 1; }
[[ -f $M ]] || { echo "$M missing" >&2; exit 1; }
api_ok() { curl -s --max-time 2 --cacert /etc/kubernetes/pki/ca.crt "https://$VIP:6443/livez" | grep -qx ok; }

trap '[[ -f $PARK ]] && mv $PARK $M && echo "kube-vip manifest restored on $(hostname)"' EXIT

echo "== $(hostname) holds $VIP - stopping kube-vip here"
T0=$(date +%s)
mv $M $PARK

for _ in $(seq 1 30); do ip -4 addr | grep -q " $VIP/" || break; sleep 1; done
if ip -4 addr | grep -q " $VIP/"; then
  echo "kube-vip did not release the VIP - removing it by hand"
  ip -4 -o addr | awk -v v=" $VIP/" 'index($0,v){print $2}' | while read -r dev; do ip addr del "$VIP/32" dev "$dev"; done
fi
echo "VIP released after $(( $(date +%s) - T0 ))s"

for _ in $(seq 1 90); do api_ok && break; sleep 1; done
if api_ok; then
  echo "API answering on $VIP again after $(( $(date +%s) - T0 ))s (served by another manager)"
  ping -c1 -W1 $VIP >/dev/null 2>&1 || true
  echo "VIP now at MAC: $(ip neigh show $VIP | awk '{print $5}')"
  kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide | awk 'NR==1 || /control-plane/ {print $1, $2, $6}'
else
  echo "FAILED: API not reachable on $VIP after 90s - restoring kube-vip here" >&2
  exit 1
fi
