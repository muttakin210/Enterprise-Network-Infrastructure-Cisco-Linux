#!/usr/bin/env bash
# setup-server.sh  -  build srv01.corp.lab from this repository (guide sections 6-8).
# Usage (on the Ubuntu VM, from the repo root):  sudo ./linux/setup-server.sh
# Idempotent: safe to re-run after editing any config in linux/.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
L="$REPO/linux"
SECRETS=/root/lab-secrets.env      # generated once, never committed

log() { printf '\n=== %s ===\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

log "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q openssh-server nginx bind9 bind9-utils dnsutils \
  kea-dhcp4-server tcpdump snmp snmpd libsnmp-dev rsyslog python3 python3-pip python3-venv \
  git curl traceroute nftables frr isc-dhcp-relay isc-dhcp-client ansible sshpass jq bc snmp-mibs-downloader
# load the standard MIBs so tools show names (sysName.0) instead of numeric OIDs
sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf
# FRR and dhcrelay run only inside the emulated routers (testing/emulation), not on the server
systemctl disable --now frr isc-dhcp-relay 2>/dev/null || true

log "Lab secrets"
if [[ ! -f $SECRETS ]]; then
  gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
  umask 077
  cat >"$SECRETS" <<EOF
SNMP_AUTH=$(gen)
SNMP_PRIV=$(gen)
EOF
fi
# shellcheck disable=SC1090
source "$SECRETS"

log "Netplan (br-vlan50 = 192.168.50.10/24)"
install -m 600 "$L/netplan/50-lab.yaml" /etc/netplan/50-lab.yaml
# remove the installer's default config so enp0s8 is only defined once
for f in /etc/netplan/00-installer-config.yaml /etc/netplan/50-cloud-init.yaml; do
  [[ -f $f ]] && mv "$f" "$f.disabled"
done
netplan generate && netplan apply
sleep 3

log "Nginx"
install -d /var/www/corp-lab
install -m 644 "$L/nginx/index.html" /var/www/corp-lab/index.html
install -m 644 "$L/nginx/corp-lab.conf" /etc/nginx/sites-available/corp-lab
ln -sf /etc/nginx/sites-available/corp-lab /etc/nginx/sites-enabled/corp-lab
rm -f /etc/nginx/sites-enabled/default
sed -i 's/^\s*#\?\s*server_tokens.*/\tserver_tokens off;/' /etc/nginx/nginx.conf
nginx -t && systemctl enable --now nginx && systemctl reload nginx

log "BIND9 (corp.lab)"
install -d -o root -g bind -m 2755 /etc/bind/zones
install -m 644 "$L/dns/named.conf.options" /etc/bind/named.conf.options
install -m 644 "$L/dns/named.conf.local"   /etc/bind/named.conf.local
install -m 644 "$L/dns/db.corp.lab"        /etc/bind/zones/db.corp.lab
install -m 644 "$L/dns/db.192.168"         /etc/bind/zones/db.192.168
named-checkconf
named-checkzone corp.lab /etc/bind/zones/db.corp.lab
named-checkzone 168.192.in-addr.arpa /etc/bind/zones/db.192.168
systemctl enable named && systemctl restart named
# this host resolves through its own BIND
sed -i 's/^#\?DNS=.*/DNS=127.0.0.1/; s/^#\?Domains=.*/Domains=corp.lab/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved

log "Kea DHCPv4"
install -m 640 -g _kea "$L/dhcp/kea-dhcp4.conf" /etc/kea/kea-dhcp4.conf
kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
systemctl enable kea-dhcp4-server && systemctl restart kea-dhcp4-server

log "rsyslog remote reception"
install -d -o syslog -g adm -m 750 /var/log/remote
install -m 644 "$L/syslog/10-remote-devices.conf" /etc/rsyslog.d/10-remote-devices.conf
rsyslogd -N1 >/dev/null
systemctl restart rsyslog
cat >/etc/logrotate.d/remote-devices <<'EOF'
/var/log/remote/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

log "SNMPv3 agent"
install -m 600 "$L/snmp/snmpd.conf" /etc/snmp/snmpd.conf
systemctl stop snmpd
if ! grep -q 'usmUser.*monitor' /var/lib/snmp/snmpd.conf 2>/dev/null \
   && ! grep -q '"monitor"' /var/lib/snmp/snmpd.conf 2>/dev/null; then
  net-snmp-create-v3-user -ro -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" monitor >/dev/null
fi
systemctl enable snmpd && systemctl start snmpd

log "SSH hardening"
cat >/etc/ssh/sshd_config.d/10-lab-hardening.conf <<'EOF'
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowUsers netadmin
EOF
sshd -t && systemctl reload ssh

log "Kernel: no routing on the server itself"
cat >/etc/sysctl.d/90-lab.conf <<'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl --system >/dev/null

log "Automation account (Ansible / health checks)"
usermod -aG frrvty netadmin
if [[ ! -f /home/netadmin/.ssh/id_ed25519 ]]; then
  sudo -u netadmin ssh-keygen -q -t ed25519 -N "" -C "netadmin@srv01-automation" -f /home/netadmin/.ssh/id_ed25519
fi
grep -qF "$(cat /home/netadmin/.ssh/id_ed25519.pub)" /home/netadmin/.ssh/authorized_keys 2>/dev/null \
  || cat /home/netadmin/.ssh/id_ed25519.pub >>/home/netadmin/.ssh/authorized_keys
chown netadmin:netadmin /home/netadmin/.ssh/authorized_keys; chmod 600 /home/netadmin/.ssh/authorized_keys
# bridged frames must not traverse iptables/UFW (would drop VLAN 50 traffic to the emulation)
sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true

log "UFW"
bash "$L/firewall/ufw-rules.sh"

log "Service status"
for s in ssh nginx named kea-dhcp4-server rsyslog snmpd; do
  printf '%-18s %s\n' "$s" "$(systemctl is-active "$s")"
done
