#!/usr/bin/env bash
# AD PHASE 5 - fix Kerberos SSH single sign-on ("Server not found in Kerberos database").
# The machines were joined with a short FQDN (hostname -f = "manager"), so AD only knows
# host/MANAGER, while SSH asks for host/manager.corp.example. This:
#   1. maps 127.0.1.1 to "<name>.corp.example <name>" in /etc/hosts (hostname itself is NOT changed,
#      so Kubernetes node names stay the same)
#   2. runs "adcli update" with the full name: sets dNSHostName and adds host/<name>.corp.example
#      service principals in AD and in /etc/krb5.keytab (uses the machine's own account, no password)
# Run on each machine:   sudo ./ad-5-fqdn-spn.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
realm list | grep -q "domain-name: corp.example" || { echo "not joined to corp.example" >&2; exit 1; }
SHORT=$(hostname -s)
FQDN="$(echo "$SHORT" | tr 'A-Z' 'a-z').corp.example"

cp -a /etc/hosts /etc/hosts.pre-fqdn 2>/dev/null || true
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$FQDN $SHORT/" /etc/hosts
else
  printf '127.0.1.1\t%s %s\n' "$FQDN" "$SHORT" >> /etc/hosts
fi
echo "$SHORT: hostname -f = $(hostname -f)"

echo "== adcli update (machine account adds its own full-name principals)"
set +e
adcli update --verbose --domain=corp.example --host-fqdn="$FQDN" \
  --add-service-principal="host/$FQDN" --add-service-principal="RestrictedKrbHost/$FQDN" 2>&1 \
  | grep -E '^ ! |error|Error|denied|Insufficient|Updated|Added|service|principal' | tail -8
RC=${PIPESTATUS[0]}
set -e
systemctl restart sssd
N=$(klist -k /etc/krb5.keytab 2>/dev/null | grep -ci "host/$FQDN@" || true)
echo "$SHORT: adcli exit=$RC, keytab entries for host/$FQDN: $N"
[[ $N -ge 1 ]] || { echo "NOT FIXED on $SHORT - see adcli lines above" >&2; exit 1; }
echo "$SHORT: OK"
