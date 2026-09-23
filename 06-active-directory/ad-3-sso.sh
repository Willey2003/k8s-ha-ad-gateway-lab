#!/usr/bin/env bash
# AD PHASE 3 - Kerberos single sign-on for SSH. Run on each machine:  sudo ./ad-3-sso.sh   (undo: --undo)
# Server side: sshd accepts Kerberos (GSSAPI) logins, using the host keytab created by the domain join.
# Client side: "ssh <node>" expands short names to <node>.corp.example and offers your Kerberos ticket
# (and forwards it, so the next hop is password-free too). Password and key logins keep working.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
SRV=/etc/ssh/sshd_config.d/50-corp-gssapi.conf
CLI=/etc/ssh/ssh_config.d/50-corp-gssapi.conf
if [[ ${1:-} == --undo ]]; then rm -f "$SRV" "$CLI"; sshd -t && systemctl reload ssh; echo "$(hostname): removed"; exit 0; fi
realm list | grep -q "domain-name: corp.example" || { echo "Not joined to corp.example - run ad-2-join.sh first" >&2; exit 1; }
[[ -s /etc/krb5.keytab ]] || { echo "No /etc/krb5.keytab - join incomplete" >&2; exit 1; }
grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || { echo "sshd_config does not include sshd_config.d - aborting" >&2; exit 1; }

cat > "$SRV" <<'CONF'
# Kerberos (GSSAPI) SSH logins for corp.example accounts
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
CONF
install -d /etc/ssh/ssh_config.d
cat > "$CLI" <<'CONF'
# "ssh worker-a" -> worker-a.corp.example, then use the Kerberos ticket for corp.example hosts
CanonicalizeHostname yes
CanonicalDomains corp.example
CanonicalizeFallbackLocal yes

Host *.corp.example
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes
CONF
sshd -t
systemctl reload ssh
echo "$(hostname): GSSAPI enabled; keytab SPNs: $(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3{print $2}' | grep -c '^host/') host/ entries"
