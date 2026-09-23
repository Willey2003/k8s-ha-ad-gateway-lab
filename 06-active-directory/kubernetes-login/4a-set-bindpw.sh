#!/usr/bin/env bash
# Replace the svc-k8s-dex bind password in Dex's config and restart Dex. Run on manager:
#   sudo ./4a-set-bindpw.sh      (asks once; saved only if AD accepts it; pasting is fine)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
cd "$(dirname "$0")"
IFS= read -r -s -p "svc-k8s-dex password (paste is fine): " P1; echo
# drop anything else that was pasted (e.g. a trailing line break), then clean the value:
# remove bracketed-paste markers, carriage returns and surrounding whitespace
while IFS= read -r -s -t 0.3 _extra; do :; done
P1=${P1//$'\e[200~'/}; P1=${P1//$'\e[201~'/}; P1=${P1//$'\r'/}
P1="${P1#"${P1%%[![:space:]]*}"}"; P1="${P1%"${P1##*[![:space:]]}"}"
[[ -n $P1 ]] || { echo "Empty password - nothing changed" >&2; exit 1; }
echo "(received ${#P1} characters)"

echo "== check the password with AD (LDAPS bind as svc-k8s-dex) before saving it"
if ! BINDPW=$P1 python3 ./ldapbind.py dc01.corp.example ./lab-ca.crt svc-k8s-dex@corp.example; then
  echo "AD rejected this password - Dex NOT changed. Check/reset svc-k8s-dex in AD and try again." >&2; exit 1
fi

echo "== update Dex config secret"
export BINDPW=$P1
kubectl -n dex get secret dex-config -o jsonpath='{.data.config\.yaml}' | base64 -d > /tmp/dexcfg.yaml
python3 - /tmp/dexcfg.yaml <<'PY'
import os, sys, yaml
p = sys.argv[1]; c = yaml.safe_load(open(p))
for con in c["connectors"]:
    if con["id"] == "ad": con["config"]["bindPW"] = os.environ["BINDPW"]
yaml.safe_dump(c, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
unset BINDPW P1
chmod 600 /tmp/dexcfg.yaml
kubectl -n dex create secret generic dex-config --from-file=config.yaml=/tmp/dexcfg.yaml --dry-run=client -o yaml | kubectl apply -f -
shred -u /tmp/dexcfg.yaml
kubectl -n dex rollout restart deploy/dex
kubectl -n dex rollout status deploy/dex --timeout=180s
echo "Now test from Bastion:  ~/k8s-deployer/ad/k8s/test-dex-login.sh lab_admin1"
