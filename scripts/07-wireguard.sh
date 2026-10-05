#!/usr/bin/env bash
# Step 7: site-to-site WireGuard VPN between gw-a (Site A) and gw-b (Site B), run from the host.
#
#   tunnel network 10.99.0.0/24   gw-a = 10.99.0.1   gw-b = 10.99.0.2   udp/51820 over the "WAN" (192.0.2.0/24)
#   gw-a routes 10.20.1.0/24 (LAN-B) into the tunnel; gw-b routes 10.10.1.0/24 and 10.10.2.0/24 (LAN-A, DMZ).
#   Private keys are generated ON the gateways and never leave them; only public keys (and a one-time
#   pre-shared key) are exchanged.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $LAB_DIR/.keys/lab_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
A() { $SSH -p 2201 lab@127.0.0.1 "$@"; }   # gw-a
B() { $SSH -p 2202 lab@127.0.0.1 "$@"; }   # gw-b

echo "== 1. replace the plain static inter-site routes by the tunnel"
A "sudo sed -i '/routes: \[{to: 10.20.1.0/d' /etc/netplan/60-lab.yaml && sudo netplan apply"
B "sudo sed -i '/routes: \[{to: 10.10.1.0/d' /etc/netplan/60-lab.yaml && sudo netplan apply"

echo "== 2. key generation on each gateway (private keys stay on the gateway)"
for gw in A B; do
  $gw 'sudo sh -c "umask 077; mkdir -p /etc/wireguard; wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key"'
done
PUB_A="$(A 'sudo cat /etc/wireguard/public.key')"
PUB_B="$(B 'sudo cat /etc/wireguard/public.key')"
PSK="$(A 'wg genpsk')"
echo "public keys exchanged: A=${PUB_A:0:8}... B=${PUB_B:0:8}..."

echo "== 3. wg0.conf on both gateways"
A "sudo sh -c 'umask 077; printf %s \"$PSK\" > /etc/wireguard/psk'"
B "sudo sh -c 'umask 077; printf %s \"$PSK\" > /etc/wireguard/psk'"

A "PRIV=\$(sudo cat /etc/wireguard/private.key); sudo sh -c \"umask 077; cat > /etc/wireguard/wg0.conf\" <<EOF
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = \$PRIV

[Peer]
# gw-b (Site B)
PublicKey = $PUB_B
PresharedKey = $PSK
Endpoint = 192.0.2.2:51820
AllowedIPs = 10.99.0.2/32, 10.20.1.0/24
PersistentKeepalive = 25
EOF"

B "PRIV=\$(sudo cat /etc/wireguard/private.key); sudo sh -c \"umask 077; cat > /etc/wireguard/wg0.conf\" <<EOF
[Interface]
Address = 10.99.0.2/24
ListenPort = 51820
PrivateKey = \$PRIV

[Peer]
# gw-a (Site A)
PublicKey = $PUB_A
PresharedKey = $PSK
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.99.0.1/32, 10.10.1.0/24, 10.10.2.0/24
PersistentKeepalive = 25
EOF"

echo "== 4. start the tunnels"
A 'sudo systemctl enable --now wg-quick@wg0 >/dev/null 2>&1; sudo wg show wg0 | head -3'
B 'sudo systemctl enable --now wg-quick@wg0 >/dev/null 2>&1; sudo wg show wg0 | head -3'

# public configs (no private material) for the repository
mkdir -p "$LAB_DIR/configs/gw-a" "$LAB_DIR/configs/gw-b"
A 'sudo sed "s/^PrivateKey = .*/PrivateKey = <redacted>/;s/^PresharedKey = .*/PresharedKey = <redacted>/" /etc/wireguard/wg0.conf' > "$LAB_DIR/configs/gw-a/wg0.conf"
B 'sudo sed "s/^PrivateKey = .*/PrivateKey = <redacted>/;s/^PresharedKey = .*/PresharedKey = <redacted>/" /etc/wireguard/wg0.conf' > "$LAB_DIR/configs/gw-b/wg0.conf"
echo "WireGuard finished"
