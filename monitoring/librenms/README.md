# LibreNMS on srv01 (extension)

Follows the official install guide (https://docs.librenms.org/Installation/Install-LibreNMS/)
for Ubuntu 22.04 with Nginx. Give the VM at least 3 GB RAM first:

```bash
VBoxManage modifyvm ENL-Ubuntu-Server --memory 3072
```

LibreNMS listens on port 8000 so that the intranet site keeps port 80:

```nginx
server {
    listen 8000;
    server_name nms.corp.lab;
    root /opt/librenms/html;
    index index.php;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ [^/]\.php(/|$) {
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi.conf;
    }
}
```

Open the port only to the Admin VLAN:

```bash
sudo ufw allow from 192.168.10.0/24 to any port 8000 proto tcp comment 'LibreNMS from Admin VLAN'
```

Add the lab devices with the same SNMPv3 credentials as the test suite:

```bash
source /root/lab-secrets.env
for h in 192.168.99.1 192.168.199.1 192.168.99.2 192.168.199.2 127.0.0.1; do
  sudo -u librenms lnms device:add --v3 --seclevel authPriv --authname monitor \
    --authproto SHA --authpass "$SNMP_AUTH" --privproto AES --privpass "$SNMP_PRIV" "$h"
done
```

Alert rule for the WAN test: **Devices → Alert rules → "Port status up/down"**, scoped to `g0-1`
(Cisco: `GigabitEthernet0/1`). Run the WAN failure test (T09) and screenshot the alert history
into `screenshots/`.
