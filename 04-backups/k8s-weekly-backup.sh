#!/usr/bin/env bash
# Weekly cluster backup, run by k8s-weekly-backup.timer on Bastion (as root).
#   1. etcd snapshot (the complete cluster state) -> /srv/backup/etcd, keep last 8
#   2. Velero backup of all namespaces except velero itself + volume data -> S3 bucket "velero" on this host, kept 8 weeks
#   3. warns when the etcd client certificate is close to expiry or backup disk is filling up
# Manual run:  sudo systemctl start k8s-weekly-backup.service ; journalctl -u k8s-weekly-backup -n 50
set -uo pipefail
TS=$(date +%Y%m%d-%H%M)
PKI=/etc/k8s-backup/pki
KCFG=/etc/k8s-backup/velero.kubeconfig
ETCD_DIR=/srv/backup/etcd
ENDPOINTS=(https://10.10.1.12:2379 https://10.10.1.13:2379 https://10.10.1.19:2379)
KEEP=8
TTL=1344h        # 8 weeks
STATUS=/srv/backup/LAST_RUN
RC=0
log()  { echo "$(date '+%F %T') $*"; }
fail() { log "ERROR: $*"; RC=1; }

log "=== weekly backup $TS start"

# 1. etcd snapshot (from the first member that answers)
SNAP="$ETCD_DIR/etcd-$TS.db"
ok=0
for ep in "${ENDPOINTS[@]}"; do
  if ETCDCTL_API=3 etcdctl --endpoints="$ep" --cacert="$PKI/ca.pem" --cert="$PKI/client.pem" \
       --key="$PKI/client-key.pem" --command-timeout=120s snapshot save "$SNAP.part" >/dev/null 2>&1; then
    mv "$SNAP.part" "$SNAP"; ok=1; log "etcd snapshot taken from $ep"; break
  fi
  rm -f "$SNAP.part"; log "etcd snapshot from $ep failed, trying next"
done
if [[ $ok == 1 ]]; then
  etcdutl snapshot status "$SNAP" -w table 2>/dev/null | sed 's/^/    /'
  gzip -f "$SNAP" && log "saved $SNAP.gz ($(du -h "$SNAP.gz" | cut -f1))"
  ls -1t "$ETCD_DIR"/etcd-*.db.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  log "etcd snapshots kept: $(ls -1 "$ETCD_DIR"/etcd-*.db.gz | wc -l)"
else
  fail "etcd snapshot failed on all members"
fi

# 2. Velero backup (all namespaces, cluster resources, pod volume data)
NAME=weekly-$TS
if velero --kubeconfig "$KCFG" -n velero backup create "$NAME" --exclude-namespaces velero --ttl "$TTL" --wait >/dev/null 2>&1; then
  PHASE=$(velero --kubeconfig "$KCFG" -n velero backup get "$NAME" -o json 2>/dev/null \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"].get("phase","?"))' 2>/dev/null)
else
  PHASE=CreateFailed
fi
case $PHASE in
  Completed) log "velero backup $NAME: Completed" ;;
  *)         fail "velero backup $NAME: $PHASE (details: velero --kubeconfig $KCFG -n velero backup describe $NAME --details)" ;;
esac

# 3. Health warnings
END=$(openssl x509 -in "$PKI/client.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
if [[ -n $END ]]; then
  DAYS=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))
  if (( DAYS < 60 )); then fail "etcd client certificate expires in $DAYS days ($END) - RENEW IT"
  else log "etcd client certificate valid for $DAYS more days"; fi
fi
USE=$(df --output=pcent /srv/backup | tail -1 | tr -dc 0-9)
(( USE >= 85 )) && fail "backup disk /srv/backup is ${USE}% full" || log "backup disk /srv/backup ${USE}% used"

RESULT=$([[ $RC == 0 ]] && echo OK || echo FAILED)
echo "$(date '+%F %T') $RESULT etcd=$([[ $ok == 1 ]] && echo ok || echo failed) velero=$PHASE" > "$STATUS"
log "=== weekly backup $TS finished: $RESULT"
exit $RC
