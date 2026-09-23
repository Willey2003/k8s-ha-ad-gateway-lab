#!/usr/bin/env bash
# BACKUP STEP 2 - run on manager (10.10.1.14):   sudo ./2-install-velero.sh
# Expects ~/velero and ~/credentials-velero (copied from Bastion).
# - installs Velero (with node-agent for volume data) using the cluster admin config
# - creates a limited "backup-runner" account that may only manage Velero objects
# - puts a kubeconfig for it plus the etcd client certs in ~/backup-handoff for Bastion
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

OWNER=${SUDO_USER:-labops}
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
VELERO=$HOME_DIR/velero
CRED=$HOME_DIR/credentials-velero
HANDOFF=$HOME_DIR/backup-handoff
S3_URL=http://10.10.1.11:7070
VIP=10.10.1.20
export KUBECONFIG=/etc/kubernetes/admin.conf
step() { echo; echo "== $*"; }

[[ -x $VELERO && -f $CRED ]] || { echo "Need $VELERO and $CRED" >&2; exit 1; }
curl -s -o /dev/null --max-time 5 "$S3_URL" || { echo "S3 store $S3_URL not reachable from here - run step 1 on Bastion first" >&2; exit 1; }

step "Install Velero v1.18.3"
if kubectl get deploy velero -n velero >/dev/null 2>&1; then
  echo "Velero already installed - skipping install"
else
  "$VELERO" install \
    --provider aws \
    --image docker.io/velero/velero:v1.18.3 \
    --plugins docker.io/velero/velero-plugin-for-aws:v1.14.3 \
    --bucket velero \
    --secret-file "$CRED" \
    --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=$S3_URL \
    --use-volume-snapshots=false \
    --use-node-agent \
    --default-volumes-to-fs-backup \
    --wait
fi
kubectl -n velero rollout status deploy/velero --timeout=300s
kubectl -n velero rollout status ds/node-agent --timeout=300s

step "Wait for backup storage location to become Available"
for _ in $(seq 1 30); do
  phase=$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ $phase == Available ]] && break; sleep 5
done
echo "BackupStorageLocation: ${phase:-unknown}"
[[ $phase == Available ]] || { echo "BSL not Available - check: kubectl -n velero logs deploy/velero" >&2; exit 1; }

step "Limited account 'backup-runner' (Velero objects in namespace velero only)"
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: {name: backup-runner, namespace: velero}
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: backup-runner-token
  namespace: velero
  annotations: {kubernetes.io/service-account.name: backup-runner}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: backup-runner, namespace: velero}
rules:
- apiGroups: ["velero.io"]
  resources: ["*"]
  verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: backup-runner, namespace: velero}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: backup-runner}
subjects: [{kind: ServiceAccount, name: backup-runner, namespace: velero}]
YAML
for _ in $(seq 1 20); do
  TOKEN=$(kubectl -n velero get secret backup-runner-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  [[ -n $TOKEN ]] && break; sleep 1
done
[[ -n ${TOKEN:-} ]] || { echo "token not generated" >&2; exit 1; }
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

step "Hand-off files for Bastion ($HANDOFF)"
rm -rf "$HANDOFF"; install -d -m 0700 -o "$OWNER" "$HANDOFF"
umask 077
cat > "$HANDOFF/velero.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: kubernetes
  cluster: {server: https://$VIP:6443, certificate-authority-data: $CA}
users:
- name: backup-runner
  user: {token: $TOKEN}
contexts:
- name: backup-runner
  context: {cluster: kubernetes, user: backup-runner, namespace: velero}
current-context: backup-runner
EOF
cp /etc/kubernetes/pki/etcd/ca.pem /etc/kubernetes/pki/etcd/client.pem /etc/kubernetes/pki/etcd/client-key.pem "$HANDOFF/"
chown -R "$OWNER": "$HANDOFF"; chmod 0600 "$HANDOFF"/*
ls -la "$HANDOFF"

step "Remove S3 credentials copy from this node"
shred -u "$CRED" 2>/dev/null || rm -f "$CRED"

echo; echo "Step 2 done. Next: step 3 on Bastion (collect hand-off files, enable weekly timer, first backup)."
