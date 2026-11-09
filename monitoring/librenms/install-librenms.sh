#!/usr/bin/env bash
# install-librenms.sh  -  LibreNMS on srv01 (Ubuntu 22.04), following the official guide
# https://docs.librenms.org/Installation/Install-LibreNMS/  (Nginx, PHP 8.4 from ppa:ondrej/php)
# Usage (on the VM, from the repo root):  sudo ./monitoring/librenms/install-librenms.sh
# Idempotent. Web UI on port 8000 so the intranet site keeps port 80.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
SECRETS=/root/lab-secrets.env
PHPV=8.4
TZ_NAME=Asia/Dhaka
log() { printf '\n=== %s ===\n' "$*"; }
gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

log "Secrets"
grep -q '^LIBRENMS_DB_PASS=' $SECRETS || echo "LIBRENMS_DB_PASS=$(gen)" >>$SECRETS
grep -q '^LIBRENMS_ADMIN_PASS=' $SECRETS || echo "LIBRENMS_ADMIN_PASS=$(gen)" >>$SECRETS
# shellcheck disable=SC1090
source $SECRETS

log "Packages (PHP $PHPV from ppa:ondrej/php: current LibreNMS needs PHP >= 8.4)"
export DEBIAN_FRONTEND=noninteractive
if ! ls /etc/apt/sources.list.d/ | grep -q ondrej; then
  apt-get install -y -q software-properties-common
  add-apt-repository -y ppa:ondrej/php
fi
apt-get update -q
apt-get install -y -q acl curl fping git graphviz imagemagick mariadb-client mariadb-server \
  mtr-tiny nginx-full nmap php$PHPV-cli php$PHPV-curl php$PHPV-fpm php$PHPV-gd php$PHPV-gmp \
  php$PHPV-mbstring php$PHPV-mysql php$PHPV-snmp php$PHPV-xml php$PHPV-zip rrdtool snmp unzip \
  python3-pymysql python3-dotenv python3-redis python3-setuptools python3-psutil python3-systemd \
  python3-pip whois traceroute
update-alternatives --set php /usr/bin/php$PHPV

log "User and code"
id librenms &>/dev/null || useradd librenms -d /opt/librenms -M -r -s /bin/bash
[[ -d /opt/librenms/.git ]] || git clone -q https://github.com/librenms/librenms.git /opt/librenms
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
sudo -u librenms -H bash -c 'cd /opt/librenms && ./scripts/composer_wrapper.php install --no-dev -q'
# Python poller/dispatcher wrapper dependencies (user site, as in the official guide)
sudo -u librenms -H pip3 install --user -q -r /opt/librenms/requirements.txt
LDIRS=(/opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache /opt/librenms/storage)
install -d -o librenms -g librenms "${LDIRS[@]}"
setfacl -d -m g::rwx "${LDIRS[@]}"
setfacl -R -m g::rwx "${LDIRS[@]}"

log "PHP timezone"
for f in /etc/php/$PHPV/fpm/php.ini /etc/php/$PHPV/cli/php.ini; do
  sed -i "s|^;\?date.timezone =.*|date.timezone = $TZ_NAME|" "$f"
done
timedatectl set-timezone $TZ_NAME

log "MariaDB"
cat >/etc/mysql/mariadb.conf.d/60-librenms.cnf <<'EOF'
[mysqld]
innodb_file_per_table=1
lower_case_table_names=0
bind-address=127.0.0.1
EOF
systemctl enable mariadb && systemctl restart mariadb
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '$LIBRENMS_DB_PASS';
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '$LIBRENMS_DB_PASS';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

log "PHP-FPM pool"
sed -e 's/^\[www\]/[librenms]/' -e 's/^user = .*/user = librenms/' -e 's/^group = .*/group = librenms/' \
    -e "s|^listen = .*|listen = /run/php-fpm-librenms.sock|" \
    /etc/php/$PHPV/fpm/pool.d/www.conf >/etc/php/$PHPV/fpm/pool.d/librenms.conf
systemctl enable php$PHPV-fpm && systemctl restart php$PHPV-fpm

log "Nginx site on :8000"
install -m 644 "$(dirname "$0")/nginx-librenms.conf" /etc/nginx/sites-available/librenms
ln -sf /etc/nginx/sites-available/librenms /etc/nginx/sites-enabled/librenms
nginx -t && systemctl reload nginx

log "Database schema, config and admin user"
cd /opt/librenms
env_set() { grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >>.env; }
env_set DB_HOST localhost; env_set DB_DATABASE librenms; env_set DB_USERNAME librenms
env_set DB_PASSWORD "$LIBRENMS_DB_PASS"; env_set APP_URL http://nms.corp.lab:8000
chown librenms:librenms .env; chmod 640 .env
# Laravel encryption key (the web installer normally creates it)
grep -q '^APP_KEY=base64:' .env || sudo -u librenms php artisan key:generate --force -q
sudo -u librenms ./lnms migrate --force -q
sudo -u librenms ./lnms db:seed --force -q || true
sudo -u librenms ./lnms config:set snmp.version '["v3"]' >/dev/null || true
sudo -u librenms ./lnms config:set rrd.step 300 >/dev/null || true
sudo -u librenms ./lnms user:add --role=admin --password="$LIBRENMS_ADMIN_PASS" \
  --email=netadmin@corp.lab admin 2>/dev/null || true
env_set INSTALL false

log "Scheduler, logrotate, CLI completion"
cp -f /opt/librenms/dist/librenms.cron /etc/cron.d/librenms 2>/dev/null || true
if [[ -f /opt/librenms/dist/librenms-scheduler.service ]]; then
  cp -f /opt/librenms/dist/librenms-scheduler.{service,timer} /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now librenms-scheduler.timer
fi
cp -f /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
ln -sf /opt/librenms/lnms /usr/bin/lnms
cp -f /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/ 2>/dev/null || true

log "Firewall: LibreNMS only from the Admin VLAN (and the VirtualBox NAT host for the lab)"
ufw allow from 192.168.10.0/24 to any port 8000 proto tcp comment 'LibreNMS from Admin VLAN'
ufw allow from 10.0.2.2 to any port 8000 proto tcp comment 'LibreNMS via VirtualBox NAT (host only)'

log "Add the lab devices (SNMPv3 authPriv, same credentials as the test suite)"
for h in 127.0.0.1 192.168.99.1 192.168.199.1 192.168.99.2 192.168.199.2; do
  # authPriv = user + SHA auth password + AES privacy password
  sudo -u librenms ./lnms device:add --v3 --security-name=monitor \
    --auth-protocol=SHA --auth-password="$SNMP_AUTH" \
    --privacy-protocol=AES --privacy-password="$SNMP_PRIV" \
    --port-association-mode=ifName "$h" 2>&1 | tail -2 || true
done

log "Validate"
sudo -u librenms ./validate.php || true
