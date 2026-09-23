#!/usr/bin/env bash
# GATEWAY STEP 2 - Gateway API CRDs + HAProxy Unified Gateway + shared Gateway "apps".
# Run on Bastion as an AD cluster-admin:  /opt/k8s-lab/gateway/gw-2-hug.sh
#   http://*.apps.corp.example  and  https://*.apps.corp.example  on 10.10.1.25 (MetalLB)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NS=haproxy-unified-gateway
kubectl auth can-i '*' '*' -A >/dev/null || { echo "Needs cluster-admin (run as a K8s-Admins AD user)" >&2; exit 1; }
helm repo add haproxytech https://haproxytech.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update haproxytech >/dev/null
echo "== install HAProxy Unified Gateway (chart 1.2.0 installs Gateway API CRDs v1.3.0)"
helm upgrade --install haproxy-unified-gateway haproxytech/haproxy-unified-gateway --version 1.2.0 \
  --namespace $NS --create-namespace -f "$HERE/hug-values.yaml" --wait --timeout 8m
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io >/dev/null
# the chart installs the CRDs in a post-install job, AFTER the controller pods start; restart them so
# the controller watches the now-existing Gateway API / HUG types (otherwise HAProxy never gets a valid config)
kubectl -n $NS rollout restart deploy/haproxy-unified-gateway
kubectl -n $NS rollout status deploy/haproxy-unified-gateway --timeout=180s

echo "== GatewayClass, wildcard TLS secret, Gateway 'apps'"
kubectl -n $NS create secret tls apps-wildcard-tls --cert="$HERE/apps-wildcard.crt" --key="$HERE/apps-wildcard.key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: {name: haproxy}
spec:
  controllerName: gate.haproxy.org/hug
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: apps, namespace: $NS}
spec:
  gatewayClassName: haproxy
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.apps.corp.example"
    allowedRoutes: {namespaces: {from: All}}
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.apps.corp.example"
    tls:
      mode: Terminate
      certificateRefs: [{kind: Secret, name: apps-wildcard-tls}]
    allowedRoutes: {namespaces: {from: All}}
YAML
echo "== waiting for the Gateway to be accepted/programmed"
kubectl -n $NS wait gateway/apps --for=condition=Accepted --timeout=180s || true
kubectl -n $NS wait gateway/apps --for=condition=Programmed --timeout=180s || true
kubectl get gatewayclass haproxy
kubectl -n $NS get gateway apps
kubectl -n $NS get svc -o wide
kubectl -n $NS get pods -o wide
