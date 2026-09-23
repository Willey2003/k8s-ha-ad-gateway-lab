#!/usr/bin/env bash
# AD PHASE 4a - install Dex (OIDC login service backed by AD/LDAPS). Run on manager:
#   sudo ./4a-dex-install.sh          (asks for the svc-k8s-dex password; re-run safely to update)
# Needs in the same directory: dex-tls.crt dex-tls.key lab-ca.crt client-secret.txt
# Dex: https://dex.corp.example:32000 (NodePort on every node, reached via VIP 10.10.1.20)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"
for f in dex-tls.crt dex-tls.key lab-ca.crt client-secret.txt; do [[ -s $f ]] || { echo "missing $f" >&2; exit 1; }; done
export KUBECONFIG=/etc/kubernetes/admin.conf
ISSUER=https://dex.corp.example:32000
IMAGE=ghcr.io/dexidp/dex:v2.45.1
CLIENT_SECRET=$(cat client-secret.txt)
CA_B64=$(base64 -w0 lab-ca.crt)

read -r -s -p "Password for AD account svc-k8s-dex: " BINDPW; echo
[[ -n $BINDPW ]] || { echo "empty password" >&2; exit 1; }
# YAML single-quoted scalar: escape single quotes by doubling them
BINDPW_YAML=${BINDPW//\'/\'\'}

CONFIG=$(cat <<EOF
issuer: $ISSUER
storage:
  type: kubernetes
  config:
    inCluster: true
web:
  https: 0.0.0.0:5554
  tlsCert: /etc/dex/tls/tls.crt
  tlsKey: /etc/dex/tls/tls.key
telemetry:
  http: 0.0.0.0:5558
logger:
  level: info
  format: json
oauth2:
  passwordConnector: ad
  skipApprovalScreen: true
  responseTypes: ["code"]
expiry:
  idTokens: 1h
  refreshTokens:
    validIfNotUsedFor: 24h
    absoluteLifetime: 168h
enablePasswordDB: false
staticClients:
- id: kubernetes
  name: Kubernetes (LAB lab)
  secret: $CLIENT_SECRET
  redirectURIs:
  - http://localhost:8000
  - http://localhost:18000
connectors:
- type: ldap
  id: ad
  name: corp.example Active Directory
  config:
    host: corp.example:636
    rootCAData: $CA_B64
    bindDN: svc-k8s-dex@corp.example
    bindPW: '$BINDPW_YAML'
    usernamePrompt: AD username
    userSearch:
      baseDN: DC=corp,DC=example
      # enabled user accounts only
      filter: "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
      username: sAMAccountName
      idAttr: sAMAccountName
      emailAttr: userPrincipalName
      nameAttr: displayName
      preferredUsernameAttr: sAMAccountName
    groupSearch:
      baseDN: DC=corp,DC=example
      filter: "(objectClass=group)"
      userMatchers:
      - userAttr: DN
        groupAttr: member
      nameAttr: cn
EOF
)
unset BINDPW BINDPW_YAML

echo "== Namespace, RBAC, secrets"
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: dex}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: dex, namespace: dex}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: dex}
rules:
- apiGroups: ["dex.coreos.com"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["create", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: dex}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: dex}
subjects: [{kind: ServiceAccount, name: dex, namespace: dex}]
YAML
kubectl -n dex create secret tls dex-tls --cert=dex-tls.crt --key=dex-tls.key --dry-run=client -o yaml | kubectl apply -f -
printf '%s\n' "$CONFIG" | kubectl -n dex create secret generic dex-config --from-file=config.yaml=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
unset CONFIG

echo "== Deployment + NodePort service"
kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: dex, namespace: dex, labels: {app: dex}}
spec:
  replicas: 2
  selector: {matchLabels: {app: dex}}
  template:
    metadata:
      labels: {app: dex}
      annotations: {config-revision: "$(date +%s)"}
    spec:
      serviceAccountName: dex
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm: {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {app: dex}}}
      securityContext: {runAsNonRoot: true, runAsUser: 1001, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: dex
        image: $IMAGE
        args: ["dex", "serve", "/etc/dex/config/config.yaml"]
        # use config values literally (a '$' in the AD bind password must not be treated as a variable)
        env: [{name: DEX_EXPAND_ENV, value: "false"}]
        ports:
        - {name: https, containerPort: 5554}
        - {name: telemetry, containerPort: 5558}
        readinessProbe: {httpGet: {path: /healthz/ready, port: telemetry}, periodSeconds: 10}
        livenessProbe:  {httpGet: {path: /healthz/live,  port: telemetry}, periodSeconds: 20}
        resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
        volumeMounts:
        - {name: config, mountPath: /etc/dex/config, readOnly: true}
        - {name: tls, mountPath: /etc/dex/tls, readOnly: true}
        - {name: tmp, mountPath: /tmp}
      volumes:
      - {name: tmp, emptyDir: {medium: Memory, sizeLimit: 16Mi}}
      - {name: config, secret: {secretName: dex-config}}
      - {name: tls, secret: {secretName: dex-tls}}
---
apiVersion: v1
kind: Service
metadata: {name: dex, namespace: dex}
spec:
  type: NodePort
  selector: {app: dex}
  ports:
  - {name: https, port: 5554, targetPort: https, nodePort: 32000}
YAML
kubectl -n dex rollout status deploy/dex --timeout=180s
kubectl -n dex get pods -o wide

echo "== Check discovery through the VIP"
sleep 3
curl -s --max-time 10 --cacert lab-ca.crt --resolve dex.corp.example:32000:10.10.1.20 \
  "$ISSUER/.well-known/openid-configuration" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("issuer:",d["issuer"]);print("grant types:",", ".join(d.get("grant_types_supported",[])))' \
  || echo "Discovery through VIP failed - is port 32000 allowed in ufw on all managers?"
echo "== Remove key material from this directory"
shred -u dex-tls.key client-secret.txt
echo "Dex installed."
