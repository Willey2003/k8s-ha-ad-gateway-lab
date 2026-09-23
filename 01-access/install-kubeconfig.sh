#!/usr/bin/env bash
# Run on your workstation as your normal user (no sudo):
#   ./install-kubeconfig.sh [user@host]      (default: labops@10.10.1.14)
set -euo pipefail
REMOTE=${1:-labops@10.10.1.14}
mkdir -p ~/.kube
[[ -f ~/.kube/config ]] && mv ~/.kube/config ~/.kube/config.bak.$(date +%s)
scp "$REMOTE:deployer.kubeconfig" ~/.kube/config
chmod 600 ~/.kube/config
kubectl auth whoami 2>/dev/null || true
kubectl get nodes
kubectl auth can-i create deployments
