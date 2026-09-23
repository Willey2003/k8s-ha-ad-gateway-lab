#!/usr/bin/env bash
# Run ONCE on the control-plane node (10.10.1.14):
#   sudo ./create-deployer.sh [namespace ...]      (default namespace: default)
# Creates a non-admin "deployer" ServiceAccount, grants it deploy rights in the
# given namespaces, and writes ~/deployer.kubeconfig owned by the invoking user.
set -euo pipefail

ADMIN_CONF=/etc/kubernetes/admin.conf
SA=deployer
SA_NS=kube-system
NAMESPACES=("${@:-default}")
OWNER=${SUDO_USER:-$USER}
OUT=$(getent passwd "$OWNER" | cut -d: -f6)/deployer.kubeconfig
k() { kubectl --kubeconfig "$ADMIN_CONF" "$@"; }

[[ -r $ADMIN_CONF ]] || { echo "Cannot read $ADMIN_CONF - run with sudo on the control-plane node" >&2; exit 1; }

k apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: $SA, namespace: $SA_NS}
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: $SA-token
  namespace: $SA_NS
  annotations: {kubernetes.io/service-account.name: $SA}
---
# Namespaced deploy permissions (bound per namespace below)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: $SA}
rules:
- apiGroups: ["", "apps", "batch", "autoscaling", "networking.k8s.io", "policy"]
  resources: [deployments, statefulsets, daemonsets, replicasets, jobs, cronjobs,
              services, configmaps, secrets, persistentvolumeclaims, serviceaccounts,
              ingresses, networkpolicies, horizontalpodautoscalers, poddisruptionbudgets,
              pods, endpoints, events]
  verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [""]
  resources: [pods/log, pods/exec, pods/portforward]
  verbs: [get, create]
- apiGroups: ["apps"]
  resources: [deployments/scale, statefulsets/scale]
  verbs: [get, update, patch]
---
# Read-only cluster-level info (kubectl get nodes / namespaces)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: $SA-cluster-read}
rules:
- apiGroups: [""]
  resources: [nodes, namespaces]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: $SA-cluster-read}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: $SA-cluster-read}
subjects: [{kind: ServiceAccount, name: $SA, namespace: $SA_NS}]
---
# Read-only view of all namespaces (kubectl get pods -A); built-in "view" excludes secrets
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: $SA-view}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects: [{kind: ServiceAccount, name: $SA, namespace: $SA_NS}]
YAML

for ns in "${NAMESPACES[@]}"; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f -
  k create rolebinding "$SA" -n "$ns" --clusterrole="$SA" \
    --serviceaccount="$SA_NS:$SA" --dry-run=client -o yaml | k apply -f -
done

# Wait for the token controller to populate the secret
for _ in $(seq 1 20); do
  TOKEN=$(k get secret "$SA-token" -n "$SA_NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  [[ -n $TOKEN ]] && break; sleep 1
done
[[ -n ${TOKEN:-} ]] || { echo "Token was not generated" >&2; exit 1; }

SERVER=$(k config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(k config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
CLUSTER=$(k config view --raw -o jsonpath='{.clusters[0].name}')

umask 077
cat > "$OUT" <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER
  cluster: {server: $SERVER, certificate-authority-data: $CA}
users:
- name: $SA
  user: {token: $TOKEN}
contexts:
- name: $SA@$CLUSTER
  context: {cluster: $CLUSTER, user: $SA, namespace: ${NAMESPACES[0]}}
current-context: $SA@$CLUSTER
KCFG
chown "$OWNER": "$OUT"
echo "Wrote $OUT (namespaces: ${NAMESPACES[*]})"
