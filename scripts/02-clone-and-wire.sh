#!/usr/bin/env bash
# Step 2: clone the base image into the lab VMs and attach them to isolated VirtualBox internal networks.
#
# Topology (see docs/topology.md):
#   gw-a     : nic2 wan, nic3 lan-a, nic4 dmz
#   gw-b     : nic2 wan, nic3 lan-b
#   web-dmz  : nic2 dmz
#   client-a : nic2 lan-a
#   client-b : nic2 lan-b
#   syslog   : nic2 dmz            (added in phase 2)
# nic1 is a NAT adapter used only for provisioning (apt, ssh from the host); it is removed at the end.
set -euo pipefail

VBM="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"

# name:ssh-port:nic2:nic3:nic4
VMS=(
  "gw-a:2201:wan:lan-a:dmz"
  "gw-b:2202:wan:lan-b:"
  "web-dmz:2203:dmz::"
  "client-a:2204:lan-a::"
  "client-b:2205:lan-b::"
)

for entry in "${VMS[@]}"; do
  IFS=: read -r name port n2 n3 n4 <<<"$entry"
  "$VBM" clonevm base --name "$name" --register --mode machine
  "$VBM" modifyvm "$name" --memory 1024 --cpus 2 --macaddress1 auto
  "$VBM" modifyvm "$name" --natpf1 delete ssh
  "$VBM" modifyvm "$name" --natpf1 "ssh,tcp,127.0.0.1,$port,,22"
  [ -n "$n2" ] && "$VBM" modifyvm "$name" --nic2 intnet --intnet2 "$n2" --nictype2 virtio --cableconnected2 on
  [ -n "$n3" ] && "$VBM" modifyvm "$name" --nic3 intnet --intnet3 "$n3" --nictype3 virtio --cableconnected3 on
  [ -n "$n4" ] && "$VBM" modifyvm "$name" --nic4 intnet --intnet4 "$n4" --nictype4 virtio --cableconnected4 on
  echo "created $name (ssh: 127.0.0.1:$port)"
done
