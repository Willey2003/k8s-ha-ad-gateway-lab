#!/usr/bin/env bash
# Copy AD helper tools to /opt/k8s-lab/ad for K8s-Admins.   sudo /home/labops/k8s-deployer/ad/k8s/install-ad-tools.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
S=$(cd "$(dirname "$0")" && pwd); D=/opt/k8s-lab/ad
install -d -m 0750 -g k8s-admins /opt/k8s-lab "$D"
install -m 0750 -g k8s-admins "$S/rotate-dex-bindpw.sh" "$S/ldapbind.py" "$D/"
install -m 0640 -g k8s-admins "$S/lab-ca.crt" "$D/"
ls -la "$D"
