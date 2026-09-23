#!/usr/bin/env bash
# BACKUP STEP 1 - run on Bastion:   sudo ~/k8s-deployer/backup/1-setup-bastion.sh
# - installs velero, etcdctl/etcdutl and versitygw (S3-compatible store) into /usr/local/bin
# - runs versitygw as a service on 10.10.1.11:7070, storing data in /srv/backup/s3
# - creates the "velero" bucket and the credentials file Velero needs
# - installs the weekly backup job (timer is enabled later, in step 3)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/../bin
OWNER=${SUDO_USER:-labops}
LISTEN_IP=10.10.1.11
PORT=7070
LAN=10.10.1.0/24
S3_DIR=/srv/backup/s3
ENV_FILE=/etc/versitygw/vgw.env
step() { echo; echo "== $*"; }

step "Install binaries"
for b in velero etcdctl etcdutl versitygw; do install -m 0755 "$BIN/$b" /usr/local/bin/$b; done
install -m 0755 "$HERE/s3req.py" /usr/local/bin/s3req
velero version --client-only | grep Version; etcdctl version | head -1; versitygw --version | head -1

step "Directories and service account"
id vgw >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin vgw
install -d -m 0755 /srv/backup
install -d -m 0700 -o vgw -g vgw "$S3_DIR"
install -d -m 0700 /srv/backup/etcd /etc/k8s-backup /etc/k8s-backup/pki

step "S3 credentials ($ENV_FILE)"
install -d -m 0750 -g vgw /etc/versitygw
if [[ ! -f $ENV_FILE ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOF
ROOT_ACCESS_KEY_ID=velero-$(tr -dc a-z0-9 </dev/urandom | head -c 8)
ROOT_SECRET_ACCESS_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40)
EOF
  echo "generated new credentials"
else
  echo "keeping existing credentials"
fi
chown root:vgw "$ENV_FILE"; chmod 0640 "$ENV_FILE"

step "versitygw service"
cat > /etc/systemd/system/versitygw.service <<EOF
[Unit]
Description=versitygw S3 gateway for Velero backups ($S3_DIR)
After=network-online.target
Wants=network-online.target

[Service]
User=vgw
Group=vgw
EnvironmentFile=$ENV_FILE
ExecStart=/usr/local/bin/versitygw --port $LISTEN_IP:$PORT --port 127.0.0.1:$PORT posix $S3_DIR
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$S3_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now versitygw
sleep 2
systemctl is-active versitygw

step "Firewall: allow $PORT/tcp from $LAN"
if systemctl is-active -q ufw; then
  ufw allow from $LAN to any port $PORT proto tcp comment 'velero S3 (versitygw)' >/dev/null
  ufw status | grep -E "$PORT" || true
fi

step "Create bucket 'velero'"
set -a; . "$ENV_FILE"; set +a
s3req GET "http://127.0.0.1:$PORT/velero?list-type=2&max-keys=1" >/dev/null 2>&1 \
  && echo "bucket already exists" \
  || { s3req PUT "http://127.0.0.1:$PORT/velero" | head -1; }

step "Velero credentials file for the cluster install"
CRED=$HERE/credentials-velero
umask 077
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$ROOT_ACCESS_KEY_ID" "$ROOT_SECRET_ACCESS_KEY" > "$CRED"
chown "$OWNER": "$CRED"; chmod 0600 "$CRED"
echo "$CRED (copied to manager in step 2, deleted there afterwards)"

step "Weekly backup job (timer enabled in step 3)"
install -m 0755 "$HERE/k8s-weekly-backup.sh" /usr/local/sbin/k8s-weekly-backup.sh
install -m 0644 "$HERE/k8s-weekly-backup.service" /etc/systemd/system/k8s-weekly-backup.service
install -m 0644 "$HERE/k8s-weekly-backup.timer"   /etc/systemd/system/k8s-weekly-backup.timer
systemctl daemon-reload
echo "installed /usr/local/sbin/k8s-weekly-backup.sh + systemd service/timer"

echo; echo "Step 1 done. Next: step 2 on manager (install Velero into the cluster)."
