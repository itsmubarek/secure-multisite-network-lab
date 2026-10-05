#!/usr/bin/env bash
# Step 5: default-deny firewall on both gateways (iptables), pushed from the host.
#
# Policy (stateful, default DROP on INPUT and FORWARD):
#   gw-a: lan-a -> dmz      only ICMP echo and tcp/443 to web-dmz
#         lan-a -> site B   ICMP and tcp/443 to 10.20.1.0/24
#         dmz   -> anywhere nothing (the DMZ may never initiate connections), except syslog/tcp 514 to the log collector
#         wan   -> anywhere nothing; only udp/51820 (WireGuard) terminates on the gateway itself
#         site B traffic is accepted only from the tunnel interface wg0 (no spoofing via the WAN)
#   gw-b: lan-b -> site A   ICMP and tcp/443 to web-dmz only
#   both: management ssh only on the NAT adapter (enp0s3), everything else dropped and logged (rate limited)
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $LAB_DIR/.keys/lab_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
mkdir -p "$LAB_DIR/configs/gw-a" "$LAB_DIR/configs/gw-b"

RULES_A='*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:LOG_DROP - [0:0]
# --- INPUT: traffic addressed to the gateway itself
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i enp0s3 -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s -j ACCEPT
-A INPUT -i enp0s8 -p udp --dport 51820 -j ACCEPT
-A INPUT -j LOG_DROP
# --- FORWARD: traffic routed through the gateway
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i enp0s9 -o enp0s10 -d 10.10.2.10 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -i enp0s9 -o enp0s10 -d 10.10.2.10 -p tcp --dport 443 -j ACCEPT
-A FORWARD -i enp0s9 -d 10.20.1.0/24 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -i enp0s9 -d 10.20.1.0/24 -p tcp --dport 443 -j ACCEPT
-A FORWARD -i wg0 -s 10.20.1.0/24 -d 10.10.2.10 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -i wg0 -s 10.20.1.0/24 -d 10.10.2.10 -p tcp --dport 443 -j ACCEPT
# --- central logging: web-dmz and gw-b (through the tunnel) may send syslog/tcp 514 to the collector on client-a
-A FORWARD -i enp0s10 -s 10.10.2.10 -d 10.10.1.10 -p tcp --dport 514 -j ACCEPT
-A FORWARD -i wg0 -s 10.99.0.2 -d 10.10.1.10 -p tcp --dport 514 -j ACCEPT
-A FORWARD -i wg0 -s 10.20.1.10 -d 10.10.1.10 -p tcp --dport 514 -j ACCEPT
-A FORWARD -j LOG_DROP
# --- logging chain (rate limited so the log cannot be flooded)
-A LOG_DROP -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "FW-DROP: " --log-level 4
-A LOG_DROP -j DROP
COMMIT'

RULES_B='*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:LOG_DROP - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i enp0s3 -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s -j ACCEPT
-A INPUT -i enp0s8 -p udp --dport 51820 -j ACCEPT
-A INPUT -j LOG_DROP
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i enp0s9 -d 10.10.2.10 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -i enp0s9 -d 10.10.2.10 -p tcp --dport 443 -j ACCEPT
-A FORWARD -i enp0s9 -d 10.10.1.0/24 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -i enp0s9 -s 10.20.1.10 -d 10.10.1.10 -p tcp --dport 514 -j ACCEPT
-A FORWARD -i wg0 -s 10.10.1.0/24 -d 10.20.1.0/24 -p icmp --icmp-type echo-request -j ACCEPT
-A FORWARD -j LOG_DROP
-A LOG_DROP -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "FW-DROP: " --log-level 4
-A LOG_DROP -j DROP
COMMIT'

apply() {
  local name="$1" port="$2" rules="$3"
  printf '%s\n' "$rules" > "$LAB_DIR/configs/$name/rules.v4"
  printf '%s\n' "$rules" | $SSH -p "$port" lab@127.0.0.1 \
    "sudo tee /etc/iptables/rules.v4 >/dev/null && sudo iptables-restore -t < /etc/iptables/rules.v4 && sudo iptables-restore < /etc/iptables/rules.v4 && sudo systemctl enable netfilter-persistent >/dev/null 2>&1"
  echo "firewall applied on $name"
}

apply gw-a 2201 "$RULES_A"
apply gw-b 2202 "$RULES_B"
