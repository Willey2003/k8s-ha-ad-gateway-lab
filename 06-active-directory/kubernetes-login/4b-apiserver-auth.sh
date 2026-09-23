#!/usr/bin/env bash
# AD PHASE 4b - make this manager's kube-apiserver trust Dex (AD logins). Run on ONE manager at a time:
#   sudo ./4b-apiserver-auth.sh            (undo: sudo ./4b-apiserver-auth.sh --undo)
# Adds --authentication-config (structured JWT authn, apiserver.config.k8s.io/v1beta1):
#   user   = "ad:" + sAMAccountName
#   groups = "ad:" + each AD group, plus "ad:all-users" for every AD login
# Certificates/ServiceAccount/other logins keep working. If the API server is not healthy
# within 3 minutes, the previous manifest is restored automatically.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"
MAN=/etc/kubernetes/manifests/kube-apiserver.yaml
AUTH_DIR=/etc/kubernetes/auth
AUTH=$AUTH_DIR/authentication-config.yaml
BK=/root/kube-apiserver.yaml.pre-oidc-$(date +%Y%m%d-%H%M%S)
IP=$(grep -o -- '--advertise-address=[0-9.]*' "$MAN" | cut -d= -f2)
export KUBECONFIG=/etc/kubernetes/admin.conf
healthy() { curl -s --max-time 3 --cacert /etc/kubernetes/pki/ca.crt "https://$IP:6443/readyz" | grep -qx ok; }
cid() { crictl ps --name '^kube-apiserver$' -q 2>/dev/null | head -1; }
# wait until kubelet has replaced the container ($1 = old container id), then require 30s of continuous health
wait_new_healthy() {
  local old=$1 new="" ok=0
  for _ in $(seq 1 60); do new=$(cid); [[ -n $new && $new != "$old" ]] && break; sleep 2; done
  [[ -n $new && $new != "$old" ]] || { echo "kube-apiserver container was not replaced within 120s" >&2; return 1; }
  echo "new kube-apiserver container ${new:0:13} started"
  for _ in $(seq 1 90); do
    if healthy && [[ $(cid) == "$new" ]]; then ok=$((ok+1)); [[ $ok -ge 6 ]] && return 0; else ok=0; fi
    [[ $(cid) != "$new" ]] && { echo "container restarted again (crashing)" >&2; return 1; }
    sleep 5
  done
  return 1
}
wait_healthy() { for _ in $(seq 1 90); do healthy && return 0; sleep 2; done; return 1; }

if [[ ${1:-} == --undo ]]; then
  cp -a "$MAN" "$BK"
  python3 - "$MAN" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); spec = d["spec"]; c = spec["containers"][0]
c["command"] = [a for a in c["command"] if not a.startswith("--authentication-config=")]
c["volumeMounts"] = [v for v in c.get("volumeMounts", []) if v["name"] != "k8s-auth"]
spec["volumes"] = [v for v in spec.get("volumes", []) if v["name"] != "k8s-auth"]
yaml.safe_dump(d, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
  echo "removed --authentication-config; waiting for API server..."; sleep 10; wait_healthy && echo OK; exit 0
fi

[[ -s lab-ca.crt ]] || { echo "missing lab-ca.crt" >&2; exit 1; }
healthy || { echo "API server on $IP is not healthy before the change - aborting" >&2; exit 1; }

echo "== $(hostname): write $AUTH"
install -d -m 0755 "$AUTH_DIR"
{
cat <<'EOF'
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration
jwt:
- issuer:
    url: https://dex.corp.example:32000
    audiences:
    - kubernetes
    certificateAuthority: |
EOF
sed 's/^/      /' lab-ca.crt
cat <<'EOF'
  claimMappings:
    username:
      expression: "'ad:' + claims.preferred_username"
    groups:
      expression: "(has(claims.groups) ? dyn(claims.groups).map(g, 'ad:' + string(g)) : []) + ['ad:all-users']"
    uid:
      claim: sub
  claimValidationRules:
  - expression: "has(claims.preferred_username) && claims.preferred_username != ''"
    message: "token has no preferred_username (request the 'profile' scope)"
EOF
} > "$AUTH"
chmod 0644 "$AUTH"

echo "== back up manifest to $BK (outside the manifests dir)"
cp -a "$MAN" "$BK"

OLD_CID=$(cid)
echo "== patch kube-apiserver manifest (current container ${OLD_CID:0:13})"
python3 - "$MAN" "$AUTH" "$AUTH_DIR" <<'PY'
import sys, yaml
p, auth, auth_dir = sys.argv[1:4]
d = yaml.safe_load(open(p)); spec = d["spec"]; c = spec["containers"][0]
flag = f"--authentication-config={auth}"
c["command"] = [a for a in c["command"] if not a.startswith("--authentication-config=")] + [flag]
if any(a.startswith("--oidc-") for a in c["command"]):
    sys.exit("existing --oidc-* flags found; they cannot be combined with --authentication-config")
c.setdefault("volumeMounts", [])
if not any(v["name"] == "k8s-auth" for v in c["volumeMounts"]):
    c["volumeMounts"].append({"name": "k8s-auth", "mountPath": auth_dir, "readOnly": True})
spec.setdefault("volumes", [])
if not any(v["name"] == "k8s-auth" for v in spec["volumes"]):
    spec["volumes"].append({"name": "k8s-auth", "hostPath": {"path": auth_dir, "type": "DirectoryOrCreate"}})
yaml.safe_dump(d, open(p, "w"), default_flow_style=False, sort_keys=False)
PY

echo "== waiting for kube-apiserver to restart (kubelet picks up the change)..."
if wait_new_healthy "$OLD_CID"; then
  echo "API server on $IP healthy with AD authentication enabled"
else
  echo "API server NOT healthy - restoring previous manifest" >&2
  cp -a "$BK" "$MAN"; sleep 20; wait_healthy && echo "restored and healthy" >&2
  crictl logs --tail 15 "$(crictl ps -a --name '^kube-apiserver$' -q | sed -n 2p)" 2>&1 | grep -iE 'error|invalid|failed' | head -5 >&2
  exit 1
fi

echo "== record the setting in kubeadm-config (so kubeadm upgrades keep it)"
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cc.yaml
python3 - /tmp/cc.yaml "$AUTH" "$AUTH_DIR" <<'PY'
import sys, yaml
p, auth, auth_dir = sys.argv[1:4]
cc = yaml.safe_load(open(p)); api = cc.setdefault("apiServer", {})
args = [a for a in api.get("extraArgs", []) if a.get("name") != "authentication-config"]
args.append({"name": "authentication-config", "value": auth}); api["extraArgs"] = args
vols = [v for v in api.get("extraVolumes", []) if v.get("name") != "k8s-auth"]
vols.append({"name": "k8s-auth", "hostPath": auth_dir, "mountPath": auth_dir, "readOnly": True, "pathType": "DirectoryOrCreate"})
api["extraVolumes"] = vols
yaml.safe_dump(cc, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
kubectl -n kube-system create cm kubeadm-config --from-file=ClusterConfiguration=/tmp/cc.yaml --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null && echo "kubeadm-config updated"
rm -f /tmp/cc.yaml
kubectl get --raw /readyz >/dev/null && echo "Done on $(hostname). Backup: $BK"
