#!/usr/bin/env bash
# Test an AD login against Dex (no cluster change). Shows the identity in the token, not the token.
#   ~/k8s-deployer/ad/k8s/test-dex-login.sh [ad-username]      (default: lab_admin1)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
USER_AD=${1:-lab_admin1}
CACHE=$(mktemp -d); trap 'rm -rf "$CACHE"' EXIT
"$HERE/kubelogin" get-token \
  --oidc-issuer-url=https://dex.corp.example:32000 \
  --oidc-client-id=kubernetes --oidc-client-secret="$(cat "$HERE/client-secret.txt")" \
  --grant-type=password --username="$USER_AD" \
  --certificate-authority="$HERE/lab-ca.crt" \
  --oidc-extra-scope=profile --oidc-extra-scope=email --oidc-extra-scope=groups \
  --token-cache-dir="$CACHE" \
| python3 -c '
import sys, json, base64
tok = json.load(sys.stdin)["status"]["token"]
p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print("LOGIN OK")
for k in ("iss", "aud", "preferred_username", "name", "email", "groups"):
    print(f"  {k:20} {c.get(k)}")
print("  -> Kubernetes will see user  ad:" + c.get("preferred_username", "?"))
print("  -> and groups               " + ", ".join(["ad:" + g for g in c.get("groups", [])] + ["ad:all-users"]))
'
