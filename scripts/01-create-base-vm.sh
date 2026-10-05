#!/usr/bin/env bash
# Step 1: create the "base" Ubuntu Server VM with an unattended install (VirtualBox).
# Every lab VM is a clone of this image, so the install is done once.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB_DIR/.lab-credentials"

VBM="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
ISO='C:\Users\hp\Downloads\Organized_Downloads\Installers\ubuntu-26.04.1-live-server-amd64.iso'
VM=base
VMDIR="$("$VBM" list systemproperties | sed -n 's/^Default machine folder: *//p' | tr -d '\r')"
PUBKEY="$(cat "$LAB_DIR/.keys/lab_ed25519.pub")"

"$VBM" createvm --name "$VM" --ostype Ubuntu_64 --register
"$VBM" modifyvm "$VM" --memory 4096 --cpus 4 --audio-driver none --vram 16 --graphicscontroller vmsvga \
  --x2apic on --ioapic on --nic1 nat --natpf1 "ssh,tcp,127.0.0.1,2222,,22"
"$VBM" createmedium disk --filename "$VMDIR\\$VM\\$VM.vdi" --size 12288 --format VDI --variant Standard
"$VBM" storagectl "$VM" --name SATA --add sata --controller IntelAhci
"$VBM" storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$VMDIR\\$VM\\$VM.vdi"

# Post-install: install the lab toolset and authorise the host key for passwordless ssh.
POST="mkdir -p /home/$LAB_USER/.ssh && echo '$PUBKEY' >> /home/$LAB_USER/.ssh/authorized_keys && chmod 700 /home/$LAB_USER/.ssh && chmod 600 /home/$LAB_USER/.ssh/authorized_keys && chown -R $LAB_USER:$LAB_USER /home/$LAB_USER/.ssh"

"$VBM" unattended install "$VM" \
  --iso="$ISO" \
  --user="$LAB_USER" --password="$LAB_PASSWORD" --full-user-name="Lab Admin" \
  --hostname=base.lab.local --time-zone=Europe/Berlin --locale=en_US \
  --post-install-command="$POST" \
  --start-vm=headless

echo "Unattended install started for VM '$VM'. It reboots itself when done."

# NOTE: see docs/build-notes.md - the unattended install does not install openssh-server and leaves a stale 'cdrom' apt source.
