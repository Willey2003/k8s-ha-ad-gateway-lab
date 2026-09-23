#!/usr/bin/env bash
# AD PHASE 1 - DNS. Run on each machine:   sudo ./ad-1-dns.sh          (undo: sudo ./ad-1-dns.sh --undo)
# Adds the corp.example domain controllers to systemd-resolved as global DNS servers with
# search domain corp.example. Queries for *.corp.example go ONLY to the DCs; all other
# queries can use the DCs or the existing public servers, so internet names keep working
# even if both DCs are down. One drop-in file; nothing else is edited.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
F=/etc/systemd/resolved.conf.d/corp.conf
if [[ ${1:-} == --undo ]]; then
  rm -f "$F"; systemctl restart systemd-resolved; echo "$(hostname): removed $F"; exit 0
fi
install -d -m 0755 /etc/systemd/resolved.conf.d
cat > "$F" <<'CONF'
# corp.example Active Directory DNS (dc01 / dc02)
[Resolve]
DNS=10.10.5.251 10.10.5.252
Domains=corp.example
CONF
systemctl restart systemd-resolved
sleep 1
r() { resolvectl query "$1" 2>/dev/null | head -1 | awk '{print $2}'; }
printf '%-10s k8s-api=%s  manager-2=%s  short(worker-a)=%s  _ldap SRV=%s  internet(pkgs.k8s.io)=%s\n' \
  "$(hostname)" "$(r k8s-api.corp.example)" "$(r manager-2.corp.example)" "$(getent hosts worker-a | awk '{print $1}')" \
  "$(resolvectl query -t SRV _ldap._tcp.corp.example 2>/dev/null | grep -c dc0)" "$(r pkgs.k8s.io)"
