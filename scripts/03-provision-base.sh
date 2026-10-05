#!/usr/bin/env bash
# Step 3: provision the base image (runs INSIDE the base VM, via ssh).
# Installs the lab toolset and makes the image safe to clone (unique host keys / machine-id per clone).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo rm -f /etc/apt/sources.list.d/cdrom.sources   # stale installer medium
sudo apt-get update -qq
sudo apt-get install -y openssh-server \
  iptables iptables-persistent wireguard wireguard-tools \
  tcpdump nmap openssl curl traceroute net-tools dnsutils \
  nginx suricata jq

# nginx and suricata are enabled only on the VMs that need them
sudo systemctl disable --now nginx suricata 2>/dev/null || true

# the lab VMs must not be reconfigured by cloud-init's network handling
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null

# every clone generates its own ssh host keys on first start
sudo mkdir -p /etc/systemd/system/ssh.service.d
printf '[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\nExecStartPre=/usr/sbin/sshd -t\n' | sudo tee /etc/systemd/system/ssh.service.d/hostkeys.conf >/dev/null
sudo systemctl daemon-reload

# the installer's network file is bound to the base VM's MAC address and breaks clones
sudo rm -f /etc/netplan/00-installer-config.yaml

# unique identity for each clone
sudo rm -f /etc/ssh/ssh_host_*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo apt-get clean
history -c || true
echo "BASE_READY"
