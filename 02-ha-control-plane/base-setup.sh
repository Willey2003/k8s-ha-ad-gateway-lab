#!/usr/bin/env bash
# Base OS setup for a new control-plane VM (manager-2 / manager-3).
# Updates packages, makes sure ssh + curl are present, and configures ufw
# like the existing manager (default deny) with the ports a kubeadm
# control-plane node running Calico needs. Run on the new VM:
#   sudo ./base-setup.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

LAN=10.10.1.0/24          # nodes, etcd, bastion
POD_CIDR=192.168.0.0/16    # Calico pod network (kubeadm podSubnet)
export DEBIAN_FRONTEND=noninteractive

echo "== apt update / upgrade"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null

echo "== Base packages"
apt-get install -y -qq openssh-server curl ca-certificates gnupg ufw \
  open-vm-tools chrony >/dev/null
systemctl enable --now ssh open-vm-tools chrony >/dev/null

echo "== Firewall (ufw)"
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'ssh' >/dev/null
for p in 6443 10250 10257 10259; do
  ufw allow from "$LAN" to any port "$p" proto tcp comment 'k8s control plane' >/dev/null
done
ufw allow from "$LAN" to any port 179  proto tcp comment 'calico bgp'     >/dev/null
ufw allow from "$LAN" to any port 5473 proto tcp comment 'calico typha'   >/dev/null
ufw allow from "$LAN" to any port 4789 proto udp comment 'calico vxlan'   >/dev/null
# ufw has no rule syntax for IP-in-IP (protocol 4), so add it to before.rules
grep -q 'calico ipip' /etc/ufw/before.rules || sed -i "0,/^COMMIT/s||# calico ipip\n-A ufw-before-input -p 4 -s $LAN -j ACCEPT\nCOMMIT|" /etc/ufw/before.rules
ufw allow from "$POD_CIDR" comment 'pod network' >/dev/null
ufw route allow from "$POD_CIDR" comment 'pod forwarding' >/dev/null
ufw route allow to "$POD_CIDR"   comment 'pod forwarding' >/dev/null
ufw --force enable >/dev/null

echo "== Result"
echo "host: $(hostname)  ip: $(hostname -I | awk '{print $1}')"
df -h / | tail -1
systemctl is-active ssh | sed 's/^/ssh: /'
curl --version | head -1
ufw status numbered
echo "Base setup done."
