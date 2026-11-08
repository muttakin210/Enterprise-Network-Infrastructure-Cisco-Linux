#!/usr/bin/env bash
# UFW policy for srv01.corp.lab (guide section 6 starter policy, tightened per service).
# Run as root. Safe to re-run: it resets UFW and rebuilds the rule set.
set -euo pipefail

LAB=192.168.0.0/16          # all lab VLANs
VBOX_NAT=10.0.2.0/24        # VirtualBox NAT: Windows host reaches the VM via port forwards
DEVICES=(192.168.50.1 192.168.99.0/24 192.168.199.0/24 10.0.12.0/30)   # routers/switches (syslog sources)

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# Administration and web
ufw allow from "$LAB"      to any port 22 proto tcp comment 'SSH from lab'
ufw allow from "$VBOX_NAT" to any port 22 proto tcp comment 'SSH from VirtualBox host'
ufw allow from "$LAB"      to any port 80 proto tcp comment 'HTTP from lab'
ufw allow from "$VBOX_NAT" to any port 80 proto tcp comment 'HTTP from VirtualBox host'

# DNS
for src in "$LAB" "$VBOX_NAT"; do
  ufw allow from "$src" to any port 53 proto udp comment 'DNS'
  ufw allow from "$src" to any port 53 proto tcp comment 'DNS'
done

# DHCP: relayed requests arrive unicast from router interfaces
ufw allow from "$LAB" to any port 67 proto udp comment 'DHCP relay'

# Syslog and SNMP traps: only from network devices
for src in "${DEVICES[@]}"; do
  ufw allow from "$src" to any port 514 proto udp comment 'syslog from devices'
  ufw allow from "$src" to any port 514 proto tcp comment 'syslog from devices'
  ufw allow from "$src" to any port 162 proto udp comment 'SNMP traps from devices'
done
ufw allow from "$VBOX_NAT" to any port 514 proto udp comment 'syslog test from host'

# SNMP agent on this server: polled by the NMS (itself) and the host
ufw allow from 127.0.0.1   to any port 161 proto udp comment 'SNMP local NMS'
ufw allow from "$VBOX_NAT" to any port 161 proto udp comment 'SNMP from VirtualBox host'

ufw --force enable
ufw status verbose
