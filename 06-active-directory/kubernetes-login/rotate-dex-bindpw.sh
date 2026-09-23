#!/usr/bin/env bash
# Rotate the svc-k8s-dex AD password and update Dex in one go - no copy/paste, and it works even
# when Dex (kubectl AD logins) is broken. Run on Bastion as an AD admin (K8s-Admins + Domain Admins):
#   /opt/k8s-lab/ad/rotate-dex-bindpw.sh
# You type YOUR OWN AD password once. It is used to (1) reset svc-k8s-dex over LDAPS and
# (2) sudo on the manager, where Dex's config is updated with the cluster's local admin config.
# The new service password is generated here, verified with AD, and never displayed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DC=dc01.corp.example
MGR=manager.corp.example
ADMIN="$(id -un)@corp.example"
export LDAPTLS_CACERT="$HERE/lab-ca.crt"
SSH=(ssh -o StrictHostKeyChecking=accept-new -o GSSAPIAuthentication=yes "$MGR")
KC="kubectl --kubeconfig /etc/kubernetes/admin.conf"

IFS= read -r -s -p "Your AD password ($ADMIN): " ADMPW; echo
[[ -n $ADMPW ]] || { echo "empty password" >&2; exit 1; }
umask 077; WORK=$(mktemp -d)
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT
printf '%s' "$ADMPW" > "$WORK/pw"
# run a command as root on the manager; sudo reads the password from the first stdin line
on_mgr() { { printf '%s\n' "$ADMPW"; cat; } | "${SSH[@]}" "sudo -k -S -p '' $*"; }

echo "== check access to $MGR (sudo + cluster admin config)"
on_mgr "$KC -n dex get deploy dex -o name" </dev/null \
  || { echo "Cannot run kubectl as root on $MGR - wrong password, or no Kerberos ticket (log in to Bastion with your password)" >&2; exit 1; }

echo "== find svc-k8s-dex in AD"
SVC_DN=$(ldapsearch -LLL -o ldif-wrap=no -x -H "ldaps://$DC" -D "$ADMIN" -y "$WORK/pw" \
          -b "DC=corp,DC=example" "(sAMAccountName=svc-k8s-dex)" dn 2>"$WORK/err" | sed -n 's/^dn: //p' | head -1) || true
[[ -n $SVC_DN ]] || { echo "Could not find svc-k8s-dex: $(grep -m1 -iE 'invalid|error' "$WORK/err")" >&2; exit 1; }
echo "found: $SVC_DN"

echo "== fetch current Dex config"
on_mgr "$KC -n dex get secret dex-config -o jsonpath='{.data.config\.yaml}'" </dev/null | base64 -d > "$WORK/config.yaml"
grep -q 'bindDN: svc-k8s-dex' "$WORK/config.yaml" || { echo "Unexpected Dex config - aborting before any change" >&2; exit 1; }

echo "== reset svc-k8s-dex in AD over LDAPS (authorised as $ADMIN)"
NEWPW=$(python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(24)))')
B64=$(printf '"%s"' "$NEWPW" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
printf 'dn: %s\nchangetype: modify\nreplace: unicodePwd\nunicodePwd:: %s\n-\n' "$SVC_DN" "$B64" \
  | ldapmodify -x -H "ldaps://$DC" -D "$ADMIN" -y "$WORK/pw" >/dev/null
unset B64
echo "password reset in AD"
BINDPW=$NEWPW python3 "$HERE/ldapbind.py" "$DC" "$HERE/lab-ca.crt" svc-k8s-dex@corp.example

echo "== write it into Dex (via $MGR) and restart Dex"
BINDPW=$NEWPW python3 - "$WORK/config.yaml" <<'PY'
import os, sys, yaml
p = sys.argv[1]; c = yaml.safe_load(open(p))
for con in c["connectors"]:
    if con["id"] == "ad": con["config"]["bindPW"] = os.environ["BINDPW"]
yaml.safe_dump(c, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
unset NEWPW
python3 - "$WORK/config.yaml" > "$WORK/secret.yaml" <<'PY'
import base64, sys, yaml
data = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
print(yaml.safe_dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                      "metadata": {"name": "dex-config", "namespace": "dex"},
                      "data": {"config.yaml": data}}))
PY
on_mgr "$KC apply -f -" < "$WORK/secret.yaml"
on_mgr "$KC -n dex rollout restart deploy/dex" </dev/null
on_mgr "$KC -n dex rollout status deploy/dex --timeout=180s" </dev/null
unset ADMPW
echo "Done - svc-k8s-dex has a new password that only AD and Dex know."
