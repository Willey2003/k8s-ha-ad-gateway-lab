#!/usr/bin/env bash
# Sync this machine's clock from the corp.example domain controllers.
# Outbound NTP to the internet is blocked, but both DCs serve NTP on UDP 123.
#   sudo ./timesync.sh
# Safe to re-run. Original config is kept as /etc/chrony/chrony.conf.orig.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

NTP_SERVERS=(10.10.5.251 10.10.5.252)   # dc01, dc02

if ! command -v chronyd >/dev/null; then
  echo "== Installing chrony (replaces systemd-timesyncd)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony >/dev/null
fi
systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true

[[ -f /etc/chrony/chrony.conf.orig ]] || cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.orig
{
  echo "# Managed by timesync.sh - time from corp.example domain controllers"
  for s in "${NTP_SERVERS[@]}"; do echo "server $s iburst"; done
  cat <<'EOF'
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
keyfile /etc/chrony/chrony.keys
# Step the clock if it is off by more than 1s during the first 3 updates, then slew
makestep 1 3
rtcsync
maxupdateskew 100.0
leapsectz right/UTC
EOF
} > /etc/chrony/chrony.conf

echo "== Before: $(date -u +%T) UTC"
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony
if chronyc waitsync 20 0.5 >/dev/null; then
  echo "== After:  $(date -u +%T) UTC - synced"
else
  echo "== WARNING: not synced yet, check 'chronyc sources'" >&2
fi
chronyc -n sources | tail -n +3
chronyc tracking | grep -E 'Reference ID|System time|Leap status'
