# Secure Multi-Site Network Lab

A small two-site enterprise network built in VirtualBox to practise the core infrastructure-security building blocks:
**network segmentation, a default-deny firewall, a private PKI with HTTPS, a site-to-site WireGuard VPN, intrusion detection and
central logging.** Every claim below is backed by a captured test in [`evidence/`](evidence/).

> Process note: the build was automated with shell scripts that were written with AI assistance (Claude Code) and run against
> the VMs. The scripts, configs and test output in this repository are exactly what was executed.

## Architecture

```
                         Site A                                                   Site B
  ┌──────────┐   ┌─────────────────────────┐   WAN 192.0.2.0/24    ┌──────────────────────┐   ┌──────────┐
  │ client-a │───┤ gw-a                    ├══ WireGuard tunnel ═══┤ gw-b                 ├───┤ client-b │
  │ 10.10.1.10│  │ iptables default-deny   │    10.99.0.0/24       │ iptables default-deny│   │10.20.1.10│
  │ admin+CA │   │ Suricata IDS            │    udp/51820          └──────────────────────┘   └──────────┘
  │ syslog   │   └───────────┬─────────────┘
  └──────────┘               │ DMZ 10.10.2.0/24
                      ┌──────┴───────┐
                      │ web-dmz      │  nginx, HTTPS (cert from the lab CA)
                      │ 10.10.2.10   │
                      └──────────────┘
```

| VM | Role | Networks / addresses |
|---|---|---|
| `gw-a` | Site A gateway: router, firewall, WireGuard, Suricata | wan 192.0.2.1 · lan-a 10.10.1.1 · dmz 10.10.2.1 · wg0 10.99.0.1 |
| `gw-b` | Site B gateway: router, firewall, WireGuard | wan 192.0.2.2 · lan-b 10.20.1.1 · wg0 10.99.0.2 |
| `web-dmz` | HTTPS web server in the DMZ | 10.10.2.10 |
| `client-a` | Admin workstation: hosts the CA, receives all syslog | 10.10.1.10 |
| `client-b` | User workstation at Site B | 10.20.1.10 |

Each VM has a NAT adapter used only for management ssh from the host (its default route is disabled); all lab traffic uses
VirtualBox *internal networks* (`wan`, `lan-a`, `dmz`, `lan-b`). Host: Windows 11, VirtualBox 7.2, Ubuntu Server 26.04.1 LTS guests.

## What was built and how it was verified

| # | Component | Result | Evidence |
|---|---|---|---|
| 1 | Segmented routed network (LAN-A, DMZ, LAN-B, WAN) | `client-a` reaches `client-b` across `gw-a → WAN → gw-b` | [`01-baseline-connectivity.txt`](evidence/01-baseline-connectivity.txt) |
| 2 | Stateful **default-deny firewall** (iptables) | Only ICMP echo and tcp/443 to the web server are allowed; the DMZ cannot initiate connections; nmap shows `80/22 filtered`, `443 open` | [`02-firewall-tests.txt`](evidence/02-firewall-tests.txt) |
| 3 | **Private PKI** (OpenSSL): root CA → intermediate CA (pathlen 0) → server certificate with SAN | Without the CA `curl` fails (`unable to get local issuer certificate`); with the root CA it verifies (TLS 1.3); a **revoked** certificate is rejected via the CRL (`error 23: certificate revoked`) | [`03-pki-tests.txt`](evidence/03-pki-tests.txt) |
| 4 | **Site-to-site WireGuard VPN** | Before: the string `SECRET!!` is readable on the WAN. After: the WAN carries only `udp/51820` ciphertext, the string appears **0 times**; inside `wg0` the traffic is plaintext | [`04a`](evidence/04a-before-vpn-plaintext-capture.txt), [`04b`](evidence/04b-after-vpn-tests.txt) |
| 5 | End-to-end policy | `client-b` fetches `https://web.lab.local` over the tunnel with a verified certificate; ssh and other ports are dropped | [`05-end-to-end-tests.txt`](evidence/05-end-to-end-tests.txt) |
| 6 | **Suricata IDS** + **central syslog** (rsyslog/tcp) | Custom rules detect SYN scans, ping bursts and ssh probes; alerts and the firewall's `FW-DROP` messages from all hosts land in `/var/log/remote/<host>/` on the collector | [`06-ids-and-logging.txt`](evidence/06-ids-and-logging.txt) |
| 7 | Branch egress filtering | A port scan from Site B is dropped by `gw-b` *before* it enters the tunnel and is visible in the central log | [`07-site-b-scan-blocked-at-gw-b.txt`](evidence/07-site-b-scan-blocked-at-gw-b.txt) |

