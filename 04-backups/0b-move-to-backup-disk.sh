#!/usr/bin/env bash
# One-time fix: step 0 left an empty partition /dev/sdb1 (no filesystem) and step 1 then put
# /srv/backup on the root disk. This formats /dev/sdb1, moves /srv/backup onto it (keeping
# ownership and extended attributes, which versitygw uses), and restarts versitygw.
#   sudo ~/k8s-deployer/backup/0b-move-to-backup-disk.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
PART=/dev/sdb1
MNT=/srv/backup
TMP=/mnt/k8s-backup-new
OLD=/srv/backup.rootdisk-old
LABEL=k8s-backup

[[ -b $PART ]] || { echo "$PART not found" >&2; exit 1; }
[[ -z $(blkid -o value -s TYPE "$PART" 2>/dev/null) ]] || { echo "$PART already has a filesystem - refusing" >&2; exit 1; }
findmnt -rno TARGET "$MNT" >/dev/null && { echo "$MNT is already a mount point - nothing to do" >&2; exit 1; }
[[ $(lsblk -no MOUNTPOINT "$PART" | tr -d ' \n') == "" ]] || { echo "$PART is mounted - refusing" >&2; exit 1; }

echo "== Format $PART ($(lsblk -dno SIZE "$PART")) as ext4"
mkfs.ext4 -q -L "$LABEL" "$PART"
UUID=$(blkid -o value -s UUID "$PART")

echo "== Stop versitygw and copy $MNT onto the new disk"
systemctl stop versitygw
install -d "$TMP"; mount "$PART" "$TMP"
cp -a --preserve=all "$MNT"/. "$TMP"/
umount "$TMP"; rmdir "$TMP"

echo "== Switch $MNT to the new disk"
mv "$MNT" "$OLD"
install -d -m 0755 "$MNT"
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MNT ext4 defaults,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount "$MNT"
chmod 0755 "$MNT"

echo "== Start versitygw and check the bucket"
systemctl start versitygw; sleep 2
set -a; . /etc/versitygw/vgw.env; set +a
if s3req GET "http://127.0.0.1:7070/velero?list-type=2&max-keys=1" | head -1 | grep -qx 200; then
  echo "bucket 'velero' OK on new disk"
  rm -rf "$OLD"
else
  echo "Bucket check FAILED - old data kept in $OLD" >&2; exit 1
fi

echo; df -h "$MNT"; ls -la "$MNT"; grep "$MNT" /etc/fstab
echo "versitygw: $(systemctl is-active versitygw)"
echo "ufw: $(ufw status | head -1)"; ufw status | grep 7070 || true
echo "Done. Backups now go to $PART."
