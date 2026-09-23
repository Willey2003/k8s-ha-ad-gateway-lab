#!/usr/bin/env bash
# BACKUP STEP 3 - run on Bastion:   sudo ~/k8s-deployer/backup/3-finish-bastion.sh
# Collects the hand-off files from manager, stores them root-only in /etc/k8s-backup,
# removes them from manager, enables the weekly timer and runs the first backup now.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
OWNER=${SUDO_USER:-labops}
MANAGER=10.10.1.14
TMP=$(mktemp -d); chown "$OWNER" "$TMP"; trap 'rm -rf "$TMP"' EXIT
step() { echo; echo "== $*"; }

step "Collect hand-off files from $MANAGER"
sudo -u "$OWNER" scp -q "$OWNER@$MANAGER:backup-handoff/*" "$TMP/"
install -m 0600 -o root -g root "$TMP/velero.kubeconfig" /etc/k8s-backup/velero.kubeconfig
for f in ca.pem client.pem client-key.pem; do install -m 0600 -o root -g root "$TMP/$f" /etc/k8s-backup/pki/$f; done
ls -la /etc/k8s-backup /etc/k8s-backup/pki
sudo -u "$OWNER" ssh "$OWNER@$MANAGER" 'rm -rf ~/backup-handoff' && echo "removed hand-off copy from $MANAGER"

step "Check access"
velero --kubeconfig /etc/k8s-backup/velero.kubeconfig -n velero backup-location get
ETCDCTL_API=3 etcdctl --endpoints=https://10.10.1.12:2379,https://10.10.1.13:2379,https://10.10.1.19:2379 \
  --cacert=/etc/k8s-backup/pki/ca.pem --cert=/etc/k8s-backup/pki/client.pem --key=/etc/k8s-backup/pki/client-key.pem \
  endpoint health

step "Enable weekly timer"
systemctl enable --now k8s-weekly-backup.timer
systemctl list-timers k8s-weekly-backup.timer --no-pager

step "First backup now (a few minutes)"
systemctl start k8s-weekly-backup.service || true
journalctl -u k8s-weekly-backup.service -n 40 --no-pager -o cat
echo; cat /srv/backup/LAST_RUN
