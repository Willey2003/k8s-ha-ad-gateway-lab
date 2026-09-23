#!/usr/bin/env bash
# GATEWAY STEP 3 - let every AD user publish apps from playground, and deploy a demo app.
# Run on Bastion as an AD cluster-admin:  /opt/k8s-lab/gateway/gw-3-routes-demo.sh
#   demo: http(s)://hello.apps.corp.example  -> Deployment "hello" in namespace playground
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
kubectl auth can-i '*' '*' -A >/dev/null || { echo "Needs cluster-admin (run as a K8s-Admins AD user)" >&2; exit 1; }
echo "== RBAC: HTTPRoutes join the built-in edit/view roles (so playground users can publish apps)"
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-routes-edit
  labels: {rbac.authorization.k8s.io/aggregate-to-edit: "true", rbac.authorization.k8s.io/aggregate-to-admin: "true"}
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: [httproutes, grpcroutes, referencegrants]
  verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-api-view
  labels: {rbac.authorization.k8s.io/aggregate-to-view: "true"}
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: [gatewayclasses, gateways, httproutes, grpcroutes, referencegrants]
  verbs: [get, list, watch]
YAML
echo "== demo app in playground"
kubectl apply -n playground -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: hello, labels: {app: hello}}
spec:
  replicas: 2
  selector: {matchLabels: {app: hello}}
  template:
    metadata: {labels: {app: hello}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 101, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: hello
        image: docker.io/nginxinc/nginx-unprivileged:1.27-alpine
        ports: [{containerPort: 8080}]
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: html, mountPath: /usr/share/nginx/html}]
      initContainers:
      - name: page
        image: docker.io/library/busybox:1.36
        command: ["sh", "-c", "echo \"Hello from LAB lab - pod $(hostname) - via HAProxy Unified Gateway\" > /html/index.html"]
        securityContext: {runAsNonRoot: true, runAsUser: 101, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: html, mountPath: /html}]
      volumes: [{name: html, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: hello}
spec:
  selector: {app: hello}
  ports: [{name: http, port: 80, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: hello}
spec:
  parentRefs: [{name: apps, namespace: haproxy-unified-gateway}]
  hostnames: [hello.apps.corp.example]
  rules:
  - backendRefs: [{name: hello, port: 80}]
YAML
kubectl -n playground rollout status deploy/hello --timeout=180s
sleep 5
kubectl -n playground get httproute hello -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
echo "== test through the gateway (10.10.1.25)"
curl -s --max-time 10 --resolve hello.apps.corp.example:80:10.10.1.25 http://hello.apps.corp.example/ || echo "HTTP test failed"
curl -s --max-time 10 --cacert "$HERE/lab-ca.crt" --resolve hello.apps.corp.example:443:10.10.1.25 https://hello.apps.corp.example/ || echo "HTTPS test failed"
