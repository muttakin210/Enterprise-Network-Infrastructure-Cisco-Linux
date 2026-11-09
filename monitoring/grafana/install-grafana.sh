#!/usr/bin/env bash
# install-grafana.sh  -  Grafana OSS on srv01 with Zabbix and LibreNMS as data sources
# https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/
# Usage (on the VM, from the repo root):  sudo ./monitoring/grafana/install-grafana.sh
# Needs install-zabbix.sh and install-librenms.sh first. Web UI on port 3000.
# Both data sources use dedicated read-only accounts; the dashboard is provisioned from this repo.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SECRETS=/root/lab-secrets.env
log() { printf '\n=== %s ===\n' "$*"; }
gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

log "Secrets"
for k in GRAFANA_ADMIN_PASS GRAFANA_ZBX_PASS GRAFANA_DB_PASS; do
  grep -q "^$k=" $SECRETS || echo "$k=$(gen)" >>$SECRETS
done
# shellcheck disable=SC1090
source $SECRETS

log "Package (official Grafana APT repository)"
export DEBIAN_FRONTEND=noninteractive
if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    >/etc/apt/sources.list.d/grafana.list
  apt-get update -q
fi
apt-get install -y -q grafana

log "Zabbix plugin"
grafana cli plugins ls 2>/dev/null | grep -q alexanderzobnin-zabbix-app \
  || grafana cli plugins install alexanderzobnin-zabbix-app

log "Read-only accounts: Zabbix API user 'grafana', MariaDB user 'grafana_ro' on librenms"
ZABBIX_ADMIN_PASS="$ZABBIX_ADMIN_PASS" SNMP_AUTH="$SNMP_AUTH" SNMP_PRIV="$SNMP_PRIV" \
  GRAFANA_ZBX_PASS="$GRAFANA_ZBX_PASS" python3 "$REPO/monitoring/zabbix/zabbix-configure.py" | tail -1
mysql -uroot <<EOF
CREATE USER IF NOT EXISTS 'grafana_ro'@'localhost' IDENTIFIED BY '$GRAFANA_DB_PASS';
ALTER USER 'grafana_ro'@'localhost' IDENTIFIED BY '$GRAFANA_DB_PASS';
GRANT SELECT ON librenms.devices  TO 'grafana_ro'@'localhost';
GRANT SELECT ON librenms.ports    TO 'grafana_ro'@'localhost';
GRANT SELECT ON librenms.eventlog TO 'grafana_ro'@'localhost';
FLUSH PRIVILEGES;
EOF

log "grafana.ini: port 3000, no sign-up, no anonymous access"
G=/etc/grafana/grafana.ini
sed -i -E 's|^;?http_port = .*|http_port = 3000|; s|^;?allow_sign_up = .*|allow_sign_up = false|; s|^;?disable_gravatar = .*|disable_gravatar = true|; s|^;?reporting_enabled = .*|reporting_enabled = false|' $G
sed -i -E '/^\[auth.anonymous\]/,/^\[/ s|^;?enabled = .*|enabled = false|' $G

log "Provisioning (data sources, plugin, dashboard)"
P=/etc/grafana/provisioning
install -d $P/datasources $P/plugins $P/dashboards /var/lib/grafana/dashboards/enl
install -m 644 "$HERE/provisioning/plugins/zabbix.yaml"         $P/plugins/zabbix.yaml
install -m 644 "$HERE/provisioning/dashboards/enl.yaml"         $P/dashboards/enl.yaml
install -m 644 "$HERE/dashboards/enl-lab-overview.json"         /var/lib/grafana/dashboards/enl/
# data sources: secrets are filled in here and the result is readable only by grafana
sed -e "s|__GRAFANA_ZBX_PASS__|$GRAFANA_ZBX_PASS|" -e "s|__GRAFANA_DB_PASS__|$GRAFANA_DB_PASS|" \
  "$HERE/provisioning/datasources/enl.yaml" >$P/datasources/enl.yaml
chown root:grafana $P/datasources/enl.yaml; chmod 640 $P/datasources/enl.yaml

systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server
for _ in $(seq 60); do curl -fs -o /dev/null http://127.0.0.1:3000/api/health && break; sleep 2; done
grafana cli --homepath /usr/share/grafana --config $G admin reset-admin-password "$GRAFANA_ADMIN_PASS" >/dev/null 2>&1 \
  && echo "admin password set"

log "Firewall"
ufw allow from 192.168.10.0/24 to any port 3000 proto tcp comment 'Grafana from Admin VLAN'
ufw allow from 10.99.0.0/24    to any port 3000 proto tcp comment 'Grafana from WireGuard admins'
ufw allow from 10.0.2.2        to any port 3000 proto tcp comment 'Grafana via VirtualBox NAT (host only)'

log "Health"
curl -s http://127.0.0.1:3000/api/health; echo
for ds in zabbix librenms; do
  curl -s -u "admin:$GRAFANA_ADMIN_PASS" "http://127.0.0.1:3000/api/datasources/uid/$ds/health" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sys.argv[1], d.get("status"), d.get("message","")[:80])' $ds
done