## Design decisions (the "why")

- **Default-deny, stateful rules.** `INPUT` and `FORWARD` default to `DROP`; only `ESTABLISHED,RELATED` plus an explicit allow-list pass.
  Everything else hits a rate-limited `LOG` chain so the log cannot be flooded. A deny-by-default policy fails closed when a rule is forgotten.
- **The DMZ never initiates.** If the web server is compromised, it cannot open connections into the LAN or Site B (verified).
  The only exception is syslog (tcp/514) to the collector, written as an explicit rule.
- **Accept Site B traffic only from `wg0`.** Rules matching `10.20.1.0/24` are bound to the tunnel interface, so a forged packet with a
  Site-B source address arriving from the WAN cannot match them.
- **Egress filtering at both gateways.** Branch users may reach only what policy allows, which stops reconnaissance before it crosses the tunnel.
- **PKI layout.** The root CA signs only the intermediate; the intermediate (pathlen 0) signs leaf certificates. The web server generates **its own**
  private key and sends only a CSR to the CA, so the key never travels. The CA lives on the admin workstation, not on the internet-facing server.
  Leaf certificates carry a SAN (`DNS:web.lab.local`, `IP:10.10.2.10`) because modern clients ignore the CN.
- **WireGuard.** Private keys are generated on the gateways and never leave them; only public keys and a pre-shared key (extra symmetric layer) are exchanged.
  `AllowedIPs` acts as cryptokey routing: each peer can only inject traffic for its own networks.
- **Central logging.** Logs are forwarded over tcp with a disk-assisted queue, so a collector outage does not lose messages and an attacker who wipes a
  compromised host's local logs cannot erase what was already shipped.

## Repository layout

```
scripts/     numbered build scripts (01 base VM … 08 syslog + IDS), run in order from the host
configs/     firewall rule sets (rules.v4), WireGuard configs (secrets redacted), public certificates
evidence/    raw output of every test shown above
docs/        build notes and troubleshooting
```

Secrets (`.lab-credentials`, `.keys/`, CA private keys, VM disks) are excluded by `.gitignore`. The WireGuard configs in `configs/` have
`PrivateKey` and `PresharedKey` replaced by `<redacted>`.

## Reproduce

1. Install VirtualBox, download the Ubuntu Server 26.04.1 LTS ISO, then run `scripts/01-create-base-vm.sh` and follow [`docs/build-notes.md`](docs/build-notes.md).
2. Run the scripts in order: `02-clone-and-wire.sh`, `03-provision-base.sh` (inside the base VM), `04-configure-network.sh`, `05-firewall.sh`,
   `06-pki.sh`, `07-wireguard.sh`, `08-syslog-ids.sh`.
3. Compare your output with the files in `evidence/`.

## Limitations (what this lab is not)

- CA private keys are unencrypted so the lab can be rebuilt unattended. A real root CA key is encrypted and kept offline.
- Suricata uses three **custom** rules for scan detection; it does not load a full commercial/community ruleset (the gateways have no internet route by design).
- Single gateway per site: no high availability, no BGP/OSPF; static routing only.
- Logs are sent over plain tcp inside the trusted lab network. A production setup would use TLS (RELP/TLS) for log transport.
- The firewall is IPv4 only; IPv6 is not part of this lab.
- This is a learning lab on virtual networks; it has not been security-audited.

## Troubleshooting log (honest notes)

These problems occurred while building the lab and are documented in [`docs/build-notes.md`](docs/build-notes.md): a VirtualBox hang with the
default VM settings on a Hyper-V host, a missing `openssh-server` after the unattended install, a stale `cdrom` apt source, and sshd host keys that
must be regenerated for every clone.
