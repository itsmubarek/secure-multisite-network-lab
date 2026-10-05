# Build notes and troubleshooting

Problems met while building the lab, how they were diagnosed and what was changed. They are kept here because they are the
realistic part of the work.

## 1. Ubuntu 26.04 guest hangs or panics in VirtualBox 7.2 on a Windows host with the hypervisor active
*Symptom:* the installer froze at `Loading essential drivers` (console frozen, one vCPU at 100 %), and with other settings the guest ended in
`Kernel panic - IO-APIC + timer doesn't work`.
*Diagnosis:* compared with a VM that boots on the same machine (`VBoxManage showvminfo`): that VM used 4 vCPUs and the **default** paravirtualisation provider.
*Fix:* `--cpus 4 --paravirtprovider default --x2apic on --graphicscontroller vmsvga`. Clones use 2 vCPUs and 1 GB RAM. Starting all five clones at once
occasionally caused one to panic at boot; a power-cycle fixed it (see `evidence/` for none of this — it is host behaviour, not lab behaviour).

## 2. `openssh-server` is not installed by the unattended install
*Symptom:* port-forwarded ssh answered with `Connection abort`.
*Fix:* log in on the VM console (`VBoxManage controlvm <vm> keyboardputstring`), then install `openssh-server`.

## 3. Interrupted package upgrade and stale `cdrom` apt source
*Symptom:* `dpkg was interrupted`, then `The repository 'file:/cdrom resolute Release' no longer has a Release file`.
*Cause:* the VM was powered off during the installer's security-update step; the installer medium was still listed as an apt source.
*Fix:* delete `/etc/apt/sources.list.d/cdrom.sources`, then `apt-get -f install`, `dpkg --configure -a`, `apt-get dist-upgrade`.

## 4. sshd refuses to start on clones: `no hostkeys available`
*Cause:* the base image's host keys were deleted so each clone could create its own, but the systemd drop-in ran `ssh-keygen -A` *after* the
unit's own `sshd -t` check. `03-provision-base.sh` now resets `ExecStartPre=` and runs `ssh-keygen -A` first.

## 5. Netplan: `Cannot find unique matching interface for enp0s3`
*Cause:* the installer's `00-installer-config.yaml` matches the base VM's MAC address, which differs on every clone. Removed in `03` and `04`.
Also: `dhcp4-overrides: use-routes: false` requires the same setting under `dhcp6-overrides` for systemd-networkd.

## 6. OpenSSL: `variable has no value` for `$ENV::SAN`
*Cause:* the config is parsed completely, so the `subjectAltName = $ENV::SAN` line fails for every command unless `SAN` is set.
*Fix:* export a default `SAN` for all calls and set the real value only when signing a server certificate.

## 7. Syslog from `client-b` was dropped by the firewall
*Found in:* the central log itself (`FW-DROP ... DPT=514` from `gw-b`). Cause: tcp/514 from Site B to the collector was not in the policy.
*Fix:* explicit rules on `gw-b` and `gw-a` (tunnel interface only).

## 8. The IDS saw no scan from Site B
*Diagnosis:* a `tcpdump` on `wg0` showed only the syslog flow, no scan packets. `gw-b`'s default-deny egress policy dropped them before the tunnel
(`evidence/07-site-b-scan-blocked-at-gw-b.txt`). Not a bug: the control worked earlier than the sensor.
