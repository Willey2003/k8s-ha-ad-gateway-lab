#!/usr/bin/env bash
# Copy the gateway scripts to /opt/k8s-lab/gateway so AD admins (group k8s-admins) can run them.
#   sudo ~/k8s-deployer/gateway/install-to-opt.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd); DST=/opt/k8s-lab/gateway
install -d -m 0750 -g k8s-admins /opt/k8s-lab "$DST"
install -m 0750 -g k8s-admins "$SRC"/gw-*.sh "$DST"/
install -m 0640 -g k8s-admins "$SRC"/hug-values.yaml "$SRC"/apps-wildcard.crt "$SRC"/lab-ca.crt "$DST"/
install -m 0640 -g k8s-admins "$SRC"/apps-wildcard.key "$DST"/
ls -la "$DST"
