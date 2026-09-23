#!/usr/bin/env bash
# Log in to Dex with an AD account and ask ONE API server who it thinks you are.
#   ~/k8s-deployer/ad/k8s/test-apiserver-login.sh <api-server-ip> [ad-username]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IP=${1:?give the API server IP, e.g. 10.10.1.21}; USER_AD=${2:-lab_admin1}
CACHE=$(mktemp -d); CA=$(mktemp); trap 'rm -rf "$CACHE" "$CA"' EXIT
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CA"
TOKEN=$("$HERE/kubelogin" get-token --oidc-issuer-url=https://dex.corp.example:32000 \
  --oidc-client-id=kubernetes --oidc-client-secret="$(cat "$HERE/client-secret.txt")" \
  --grant-type=password --username="$USER_AD" --certificate-authority="$HERE/lab-ca.crt" \
  --oidc-extra-scope=profile --oidc-extra-scope=email --oidc-extra-scope=groups \
  --token-cache-dir="$CACHE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["token"])')
K="kubectl --kubeconfig=/dev/null --server=https://$IP:6443 --certificate-authority=$CA --token=$TOKEN"
echo "== API server $IP says you are:"; $K auth whoami
echo "== permission checks as this AD user:"
for c in "get pods -A" "delete nodes" "create deployments -n playground"; do printf '  %-34s %s\n' "$c" "$($K auth can-i $c 2>&1)"; done
