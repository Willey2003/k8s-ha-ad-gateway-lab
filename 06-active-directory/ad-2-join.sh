#!/usr/bin/env bash
# AD PHASE 2 - join this machine to corp.example (realmd + SSSD). Run on each machine:
#   sudo ./ad-2-join.sh            (asks for the lab_admin1 AD password once)
#   sudo ./ad-2-join.sh --undo     (leave the domain, remove the sudo rule)
# Result: members of the AD group K8s-Admins can SSH in with their AD username/password
# (short names, e.g. "lab_admin1"), get a home directory automatically, and may use sudo.
# Local accounts (like "labops") are NOT affected and keep working as a break-glass login.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
DOMAIN=corp.example
REALM=CORP.EXAMPLE
JOIN_USER=${JOIN_USER:-lab_admin1}
ADMIN_GROUP=k8s-admins            # AD group "K8s-Admins" (SSSD lower-cases names)
SSSD_CONF=/etc/sssd/sssd.conf
SUDOERS=/etc/sudoers.d/k8s-admins
step() { echo; echo "== $(hostname): $*"; }

if [[ ${1:-} == --undo ]]; then
  realm leave "$DOMAIN" 2>/dev/null || true
  rm -f "$SUDOERS"
  echo "$(hostname): left $DOMAIN, removed $SUDOERS (local accounts unchanged)"; exit 0
fi

step "Packages (realmd, sssd, adcli, krb5)"
export DEBIAN_FRONTEND=noninteractive
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
apt-get update -qq
apt-get install -y -qq realmd sssd sssd-tools libnss-sss libpam-sss adcli krb5-user >/dev/null
echo "installed"

step "Pre-checks"
getent hosts dc01.corp.example >/dev/null || { echo "Cannot resolve the DCs - run ad-1-dns.sh first" >&2; exit 1; }
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || echo "WARNING: clock not NTP-synced (Kerberos needs < 5 min skew)"
realm discover "$DOMAIN" | grep -E 'domain-name|configured|server-software' | sed 's/^/  /'

step "Join $DOMAIN"
if realm list | grep -q "domain-name: $DOMAIN"; then
  echo "already joined - skipping join"
else
  echo ">>> Enter the AD password for $JOIN_USER when asked <<<"
  realm join --user="$JOIN_USER" --membership-software=adcli "$DOMAIN"
fi

step "Configure SSSD (short names, /home/<user>, only $ADMIN_GROUP may log in)"
python3 - "$SSSD_CONF" "$DOMAIN" "$ADMIN_GROUP" <<'PY'
import configparser, sys
path, domain, group = sys.argv[1:4]
c = configparser.RawConfigParser(); c.optionxform = str; c.read(path)
s = f"domain/{domain}"
c.set(s, "use_fully_qualified_names", "False")
c.set(s, "fallback_homedir", "/home/%u")
c.set(s, "access_provider", "simple")
c.set(s, "simple_allow_groups", group)
c.set(s, "ad_gpo_access_control", "permissive")
c.set(s, "cache_credentials", "True")
with open(path, "w") as f: c.write(f)
PY
chmod 0600 "$SSSD_CONF"

step "Home directories and sudo"
pam-auth-update --enable mkhomedir
printf '# AD group K8s-Admins (corp.example) - full sudo, password required\n%%%s ALL=(ALL:ALL) ALL\n' "$ADMIN_GROUP" > "$SUDOERS"
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS"

step "Restart SSSD and verify"
systemctl restart sssd
sss_cache -E 2>/dev/null || true
sleep 2
realm list | grep -E 'domain-name|login-policy|permitted' | sed 's/^/  /' || true
echo "  AD user lookup : $(id "$JOIN_USER" 2>&1 | cut -c1-150)"
echo "  AD group lookup: $(getent group "$ADMIN_GROUP" || echo "not found yet - create K8s-Admins in AD and add members")"
echo "  local labops still present: $(id -un labops 2>/dev/null && echo yes || echo n/a)"
