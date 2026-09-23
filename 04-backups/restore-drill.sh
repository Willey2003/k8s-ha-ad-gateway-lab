#!/usr/bin/env bash
# Velero restore drill - proves backups can actually be restored, including volume data.
#   sudo ~/k8s-deployer/backup/restore-drill.sh
# In namespace "default" it creates throw-away objects labelled drill=velero (a ConfigMap,
# a Secret and a Pod that writes a random proof string into a volume), backs them up,
# DELETES them, restores them from the backup and compares everything.
# Only objects labelled drill=velero are touched; nfs-test and everything else is left alone.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
OWNER=${SUDO_USER:-labops}
KUBE="kubectl --kubeconfig /home/$OWNER/.kube/config -n default"
VEL="velero --kubeconfig /etc/k8s-backup/velero.kubeconfig -n velero"
TS=$(date +%Y%m%d-%H%M%S)
NAME=drill-$TS
PROOF=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
PASS=1
step() { echo; echo "== $*"; }
check() { if [[ $2 == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (expected '$3', got '$2')"; PASS=0; fi; }
cleanup() { $KUBE delete pod,configmap,secret -l drill=velero --ignore-not-found --wait=true >/dev/null 2>&1; }
trap cleanup EXIT

step "1. Create test objects (label drill=velero)"
cleanup
$KUBE create configmap drill-cm --from-literal=proof="$PROOF" >/dev/null
$KUBE create secret generic drill-secret --from-literal=password="$SECRET" >/dev/null
$KUBE label configmap drill-cm drill=velero >/dev/null
$KUBE label secret drill-secret drill=velero >/dev/null
$KUBE apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: drill-pod
  labels: {drill: velero}
spec:
  containers:
  - name: app
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes:
  - name: data
    emptyDir: {}
EOF
$KUBE wait --for=condition=Ready pod/drill-pod --timeout=180s >/dev/null || { echo "drill-pod did not start"; exit 1; }
# Write the proof only into the volume (not into the pod spec), so only a real volume restore can bring it back
$KUBE exec drill-pod -c app -- sh -c "echo $PROOF > /data/proof.txt"
check "proof written to volume" "$($KUBE exec drill-pod -c app -- cat /data/proof.txt)" "$PROOF"

step "2. Back up (velero backup $NAME)"
$VEL backup create "$NAME" --include-namespaces default --selector drill=velero --wait >/dev/null
BPHASE=$($VEL backup get "$NAME" -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"].get("phase"))')
check "backup phase" "$BPHASE" Completed
PVB=$($VEL backup describe "$NAME" --details 2>/dev/null | grep -cE 'default/drill-pod: data' || true)
check "volume data included in backup" "$([[ $PVB -ge 1 ]] && echo yes || echo no)" yes

step "3. Delete the originals (simulated loss)"
cleanup
check "objects gone" "$($KUBE get pod,configmap,secret -l drill=velero --no-headers 2>/dev/null | wc -l)" 0

step "4. Restore (velero restore $NAME)"
$VEL restore create "$NAME" --from-backup "$NAME" --wait >/dev/null
RPHASE=$($VEL restore get "$NAME" -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"].get("phase"))')
check "restore phase" "$RPHASE" Completed
$KUBE wait --for=condition=Ready pod/drill-pod --timeout=180s >/dev/null

step "5. Compare restored data with the originals"
check "ConfigMap data"   "$($KUBE get configmap drill-cm -o jsonpath='{.data.proof}')" "$PROOF"
check "Secret data"      "$($KUBE get secret drill-secret -o jsonpath='{.data.password}' | base64 -d)" "$SECRET"
check "Volume file data" "$($KUBE exec drill-pod -c app -- cat /data/proof.txt 2>/dev/null)" "$PROOF"

step "6. Clean up drill objects and drill backup"
cleanup
$VEL backup delete "$NAME" --confirm >/dev/null && echo "  drill backup $NAME scheduled for deletion"

echo
if [[ $PASS == 1 ]]; then echo "RESTORE DRILL PASSED - Velero backups can be restored, including volume data."
else echo "RESTORE DRILL FAILED - see FAIL lines above. Details: $VEL restore describe $NAME --details"; exit 1; fi
