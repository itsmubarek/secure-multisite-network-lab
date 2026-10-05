#!/usr/bin/env bash
# Step 4: hostnames, static addressing and routing (run from the host).
#
#   wan   192.0.2.0/24   (the simulated "Internet", documentation range)
#   lan-a 10.10.1.0/24   dmz 10.10.2.0/24      lan-b 10.20.1.0/24
#
# The NAT adapter (enp0s3) is kept only for management ssh from the host: its default route is disabled,
# so all lab traffic uses the lab networks.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $LAB_DIR/.keys/lab_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# name port yaml-for-lab-interfaces
configure() {
  local name="$1" port="$2" yaml="$3" forward="$4"
  $SSH -p "$port" lab@127.0.0.1 "sudo rm -f /etc/netplan/00-installer-config.yaml && sudo hostnamectl set-hostname $name && sudo sed -i \"s/^127.0.1.1.*/127.0.1.1 $name/\" /etc/hosts; grep -q \"127.0.1.1\" /etc/hosts || echo \"127.0.1.1 $name\" | sudo tee -a /etc/hosts >/dev/null"
  $SSH -p "$port" lab@127.0.0.1 "sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null" <<'EOF'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
      dhcp6-overrides:
        use-routes: false
EOF
  printf '%s\n' "$yaml" | $SSH -p "$port" lab@127.0.0.1 "sudo tee /etc/netplan/60-lab.yaml >/dev/null; sudo chmod 600 /etc/netplan/*.yaml; sudo netplan apply"
  if [ "$forward" = "yes" ]; then
    $SSH -p "$port" lab@127.0.0.1 "echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-forward.conf >/dev/null; sudo sysctl -q --system"
  fi
  echo "configured $name"
}

configure gw-a 2201 "network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [192.0.2.1/24]
      routes: [{to: 10.20.1.0/24, via: 192.0.2.2}]
    enp0s9: {addresses: [10.10.1.1/24]}
    enp0s10: {addresses: [10.10.2.1/24]}
" yes

configure gw-b 2202 "network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [192.0.2.2/24]
      routes: [{to: 10.10.1.0/24, via: 192.0.2.1}, {to: 10.10.2.0/24, via: 192.0.2.1}]
    enp0s9:
      addresses: [10.20.1.1/24]
" yes

configure web-dmz 2203 "network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [10.10.2.10/24]
      routes: [{to: default, via: 10.10.2.1}]
" no

configure client-a 2204 "network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [10.10.1.10/24]
      routes: [{to: default, via: 10.10.1.1}]
" no

configure client-b 2205 "network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [10.20.1.10/24]
      routes: [{to: default, via: 10.20.1.1}]
" no
