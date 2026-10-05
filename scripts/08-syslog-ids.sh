#!/usr/bin/env bash
# Step 8 (phase 2): centralised logging (rsyslog over TCP) and Suricata IDS on gw-a, run from the host.
#
#   collector : client-a (10.10.1.10) receives syslog on tcp/514 and stores it per host in /var/log/remote/<host>/
#   senders   : gw-a, gw-b, web-dmz, client-b forward all logs (including the firewall's "FW-DROP" kernel messages)
#   Suricata  : runs on gw-a and watches LAN-A (enp0s9) and the tunnel (wg0) with local rules for scans.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $LAB_DIR/.keys/lab_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
declare -A PORT=([gw-a]=2201 [gw-b]=2202 [web-dmz]=2203 [client-a]=2204 [client-b]=2205)
run() { local vm="$1"; shift; $SSH -p "${PORT[$vm]}" lab@127.0.0.1 "$@"; }

echo "== 1. log collector on client-a"
run client-a 'sudo tee /etc/rsyslog.d/10-collector.conf >/dev/null' <<'EOF'
# receive remote logs on tcp/514 and write one directory per sending host
module(load="imtcp")
input(type="imtcp" port="514")
template(name="PerHost" type="string" string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")
if ($inputname == "imtcp") then {
    action(type="omfile" dynaFile="PerHost" dirCreateMode="0755" fileCreateMode="0640")
    stop
}
EOF
run client-a 'sudo mkdir -p /var/log/remote && sudo chown syslog:adm /var/log/remote && sudo rsyslogd -N1 2>&1 | tail -1; sudo systemctl restart rsyslog; ss -ltn | grep ":514 "'

echo "== 2. log forwarding from the other VMs"
for vm in gw-a gw-b web-dmz client-b; do
  run "$vm" 'sudo tee /etc/rsyslog.d/90-forward.conf >/dev/null' <<'EOF'
# forward everything to the central collector (tcp, with a disk-assisted memory queue so no logs are lost on outages)
*.* action(type="omfwd" target="10.10.1.10" port="514" protocol="tcp"
           action.resumeRetryCount="-1" queue.type="LinkedList" queue.size="10000" queue.filename="fwd" queue.saveOnShutdown="on")
EOF
  run "$vm" 'sudo rsyslogd -N1 2>&1 | tail -1; sudo systemctl restart rsyslog'
  echo "forwarding enabled on $vm"
done
# gw-a is on the same LAN as the collector, so it logs directly

echo "== 3. Suricata IDS on gw-a"
run gw-a 'sudo tee /etc/suricata/suricata-lab.yaml >/dev/null' <<'EOF'
%YAML 1.1
---
vars:
  address-groups:
    HOME_NET: "[10.10.0.0/16,10.20.0.0/16,10.99.0.0/24]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    SMTP_SERVERS: "$HOME_NET"
    SQL_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"
    TELNET_SERVERS: "$HOME_NET"
    AIM_SERVERS: "$EXTERNAL_NET"
    DC_SERVERS: "$HOME_NET"
    DNP3_SERVER: "$HOME_NET"
    DNP3_CLIENT: "$HOME_NET"
    MODBUS_CLIENT: "$HOME_NET"
    MODBUS_SERVER: "$HOME_NET"
    ENIP_CLIENT: "$HOME_NET"
    ENIP_SERVER: "$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544
default-log-dir: /var/log/suricata/
stats:
  enabled: no
outputs:
  - fast:
      enabled: yes
      filename: fast.log
      append: yes
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert
  - syslog:
      enabled: yes
      facility: local5
      level: Info
af-packet:
  - interface: enp0s9
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    checksum-checks: no
  - interface: wg0
    cluster-id: 98
    cluster-type: cluster_flow
    defrag: yes
    checksum-checks: no
detect:
  profile: low
max-pending-packets: 512
app-layer:
  protocols:
    tls:
      enabled: yes
    http:
      enabled: yes
default-rule-path: /etc/suricata/rules
rule-files:
  - local.rules
classification-file: /etc/suricata/classification.config
reference-config-file: /etc/suricata/reference.config
threshold-file: /etc/suricata/threshold.config
logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: no
    - file:
        enabled: yes
        level: info
        filename: suricata.log
EOF
run gw-a 'sudo tee /etc/suricata/rules/local.rules >/dev/null' <<'EOF'
# local detection rules for the lab (scan detection on the protected networks)
alert tcp any any -> $HOME_NET any (msg:"LAB TCP SYN scan: many ports probed by one source"; flags:S; threshold: type both, track by_src, count 15, seconds 10; classtype:attempted-recon; sid:1000001; rev:1;)
alert icmp any any -> $HOME_NET any (msg:"LAB ICMP echo flood or ping sweep"; itype:8; threshold: type both, track by_src, count 8, seconds 10; classtype:network-scan; sid:1000002; rev:1;)
alert tcp any any -> $HOME_NET 22 (msg:"LAB SSH connection attempt towards protected networks"; flags:S; threshold: type threshold, track by_src, count 1, seconds 60; classtype:attempted-recon; sid:1000003; rev:1;)
EOF
run gw-a 'sudo tee /etc/systemd/system/suricata-lab.service >/dev/null' <<'EOF'
[Unit]
Description=Suricata IDS (lab profile)
After=network-online.target wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata-lab.yaml --af-packet
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
run gw-a 'sudo suricata -T -c /etc/suricata/suricata-lab.yaml 2>&1 | tail -3; sudo systemctl daemon-reload; sudo systemctl enable --now suricata-lab >/dev/null 2>&1; sleep 8; systemctl is-active suricata-lab'
echo "phase 2 setup finished"
