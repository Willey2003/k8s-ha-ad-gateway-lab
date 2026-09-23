#!/usr/bin/env bash
# GATEWAY STEP 1 - MetalLB (layer-2) so LoadBalancer Services get real LAN IPs.
# Run on Bastion as an AD cluster-admin (e.g. lab_admin1):  /opt/k8s-lab/gateway/gw-1-metallb.sh
# Pools: 10.10.1.25-29 (+ .40-.49 after router /24 fix), announced from worker nodes only (speakers do not run on managers).
set -euo pipefail
# the router (10.10.1.1) currently routes only 10.10.1.0/27, so .25-.29 are reachable from other
# networks; .40-.49 only become usable once the router interface is changed to /24
POOL1=10.10.1.25-10.10.1.29
POOL2=10.10.1.40-10.10.1.49
kubectl auth can-i '*' '*' -A >/dev/null || { echo "Needs cluster-admin (run as a K8s-Admins AD user)" >&2; exit 1; }
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update metallb >/dev/null
echo "== install MetalLB 0.16.1"
helm upgrade --install metallb metallb/metallb --version 0.16.1 \
  --namespace metallb-system --create-namespace \
  --set speaker.memberlist.enabled=false \
  --set frrk8s.enabled=false \
  --wait --timeout 5m
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=180s
kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=180s
echo "== address pools $POOL1, $POOL2 + L2 advertisement (workers only)"
kubectl apply -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: lab-pool, namespace: metallb-system}
spec:
  addresses: ["$POOL1", "$POOL2"]
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: lab-l2, namespace: metallb-system}
spec:
  ipAddressPools: [lab-pool]
  nodeSelectors:
  - matchExpressions:
    - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
YAML
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system get ipaddresspool,l2advertisement
echo "MetalLB ready."
