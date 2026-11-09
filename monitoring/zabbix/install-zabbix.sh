#!/usr/bin/env bash
# install-zabbix.sh  -  Zabbix 8.0 LTS server + web UI + agent 2 on srv01 (Ubuntu 22.04)
# https://www.zabbix.com/download?zabbix=8.0&os_distribution=ubuntu&os_version=22.04&components=server_frontend_agent_2&db=mysql&ws=nginx
# Usage (on the VM, from the repo root):  sudo ./monitoring/zabbix/install-zabbix.sh
# Idempotent. Shares MariaDB and PHP 8.4 with LibreNMS; web UI on port 8081.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS=/root/lab-secrets.env
PHPV=8.4
log() { printf '\n=== %s ===\n' "$*"; }
gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

log "Secrets"
grep -q '^ZABBIX_DB_PASS=' $SECRETS    || echo "ZABBIX_DB_PASS=$(gen)" >>$SECRETS
grep -q '^ZABBIX_ADMIN_PASS=' $SECRETS || echo "ZABBIX_ADMIN_PASS=$(gen)" >>$SECRETS
# shellcheck disable=SC1090
source $SECRETS

log "Packages (official Zabbix 8.0 LTS repository)"
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s zabbix-release &>/dev/null; then
  curl -fsSL -o /tmp/zabbix-release.deb \
    https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_8.0+ubuntu22.04_all.deb
  dpkg -i /tmp/zabbix-release.deb
  apt-get update -q
fi
# php8.4-* first, so the php-* dependencies resolve to the PHP already used by LibreNMS
apt-get install -y -q php$PHPV-bcmath php$PHPV-ldap php$PHPV-mysql php$PHPV-mbstring php$PHPV-xml \
  php$PHPV-gd php$PHPV-curl php$PHPV-fpm
apt-get install -y -q zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2

log "Database"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';
ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EOF
if [[ $(mysql -N zabbix -e "SHOW TABLES LIKE 'users'" | wc -l) -eq 0 ]]; then
  mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"
  zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 zabbix
  mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
fi

log "Zabbix server (small lab: few pollers, small caches)"
zset() { local f=$1 k=$2 v=$3
  if grep -qE "^#? ?$k=" "$f"; then sed -i -E "s|^#? ?$k=.*|$k=$v|" "$f"; else echo "$k=$v" >>"$f"; fi; }
Z=/etc/zabbix/zabbix_server.conf
zset $Z DBHost localhost; zset $Z DBName zabbix; zset $Z DBUser zabbix; zset $Z DBPassword "$ZABBIX_DB_PASS"
zset $Z StartPollers 5; zset $Z StartPingers 2; zset $Z StartDiscoverers 2
zset $Z CacheSize 32M; zset $Z HistoryCacheSize 16M; zset $Z ValueCacheSize 32M
# Zabbix 8.0 wants MariaDB >= 10.11; Ubuntu 22.04 ships 10.6, shared with LibreNMS.
# Documented override (see docs/limitations.md). On a new build use Ubuntu 24.04 (MariaDB 10.11).
zset $Z AllowUnsupportedDBVersions 1
chmod 640 $Z; chgrp zabbix $Z

log "Agent 2 on srv01"
A=/etc/zabbix/zabbix_agent2.conf
zset $A Server 127.0.0.1; zset $A ServerActive 127.0.0.1; zset $A Hostname srv01.corp.lab

log "Web frontend on :8081 (no setup wizard)"
sed -i -E "s|^#? *listen +[0-9]+;|        listen          8081;|; s|^#? *server_name +.*;|        server_name     zabbix.corp.lab _;|" /etc/zabbix/nginx.conf
F=/etc/zabbix/web/zabbix.conf.php
sed -e "s|^\$DB\['PASSWORD'\].*|\$DB['PASSWORD'] = '$ZABBIX_DB_PASS';|" \
    -e "s|^\$ZBX_SERVER_NAME.*|\$ZBX_SERVER_NAME = 'corp.lab';|" \
    /usr/share/zabbix/ui/conf/zabbix.conf.php.example >$F
chown www-data:www-data $F; chmod 640 $F
sed -i "s|^; *php_value\[date.timezone\].*|php_value[date.timezone] = Asia/Dhaka|" /etc/zabbix/php-fpm.conf
nginx -t
systemctl enable zabbix-server zabbix-agent2 php$PHPV-fpm nginx
systemctl restart zabbix-server zabbix-agent2 php$PHPV-fpm nginx

log "Firewall: UI only from the Admin VLAN, VPN admins and the VirtualBox host"
ufw allow from 192.168.10.0/24 to any port 8081 proto tcp comment 'Zabbix from Admin VLAN'
ufw allow from 10.99.0.0/24    to any port 8081 proto tcp comment 'Zabbix from WireGuard admins'
ufw allow from 10.0.2.2        to any port 8081 proto tcp comment 'Zabbix via VirtualBox NAT (host only)'

log "Wait for the API"
for _ in $(seq 30); do
  curl -fs -o /dev/null -H 'Content-Type: application/json-rpc' \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
    http://127.0.0.1:8081/api_jsonrpc.php && break
  sleep 2
done

log "Configure through the API: admin password, SNMPv3 secret macros, lab hosts"
ZABBIX_ADMIN_PASS="$ZABBIX_ADMIN_PASS" SNMP_AUTH="$SNMP_AUTH" SNMP_PRIV="$SNMP_PRIV" \
  python3 "$HERE/zabbix-configure.py"

echo "zabbix-server: $(systemctl is-active zabbix-server)"
