#!/usr/bin/env bash
# AD PHASE 4c - permissions for AD users. Run once on a manager:  sudo ./4c-rbac.sh
#   ad:all-users  (every AD login) -> cluster-wide read-only "view" (no Secrets) + "edit" in namespace playground
#   ad:K8s-Admins (AD group)       -> cluster-admin
# playground: quota-limited, Pod Security "baseline" enforced (no privileged/hostPath pods).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: ad-all-users-view}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: Group, name: "ad:all-users"}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: ad-k8s-admins-cluster-admin}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: Group, name: "ad:K8s-Admins"}]
---
apiVersion: v1
kind: Namespace
metadata:
  name: playground
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ad-all-users-edit, namespace: playground}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: edit}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: Group, name: "ad:all-users"}]
---
apiVersion: v1
kind: ResourceQuota
metadata: {name: playground-quota, namespace: playground}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "30"
    services: "10"
    services.nodeports: "0"
    services.loadbalancers: "0"
    persistentvolumeclaims: "5"
---
apiVersion: v1
kind: LimitRange
metadata: {name: playground-defaults, namespace: playground}
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}
    default: {cpu: 500m, memory: 512Mi}
    max: {cpu: "2", memory: 4Gi}
YAML
echo; echo "== what an AD user may do (impersonation check)"
chk() { printf '  %-44s %s\n' "$*" "$(kubectl auth can-i "$@" --as=ad:test.user --as-group=ad:all-users 2>/dev/null)"; }
chk get pods -A
chk create deployments -n playground
chk delete deployments -n default
chk get secrets -n kube-system
chk create namespaces
printf '  %-44s %s\n' "K8s-Admins: delete nodes" "$(kubectl auth can-i delete nodes --as=ad:admin --as-group=ad:K8s-Admins --as-group=ad:all-users)"
