#!/usr/bin/env bash
# STEP 1 of the VIP switch. Run on the existing control plane "manager" (10.10.1.14):
#   sudo ./vip-1-manager.sh
# - backs up /etc/kubernetes and the ConfigMaps it changes
# - starts kube-vip so 10.10.1.20 answers for the API server
# - re-issues the API server cert with the VIP (and new managers) in its SANs
# - sets controlPlaneEndpoint=VIP in kubeadm-config, admin.conf, kube-proxy, cluster-info
# The API server restarts once (~30s). Workers keep using 10.10.1.14 until step 2.
set -euo pipefail

VIP=10.10.1.20
OLD=10.10.1.14
NODE_NAME=manager
SANS=(10.10.1.20 10.10.1.14 10.10.1.21 10.10.1.22 manager manager-2 manager-3)
KVIP_MANIFEST=${KVIP_MANIFEST:-$HOME/kube-vip-manager.yaml}

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
[[ -f $KVIP_MANIFEST ]] || KVIP_MANIFEST=/home/${SUDO_USER:-labops}/kube-vip-manager.yaml
[[ -f $KVIP_MANIFEST ]] || { echo "kube-vip-manager.yaml not found" >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
K=/etc/kubernetes
TS=$(date +%Y%m%d-%H%M%S)
BK=/root/k8s-vip-backup-$TS
step() { echo; echo "== $*"; }
api_ok() { curl -s --max-time 3 --cacert $K/pki/ca.crt "https://$1:6443/livez" | grep -qx ok; }
wait_api() { for _ in $(seq 1 60); do api_ok "$1" && return 0; sleep 2; done; echo "API on $1 did not come back" >&2; return 1; }

step "Pre-checks"
api_ok $OLD || { echo "API server on $OLD is not healthy - aborting" >&2; exit 1; }
if ping -c1 -W1 $VIP >/dev/null 2>&1 && ! ip -4 addr | grep -q " $VIP/"; then
  echo "$VIP already answers on the network - something else uses it. Aborting." >&2; exit 1
fi
kubectl get cm kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cc.yaml
grep -q "^controlPlaneEndpoint: $OLD:6443$" /tmp/cc.yaml || grep -q "^controlPlaneEndpoint: $VIP:6443$" /tmp/cc.yaml \
  || { echo "Unexpected controlPlaneEndpoint in kubeadm-config - aborting" >&2; exit 1; }

step "Backup to $BK"
mkdir -p "$BK"
tar -C / -czf "$BK/etc-kubernetes.tgz" etc/kubernetes
kubectl get cm kubeadm-config -n kube-system -o yaml > "$BK/cm-kubeadm-config.yaml"
kubectl get cm kube-proxy     -n kube-system -o yaml > "$BK/cm-kube-proxy.yaml"
kubectl get cm cluster-info   -n kube-public -o yaml > "$BK/cm-cluster-info.yaml"
ln -sfn "$BK" /root/k8s-vip-backup-latest
echo "saved"

step "Start kube-vip (VIP $VIP)"
install -m 0644 "$KVIP_MANIFEST" $K/manifests/kube-vip.yaml
for _ in $(seq 1 60); do ip -4 addr | grep -q " $VIP/" && break; sleep 2; done
ip -4 addr | grep -q " $VIP/" || { echo "kube-vip did not claim $VIP - check: crictl logs \$(crictl ps --name kube-vip -q)" >&2; exit 1; }
echo "VIP is up on this node"

step "Re-issue API server certificate with VIP in SANs"
{
  cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $OLD
  bindPort: 6443
nodeRegistration:
  name: $NODE_NAME
  criSocket: unix:///var/run/crio/crio.sock
---
EOF
  awk -v vip="$VIP" -v sans="${SANS[*]}" '
    /^controlPlaneEndpoint:/ { print "controlPlaneEndpoint: " vip ":6443"; next }
    /^apiServer: \{\}$/      { n = split(sans, s, " "); print "apiServer:"; print "  certSANs:"
                               for (i = 1; i <= n; i++) print "  - " s[i]; next }
    { print }' /tmp/cc.yaml
} > /root/kubeadm-vip.yaml
grep -q "certSANs" /root/kubeadm-vip.yaml || { echo "Could not add certSANs (apiServer section not '{}') - edit /root/kubeadm-vip.yaml by hand" >&2; exit 1; }
mv $K/pki/apiserver.crt $K/pki/apiserver.key "$BK/"
kubeadm init phase certs apiserver --config /root/kubeadm-vip.yaml
openssl x509 -in $K/pki/apiserver.crt -noout -ext subjectAltName | tail -1

step "Restart API server to load the new certificate"
crictl stop $(crictl ps --name kube-apiserver -q) >/dev/null
sleep 5
wait_api $OLD && wait_api $VIP && echo "API healthy on $OLD and on VIP $VIP (cert verified)"

step "Point cluster config at the VIP"
kubeadm init phase upload-config kubeadm --config /root/kubeadm-vip.yaml
for f in admin.conf super-admin.conf; do
  [[ -f $K/$f ]] && sed -i "s|server: https://$OLD:6443|server: https://$VIP:6443|" $K/$f
done
kubectl get cm kube-proxy -n kube-system -o yaml | sed "s|https://$OLD:6443|https://$VIP:6443|" | kubectl replace -f -
kubectl get cm cluster-info -n kube-public -o yaml | sed "s|https://$OLD:6443|https://$VIP:6443|" | kubectl replace -f -
kubectl -n kube-system rollout restart ds kube-proxy
kubectl -n kube-system rollout status ds kube-proxy --timeout=180s

step "Result"
kubectl get cm kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}' | grep controlPlaneEndpoint
kubectl get nodes
echo
echo "Step 1 done. Backup: $BK"
echo "Next: run vip-2-kubelet.sh on each worker."
