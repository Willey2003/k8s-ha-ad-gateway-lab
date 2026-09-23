#!/usr/bin/env bash
# STEP 2 of the VIP switch. Run on each WORKER (worker-a..d) after step 1:
#   sudo ./vip-2-kubelet.sh
# Points the kubelet at the VIP instead of 10.10.1.14 and restarts it.
# Running pods are not restarted.
set -euo pipefail
VIP=10.10.1.20
OLD=10.10.1.14
CONF=/etc/kubernetes/kubelet.conf
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

curl -s --max-time 5 --cacert /etc/kubernetes/pki/ca.crt "https://$VIP:6443/livez" | grep -qx ok \
  || { echo "API not reachable/valid on VIP $VIP - run step 1 first. Nothing changed." >&2; exit 1; }

if grep -q "server: https://$VIP:6443" $CONF; then
  echo "kubelet already uses the VIP"
else
  cp -a $CONF $CONF.pre-vip
  sed -i "s|server: https://$OLD:6443|server: https://$VIP:6443|" $CONF
  grep -q "server: https://$VIP:6443" $CONF || { cp -a $CONF.pre-vip $CONF; echo "Unexpected server in $CONF - restored, nothing changed" >&2; exit 1; }
  systemctl restart kubelet
fi
sleep 10
echo "$(hostname): kubelet=$(systemctl is-active kubelet)  server=$(grep -o 'server: .*' $CONF)"
