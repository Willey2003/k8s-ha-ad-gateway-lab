#!/usr/bin/env bash
# AD PHASE 4d - Bastion: let every AD user SSH in (no sudo) and use kubectl with their AD login.
#   sudo ~/k8s-deployer/ad/k8s/4d-bastion.sh
# - SSSD on Bastion: allow groups k8s-admins AND domain users (other machines stay k8s-admins only)
# - installs kubelogin as a kubectl plugin, the lab CA, and a kubeconfig template
# - AD users get ~/.kube/config automatically at first login; kubectl then asks for their AD password
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
OWNER=${SUDO_USER:-labops}
D=/etc/kubernetes-ad
SECRET=$(cat "$HERE/client-secret.txt")
CLUSTER_CA=$(sudo -u "$OWNER" kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
[[ -n $CLUSTER_CA ]] || { echo "could not read cluster CA from $OWNER's kubeconfig" >&2; exit 1; }

echo "== SSSD: allow all domain users to log in to Bastion"
python3 - /etc/sssd/sssd.conf <<'PY'
import configparser, sys
p = sys.argv[1]; c = configparser.RawConfigParser(); c.optionxform = str; c.read(p)
s = "domain/corp.example"
c.set(s, "simple_allow_groups", "k8s-admins, domain users")
with open(p, "w") as f: c.write(f)
PY
chmod 600 /etc/sssd/sssd.conf; systemctl restart sssd; sss_cache -E 2>/dev/null || true

echo "== kubelogin plugin + CA + kubeconfig template in $D"
install -m 0755 "$HERE/kubelogin" /usr/local/bin/kubectl-oidc_login
install -d -m 0755 "$D"
install -m 0644 "$HERE/lab-ca.crt" "$D/lab-ca.crt"
cat > "$D/kubeconfig.template" <<TPL
apiVersion: v1
kind: Config
clusters:
- name: lab
  cluster:
    server: https://10.10.1.20:6443
    certificate-authority-data: $CLUSTER_CA
users:
- name: ad
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      interactiveMode: IfAvailable
      command: kubectl
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://dex.corp.example:32000
      - --oidc-client-id=kubernetes
      - --oidc-client-secret=$SECRET
      - --grant-type=password
      - --username=__USERNAME__
      - --certificate-authority=$D/lab-ca.crt
      - --oidc-extra-scope=profile
      - --oidc-extra-scope=email
      - --oidc-extra-scope=groups
      - --oidc-extra-scope=offline_access
contexts:
- name: lab
  context: {cluster: lab, user: ad, namespace: playground}
current-context: lab
TPL
chmod 0644 "$D/kubeconfig.template"
cat > /etc/profile.d/k8s-ad-kubeconfig.sh <<'PROF'
# Give AD users (uid >= 100000) a kubeconfig that logs in with their AD account (see /etc/kubernetes-ad)
if [ "$(id -u)" -ge 100000 ] && [ ! -f "$HOME/.kube/config" ] && [ -r /etc/kubernetes-ad/kubeconfig.template ]; then
  mkdir -p "$HOME/.kube" && sed "s/__USERNAME__/$(id -un)/" /etc/kubernetes-ad/kubeconfig.template > "$HOME/.kube/config" \
    && chmod 600 "$HOME/.kube/config" && echo "kubectl is set up for your AD account (namespace: playground). Try: kubectl get pods -A"
fi
PROF
chmod 0644 /etc/profile.d/k8s-ad-kubeconfig.sh
echo "== done"; realm list | grep -E 'permitted-groups'
