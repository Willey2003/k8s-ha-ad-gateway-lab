#!/usr/bin/env bash
# BACKUP STEP 0 (optional, recommended) - run on Bastion AFTER adding a new virtual disk in vCenter:
#   sudo ~/k8s-deployer/backup/0-add-backup-disk.sh            # shows candidate disks, changes nothing
#   sudo ~/k8s-deployer/backup/0-add-backup-disk.sh /dev/sdb   # formats that disk and mounts it at /srv/backup
# Refuses any disk that has partitions, a filesystem, or is mounted.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
MNT=/srv/backup
LABEL=k8s-backup

# Pick up a disk added while the VM is running
for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h" 2>/dev/null || true; done
sleep 2

if [[ $# -eq 0 ]]; then
  echo "Disks without partitions or filesystem (candidates):"
  lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}' | while read -r d s; do
    [[ -z $(lsblk -no FSTYPE,MOUNTPOINT "$d" | tr -d ' \n') && $(lsblk -no NAME "$d" | wc -l) -eq 1 ]] && echo "  $d  $s"
  done
  echo; echo "Re-run with the disk path, e.g.: sudo $0 /dev/sdb"
  exit 0
fi

DISK=$1
[[ -b $DISK ]] || { echo "$DISK is not a block device" >&2; exit 1; }
[[ $(lsblk -dno TYPE "$DISK") == disk ]] || { echo "$DISK is not a whole disk" >&2; exit 1; }
[[ $(lsblk -no NAME "$DISK" | wc -l) -eq 1 ]] || { echo "$DISK has partitions - refusing" >&2; exit 1; }
[[ -z $(blkid -o value -s TYPE "$DISK" 2>/dev/null) ]] || { echo "$DISK already has a filesystem - refusing" >&2; exit 1; }
findmnt -rno TARGET "$MNT" >/dev/null && { echo "$MNT is already a mount point - refusing" >&2; exit 1; }
if [[ -d $MNT && -n $(ls -A "$MNT" 2>/dev/null) ]]; then
  echo "$MNT already has data (step 1 was run before the disk). Stop versitygw, move data off, then retry." >&2; exit 1
fi

echo "About to FORMAT $DISK ($(lsblk -dno SIZE "$DISK")) as ext4 and mount it at $MNT."
read -r -p "Type YES to continue: " ok; [[ $ok == YES ]] || { echo "Aborted"; exit 1; }

parted -s "$DISK" mklabel gpt mkpart primary ext4 0% 100%
sleep 2
PART=$(lsblk -lpno NAME,TYPE "$DISK" | awk '$2=="part"{print $1; exit}')
mkfs.ext4 -q -L "$LABEL" "$PART"
UUID=$(blkid -o value -s UUID "$PART")
install -d -m 0755 "$MNT"
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MNT ext4 defaults,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount "$MNT"
df -h "$MNT"
echo "Done. Backups will be stored on $DISK."
