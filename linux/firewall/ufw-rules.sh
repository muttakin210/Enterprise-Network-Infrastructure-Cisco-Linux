#!/usr/bin/env bash
# UFW policy for srv01.corp.lab (guide section 6 starter policy, tightened per service).
# Run as root. Safe to re-run: it resets UFW and rebuilds the rule set.
set -euo pipefail

LAB=192.168.0.0/16          # all lab VLANs
VBOX_NAT=10.0.2.0/24        # VirtualBox NAT: Windows host reaches the VM via port forwards
DEVICES=(192.168.50.1 192.168.99.0/24 192.168.199.0/24 10.0.12.0/30)   # routers/switches (syslog sources)
VPN=10.99.0.0/24            # WireGuard remote-admin pool (terminated on HQ-R1)
ADMIN=192.168.10.0/24       # Admin VLAN

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# Administration and web
ufw allow from "$LAB"      to any port 22 proto tcp comment 'SSH from lab'
ufw allow from "$VBOX_NAT" to any port 22 proto tcp comment 'SSH from VirtualBox host'
ufw allow from "$LAB"      to any port 80 proto tcp comment 'HTTP from lab'
ufw allow from "$VBOX_NAT" to any port 80 proto tcp comment 'HTTP from VirtualBox host'
ufw allow from "$VPN"      to any port 22 proto tcp comment 'SSH from WireGuard admins'
ufw allow from "$VPN"      to any port 80 proto tcp comment 'HTTP from WireGuard admins'

# Monitoring / IPAM web UIs: Admin VLAN and VPN admins only
ufw allow from "$ADMIN"    to any port 8000 proto tcp comment 'LibreNMS from Admin VLAN'
ufw allow from "$VPN"      to any port 8000 proto tcp comment 'LibreNMS from WireGuard admins'
ufw allow from 10.0.2.2    to any port 8000 proto tcp comment 'LibreNMS via VirtualBox NAT (host only)'

# Zabbix 8081, NetBox 8082, Grafana 3000: same audience as LibreNMS
for p in 8081:Zabbix 8082:NetBox 3000:Grafana; do
  ufw allow from "$ADMIN"   to any port "${p%%:*}" proto tcp comment "${p#*:} from Admin VLAN"
  ufw allow from "$VPN"     to any port "${p%%:*}" proto tcp comment "${p#*:} from WireGuard admins"
  ufw allow from 10.0.2.2   to any port "${p%%:*}" proto tcp comment "${p#*:} via VirtualBox NAT (host only)"
done

# DNS
for src in "$LAB" "$VBOX_NAT" "$VPN"; do
  ufw allow from "$src" to any port 53 proto udp comment 'DNS'
  ufw allow from "$src" to any port 53 proto tcp comment 'DNS'
done

# DHCP: relayed requests arrive unicast from router interfaces
ufw allow from "$LAB" to any port 67 proto udp comment 'DHCP relay'
# BR-R2 relays from its upstream (WAN) interface, so requests arrive from 10.0.12.2
ufw allow from 10.0.12.0/30 to any port 67 proto udp comment 'DHCP relay via WAN'

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
