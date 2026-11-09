#!/usr/bin/env bash
# run-tests.sh  -  guide section 10 test plan, executed against the namespace
# emulation on srv01. Every command's real output is saved as evidence.
#   sudo ./testing/run-tests.sh            (emulation must be up: netns-lab.sh up)
set -u   # no pipefail: "cmd | grep -q" would fail on SIGPIPE
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/testing/results"
EVID="$OUT/evidence"
REPORT="$OUT/test-report.md"
mkdir -p "$EVID"
# shellcheck disable=SC1091
source /root/lab-secrets.env
SNMP=(-v3 -l authPriv -u monitor -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" -t 2 -r 1)
pass=0; fail=0; rows=()

n() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
can_ping()  { n "$1" ping -c 2 -W 1 -q "$2" >/dev/null 2>&1; }

# record ID "Test" "Procedure" "Expected" STATUS EVIDENCE_FILE
record() {
  local status=$5
  if [[ $status == PASS ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  rows+=("| $1 | $2 | $3 | $4 | **$status** | [$1](evidence/$6) |")
  printf '%-4s %-5s %s\n' "$1" "$status" "$2"
}

ev() { echo "$EVID/$1"; }   # evidence path

# capture FILE CMD...  : run, keep the command line and its output
capture() {
  local f=$1; shift
  { echo "\$ $*"; "$@" 2>&1; echo; } >>"$f"
}

: >"$OUT/.started"
rm -f "$EVID"/*.txt

# ---------------------------------------------------------------- T01
f=$(ev T01-gateway-ping.txt); ok=PASS
for pair in admin-pc:192.168.10.1 it-pc:192.168.20.1 hr-pc:192.168.30.1 fin-pc:192.168.40.1; do
  pc=${pair%%:*}; gw=${pair#*:}
  capture "$f" ip netns exec "$pc" ping -c 2 -W 1 "$gw"
  can_ping "$pc" "$gw" || ok=FAIL
done
record T01 "Basic reachability" "Ping local gateway from each client" "Every gateway replies" $ok T01-gateway-ping.txt

# ---------------------------------------------------------------- T02
f=$(ev T02-dhcp-leases.txt); ok=PASS
for pair in admin-pc:192.168.10. it-pc:192.168.20. hr-pc:192.168.30. fin-pc:192.168.40.; do
  pc=${pair%%:*}; net=${pair#*:}
  capture "$f" ip netns exec "$pc" ip -4 addr show eth0
  capture "$f" ip netns exec "$pc" ip route
  capture "$f" ip netns exec "$pc" cat /etc/resolv.conf
  n "$pc" ip -4 -br addr show eth0 | grep -q "$net" || ok=FAIL
  n "$pc" ip route | grep -q "default via ${net}1" || ok=FAIL
done
capture "$f" tail -n 8 /var/lib/kea/kea-leases4.csv
record T02 "DHCP via relay" "Clients lease through ip helper-address (dhcrelay) to Kea" "Address from own VLAN pool, gateway .1, DNS 192.168.50.10" $ok T02-dhcp-leases.txt

# ---------------------------------------------------------------- T03
f=$(ev T03-ospf.txt); ok=PASS
for r in hq-r1 br-r2; do
  capture "$f" vtysh -N "$r" -c "show ip ospf neighbor"
  capture "$f" vtysh -N "$r" -c "show ip route ospf"
  vtysh -N "$r" -c "show ip ospf neighbor" | grep -q Full || ok=FAIL
done
vtysh -N hq-r1 -c "show ip route" | grep -q "O>\* 192.168.40.0/24" || ok=FAIL
vtysh -N br-r2 -c "show ip route" | grep -q "O>\* 192.168.50.0/24" || ok=FAIL
record T03 "OSPF" "show ip ospf neighbor / show ip route ospf" "Neighbor Full; remote LANs installed" $ok T03-ospf.txt

# ---------------------------------------------------------------- T04
f=$(ev T04-inter-vlan-and-wan.txt); ok=PASS
capture "$f" ip netns exec admin-pc ping -c 2 -W 1 192.168.20.1
capture "$f" ip netns exec it-pc traceroute -I -n -w 1 -q 1 -m 5 192.168.50.10
capture "$f" ip netns exec hr-pc traceroute -I -n -w 1 -q 1 -m 5 192.168.50.10
can_ping admin-pc "$(n it-pc ip -4 -br addr show eth0 | awk '{print $3}' | cut -d/ -f1)" || ok=FAIL
can_ping hr-pc 192.168.50.10 || ok=FAIL
can_ping it-pc 192.168.30.1 || ok=FAIL
n hr-pc traceroute -I -n -w 1 -q 1 -m 5 192.168.50.10 | grep -q "10.0.12.1" || ok=FAIL
record T04 "Inter-VLAN and inter-site routing" "Admin->IT, HR->server across the WAN, traceroute" "Permitted flows pass; path is BR-R2 -> 10.0.12.1 -> server" $ok T04-inter-vlan-and-wan.txt

# ---------------------------------------------------------------- T05
f=$(ev T05-web.txt); ok=PASS
for pc in admin-pc it-pc hr-pc fin-pc; do
  capture "$f" ip netns exec "$pc" curl -sS -o /dev/null -w "%{http_code} %{remote_ip} %{time_total}s\n" http://www.corp.lab/
  [[ $(n "$pc" curl -s -o /dev/null -w '%{http_code}' http://www.corp.lab/) == 200 ]] || ok=FAIL
done
capture "$f" curl -sI http://127.0.0.1/
record T05 "Web service" "curl http://www.corp.lab from every VLAN" "HTTP 200 from Nginx on 192.168.50.10" $ok T05-web.txt

# ---------------------------------------------------------------- T06
f=$(ev T06-dns.txt); ok=PASS
capture "$f" ip netns exec fin-pc dig +noall +answer srv01.corp.lab
capture "$f" ip netns exec fin-pc dig +noall +answer hq-r1.corp.lab br-sw1.corp.lab www.corp.lab
capture "$f" ip netns exec hr-pc dig +noall +answer -x 192.168.50.10
capture "$f" ip netns exec it-pc dig +short ubuntu.com
[[ $(n fin-pc dig +short srv01.corp.lab) == 192.168.50.10 ]] || ok=FAIL
n hr-pc dig +short -x 192.168.50.10 | grep -q srv01.corp.lab || ok=FAIL
record T06 "DNS" "dig corp.lab records (forward, reverse, recursive)" "Expected private IPs returned" $ok T06-dns.txt

# ---------------------------------------------------------------- T07
f=$(ev T07-acl-finance.txt); ok=PASS
FIN=$(n fin-pc ip -4 -br addr show eth0 | awk '{print $3}' | cut -d/ -f1)
echo "Finance client: $FIN" >>"$f"
capture "$f" ip netns exec it-pc ping -c 2 -W 1 "$FIN"
capture "$f" ip netns exec hr-pc ping -c 2 -W 1 "$FIN"
capture "$f" ip netns exec admin-pc ping -c 2 -W 1 "$FIN"
can_ping it-pc "$FIN"    && ok=FAIL
can_ping hr-pc "$FIN"    && ok=FAIL
can_ping admin-pc "$FIN" || ok=FAIL
capture "$f" ip netns exec br-r2 nft list chain ip cisco_acl finance_protect
record T07 "ACL FINANCE-PROTECT" "IT and HR ping a Finance host; Admin pings it" "IT/HR blocked with counters incrementing; Admin allowed" $ok T07-acl-finance.txt

# ---------------------------------------------------------------- T08
f=$(ev T08-acl-management.txt); ok=PASS
capture "$f" ip netns exec it-pc ping -c 2 -W 1 192.168.99.2
capture "$f" ip netns exec admin-pc ping -c 2 -W 1 192.168.99.2
capture "$f" ping -c 2 -W 1 192.168.199.2
can_ping it-pc 192.168.99.2     && ok=FAIL
can_ping admin-pc 192.168.99.2  || ok=FAIL
ping -c 2 -W 1 -q 192.168.199.2 >/dev/null || ok=FAIL
capture "$f" ip netns exec hq-r1 nft list chain ip cisco_acl mgmt_protect
record T08 "ACL MGMT-PROTECT" "Reach switch management SVIs from IT, Admin, server" "Only Admin VLAN and the server reach VLAN 99/199" $ok T08-acl-management.txt

# ---------------------------------------------------------------- T09
f=$(ev T09-wan-failure.txt); ok=PASS
before=$(wc -l </var/log/remote/HQ-R1.log 2>/dev/null || echo 0)
echo "## $(date -Is) shutdown WAN on HQ-R1 (ip link set g0-1 down)" >>"$f"
ip -n hq-r1 link set g0-1 down
sleep 3
capture "$f" vtysh -N hq-r1 -c "show ip ospf neighbor"
capture "$f" vtysh -N hq-r1 -c "show ip route ospf"
capture "$f" ip netns exec hr-pc ping -c 2 -W 1 192.168.50.10
vtysh -N hq-r1 -c "show ip ospf neighbor" | grep -q Full && ok=FAIL
can_ping hr-pc 192.168.50.10 && ok=FAIL
echo "## $(date -Is) restore WAN (ip link set g0-1 up)" >>"$f"
t0=$(date +%s.%N)
ip -n hq-r1 link set g0-1 up
for _ in $(seq 1 60); do
  vtysh -N hq-r1 -c "show ip ospf neighbor" | grep -q Full && break; sleep 0.5
done
t1=$(date +%s.%N)
for _ in $(seq 1 20); do can_ping hr-pc 192.168.50.10 && break; sleep 0.5; done
echo "OSPF re-converged in $(printf '%.1f' "$(echo "$t1 - $t0" | bc)") s" >>"$f"
capture "$f" vtysh -N hq-r1 -c "show ip ospf neighbor"
can_ping hr-pc 192.168.50.10 || ok=FAIL
sleep 2
echo "## Syslog received on srv01 during the test (/var/log/remote/HQ-R1.log)" >>"$f"
tail -n +"$((before+1))" /var/log/remote/HQ-R1.log | grep -iE "adj|nsm|ism" | head -20 >>"$f"
tail -n +"$((before+1))" /var/log/remote/HQ-R1.log | grep -qi "AdjChg" || ok=FAIL
record T09 "WAN failure" "Shut HQ-R1 G0/1, verify, restore" "Adjacency drops, branch unreachable, Syslog event logged, re-converges" $ok T09-wan-failure.txt

# ---------------------------------------------------------------- T10
f=$(ev T10-syslog.txt); ok=PASS
capture "$f" ls -l /var/log/remote/
capture "$f" tail -n 5 /var/log/remote/all-devices.log
ip netns exec br-r2 logger --udp -n 192.168.50.10 -P 514 -t "%LINK-3-UPDOWN" "BR-R2 test event: Interface GigabitEthernet0/0.40, changed state to down (controlled test)"
sleep 1
capture "$f" tail -n 2 /var/log/remote/all-devices.log
tail -n 5 /var/log/remote/all-devices.log | grep -q "10.0.12.2" || ok=FAIL
record T10 "Centralised Syslog" "Devices send to 192.168.50.10:514; controlled test event" "Per-device files in /var/log/remote with source IPs" $ok T10-syslog.txt

# ---------------------------------------------------------------- T11
f=$(ev T11-snmpv3.txt); ok=PASS
for ip in 192.168.99.1 192.168.199.1 192.168.99.2 192.168.199.2 127.0.0.1; do
  capture "$f" snmpget "${SNMP[@]}" "$ip" SNMPv2-MIB::sysName.0 SNMPv2-MIB::sysUpTime.0 SNMPv2-MIB::sysLocation.0
  snmpget "${SNMP[@]}" "$ip" SNMPv2-MIB::sysName.0 >/dev/null 2>&1 || ok=FAIL
done
capture "$f" snmpwalk "${SNMP[@]}" 192.168.99.1 IF-MIB::ifDescr
capture "$f" snmpwalk "${SNMP[@]}" 192.168.99.1 IF-MIB::ifOperStatus
echo "## negative test: SNMPv2c community 'public' must be refused" >>"$f"
capture "$f" snmpget -v2c -c public -t 1 -r 0 192.168.99.1 SNMPv2-MIB::sysName.0
snmpget -v2c -c public -t 1 -r 0 192.168.99.1 SNMPv2-MIB::sysName.0 >/dev/null 2>&1 && ok=FAIL
echo "## negative test: wrong v3 auth key must fail" >>"$f"
capture "$f" snmpget -v3 -l authPriv -u monitor -a SHA -A wrongpassword1 -x AES -X wrongpassword2 -t 1 -r 0 192.168.99.1 SNMPv2-MIB::sysName.0
record T11 "SNMPv3 monitoring" "snmpget/snmpwalk authPriv to all devices; v2c and bad keys" "v3 authPriv answers; v2c/wrong keys refused" $ok T11-snmpv3.txt

# ---------------------------------------------------------------- T12
f=$(ev T12-ansible-backup.txt); ok=PASS
rm -rf "$REPO/automation/ansible/backups/sanitized"
capture "$f" sudo -u netadmin -H bash -c "cd '$REPO/automation/ansible' && ansible-playbook -i inventory/emulation.yml playbooks/backup-emulation.yml"
capture "$f" ls -l "$REPO/automation/ansible/backups/sanitized/"
[[ -s $REPO/automation/ansible/backups/sanitized/HQ-R1.cfg && -s $REPO/automation/ansible/backups/sanitized/BR-R2.cfg ]] || ok=FAIL
grep -q "router ospf" "$REPO/automation/ansible/backups/sanitized/HQ-R1.cfg" || ok=FAIL
record T12 "Ansible backup" "ansible-playbook backup-emulation.yml" "Backups for routers and switches created, OSPF asserted Full" $ok T12-ansible-backup.txt

# ---------------------------------------------------------------- T13
f=$(ev T13-python-health-check.txt); ok=PASS
capture "$f" sudo -u netadmin -H python3 "$REPO/automation/python/health_check.py" \
  -o "$REPO/automation/python/results/health_log.csv"
sudo -u netadmin -H python3 "$REPO/automation/python/health_check.py" -o /tmp/hc.csv >/dev/null 2>&1 || ok=FAIL
record T13 "Python health check" "health_check.py: ping + TCP/22 to every device" "All devices reachable, CSV log written" $ok T13-python-health-check.txt

# ---------------------------------------------------------------- T14
f=$(ev T14-server-hardening.txt); ok=PASS
capture "$f" ufw status verbose
capture "$f" ss -tulpn
capture "$f" sshd -T
ufw status | grep -q "Status: active" || ok=FAIL
sshd -T | grep -q "permitrootlogin no" || ok=FAIL
record T14 "Server hardening" "UFW policy, listening sockets, sshd effective config" "UFW active default-deny; root SSH login disabled" $ok T14-server-hardening.txt

# ---------------------------------------------------------------- T15
f=$(ev T15-services.txt); ok=PASS
for s in ssh nginx named kea-dhcp4-server rsyslog snmpd; do
  capture "$f" systemctl --no-pager --lines=0 status "$s"
  systemctl is-active -q "$s" || ok=FAIL
done
record T15 "Linux services" "systemctl status of all server services" "All active (running)" $ok T15-services.txt

# ---------------------------------------------------------------- T16
# WireGuard (guide section 9, optional): handshake + permitted-route test
f=$(ev T16-wireguard.txt); ok=PASS
ip netns list | grep -q '^remote-admin' || bash "$REPO/testing/emulation/wireguard-lab.sh" up >/dev/null
WG=$REPO/testing/emulation/wireguard-lab.sh
echo "## Without the tunnel: the internet edge routes nothing into the LAN" >>"$f"
n remote-admin ip route add 192.168.50.10/32 via 203.0.113.1 dev eth0 2>/dev/null
n remote-admin ip route get 192.168.50.10 >>"$f" 2>&1
capture "$f" ip netns exec remote-admin ping -c 2 -W 1 192.168.50.10
can_ping remote-admin 192.168.50.10 && ok=FAIL
n remote-admin ip route del 192.168.50.10/32 via 203.0.113.1 dev eth0 2>/dev/null
echo "## Through the tunnel" >>"$f"
capture "$f" ip netns exec remote-admin ping -c 2 -W 1 10.99.0.1
capture "$f" bash "$WG" status
hs=$(n hq-r1 wg show wg0 latest-handshakes | awk '{print $2}')
echo "latest handshake: $hs ($(( $(date +%s) - ${hs:-0} )) s ago)" >>"$f"
[[ ${hs:-0} -gt 0 ]] || ok=FAIL
for ip in 192.168.50.10 192.168.99.2 192.168.199.2; do
  capture "$f" ip netns exec remote-admin ping -c 2 -W 1 "$ip"
  can_ping remote-admin "$ip" || ok=FAIL
done
capture "$f" ip netns exec remote-admin nc -zv -w 2 192.168.50.10 22
n remote-admin nc -z -w 2 192.168.50.10 22 || ok=FAIL
capture "$f" ip netns exec remote-admin curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://192.168.50.10/
echo "## Not permitted: Finance VLAN" >>"$f"
capture "$f" ip netns exec remote-admin ping -c 2 -W 1 192.168.40.100
can_ping remote-admin 192.168.40.100 && ok=FAIL
echo "## Client widens its own AllowedIPs/route: HQ-R1 VPN-FILTER still drops it" >>"$f"
peer=$(n remote-admin wg show wg0 peers)
n remote-admin wg set wg0 peer "$peer" allowed-ips 192.168.50.0/24,192.168.99.0/24,192.168.199.0/24,192.168.40.0/24
n remote-admin ip route add 192.168.40.0/24 dev wg0
capture "$f" ip netns exec remote-admin ping -c 2 -W 1 192.168.40.100
can_ping remote-admin 192.168.40.100 && ok=FAIL
n remote-admin ip route del 192.168.40.0/24 dev wg0
n remote-admin wg set wg0 peer "$peer" allowed-ips 192.168.50.0/24,192.168.99.0/24,192.168.199.0/24
capture "$f" ip netns exec hq-r1 nft list table ip vpn
capture "$f" vtysh -N br-r2 -c 'show ip route 10.99.0.0/24'
record T16 "WireGuard remote access" "Remote admin over the internet link: no VPN, VPN, permitted and denied routes" "Handshake; servers + mgmt reachable via tunnel; Finance and untunnelled traffic dropped" $ok T16-wireguard.txt

# ---------------------------------------------------------------- T17
f=$(ev T17-librenms.txt); ok=PASS
if [[ -d /opt/librenms ]]; then
  capture "$f" curl -s -o /dev/null -w 'login page HTTP %{http_code}\n' http://127.0.0.1:8000/login
  [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/login) == 200 ]] || ok=FAIL
  # LibreNMS >= 26.10 keeps SNMP credentials encrypted in `secrets`, linked via device_polling_methods
  V3SQL="FROM devices d JOIN device_polling_methods m ON m.device_id=d.device_id AND m.method_type='snmp' JOIN secrets s ON s.id=m.secret_id"
  capture "$f" mysql librenms -e "SELECT d.hostname, d.sysName, IF(d.status=1,'up','DOWN') AS status, s.secret_type AS snmp, m.last_check_successful AS snmp_ok, d.last_polled $V3SQL ORDER BY d.hostname"
  [[ $(mysql -N librenms -e "SELECT COUNT(*) $V3SQL WHERE d.status=1 AND s.secret_type='snmp-v3' AND m.last_check_successful=1") -ge 5 ]] || ok=FAIL
  capture "$f" mysql librenms -e "SELECT d.sysName, p.ifName, p.ifOperStatus FROM ports p JOIN devices d USING(device_id) WHERE p.ifName IN ('g0-1','g0-0.50','vlan99','vlan199') ORDER BY d.sysName"
  capture "$f" mysql librenms -e "SELECT datetime, d.sysName, e.type, e.message FROM eventlog e JOIN devices d USING(device_id) WHERE e.message LIKE '%ifOperStatus%' ORDER BY e.datetime DESC LIMIT 6"
else
  echo "LibreNMS not installed (monitoring/librenms/install-librenms.sh)" >>"$f"; ok=FAIL
fi
record T17 "LibreNMS (SNMPv3)" "Web UI, device inventory and port status polled over SNMPv3 authPriv" "Login page 200; 5 devices up via v3; port events logged" $ok T17-librenms.txt

# ---------------------------------------------------------------- T18
# Zabbix: availability over SNMPv3 / agent 2, then a WAN failure must open and close a problem
f=$(ev T18-zabbix.txt); ok=PASS
ZC="$REPO/monitoring/zabbix/zabbix-check.py"
export ZABBIX_ADMIN_PASS
capture "$f" curl -s -o /dev/null -w 'frontend HTTP %{http_code}\n' http://127.0.0.1:8081/
capture "$f" python3 "$ZC" hosts
python3 "$ZC" hosts >/dev/null || ok=FAIL
# T09 shuts g0-1 administratively; Zabbix LLD then disables the "lost" interface items until the
# next discovery. Refresh discovery first so the items are enabled again.
python3 "$ZC" poll hq-r1 'g0-1\(.*\): Operational status' >/dev/null; sleep 15
echo "## WAN failure from the far end (provider/cable fault): BR-R2 g0-1 down, HQ-R1 g0-1 stays admin up" >>"$f"
t0=$(date +%s)
n br-r2 ip link set g0-1 down
sleep 2
capture "$f" python3 "$ZC" poll hq-r1 'g0-1\(.*\): Operational status'
capture "$f" python3 "$ZC" problem hq-r1 'g0-1' --since "$t0" --timeout 150
python3 "$ZC" problem hq-r1 'g0-1' --since "$t0" --timeout 5 >/dev/null || ok=FAIL
echo "## Restore: link up, poll, problem must resolve" >>"$f"
n br-r2 ip link set g0-1 up
sleep 2
capture "$f" python3 "$ZC" poll hq-r1 'g0-1\(.*\): Operational status'
capture "$f" python3 "$ZC" problem hq-r1 'g0-1' --resolved --since "$t0" --timeout 150
python3 "$ZC" problem hq-r1 'g0-1' --resolved --since "$t0" --timeout 5 >/dev/null || ok=FAIL
sleep 20   # let OSPF re-converge before the next tests
record T18 "Zabbix (SNMPv3 + agent)" "Host availability; WAN carrier loss (far end down) seen on HQ-R1" "5 hosts available; 'Link down' problem opens, then resolves" $ok T18-zabbix.txt

# ---------------------------------------------------------------- T19
# NetBox: UI, and the import is idempotent (re-run gives the same counts)
f=$(ev T19-netbox.txt); ok=PASS
capture "$f" curl -s -o /dev/null -w 'login page HTTP %{http_code}\n' http://127.0.0.1:8082/login/
[[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/login/) == 200 ]] || ok=FAIL
echo "## Re-run the import (idempotent): object counts" >>"$f"
capture "$f" env NETBOX_ADMIN_PASS="$NETBOX_ADMIN_PASS" python3 "$REPO/ipam/netbox/import-lab.py" "$REPO/topology/addressing-plan.csv"
grep -qE '^dcim/devices +5$' "$f" || ok=FAIL
grep -qE '^dcim/cables +4$' "$f" || ok=FAIL
echo "## What NetBox documents (used by the Nmap audit)" >>"$f"
capture "$f" env NETBOX_ADMIN_PASS="$NETBOX_ADMIN_PASS" python3 "$REPO/ipam/netbox/nb-expected.py"
record T19 "NetBox IPAM/DCIM" "Import addressing plan, devices, interfaces, IPs and cables via API" "Login 200; 5 devices, 4 cables; re-run changes nothing" $ok T19-netbox.txt

# ---------------------------------------------------------------- T20
f=$(ev T20-grafana.txt); ok=PASS
capture "$f" curl -s http://127.0.0.1:3000/api/health
for ds in zabbix librenms; do
  capture "$f" curl -s -u "admin:$GRAFANA_ADMIN_PASS" "http://127.0.0.1:3000/api/datasources/uid/$ds/health"
  curl -s -u "admin:$GRAFANA_ADMIN_PASS" "http://127.0.0.1:3000/api/datasources/uid/$ds/health" | grep -q '"status":"OK"' || ok=FAIL
done
capture "$f" curl -s -u "admin:$GRAFANA_ADMIN_PASS" "http://127.0.0.1:3000/api/search?query=ENL"
curl -s -u "admin:$GRAFANA_ADMIN_PASS" "http://127.0.0.1:3000/api/dashboards/uid/enl-lab-overview" | grep -q '"uid":"enl-lab-overview"' || ok=FAIL
echo "## Anonymous access is refused" >>"$f"
capture "$f" curl -s -o /dev/null -w 'anonymous dashboard API HTTP %{http_code}\n' http://127.0.0.1:3000/api/dashboards/uid/enl-lab-overview
[[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/dashboards/uid/enl-lab-overview) == 401 ]] || ok=FAIL
record T20 "Grafana" "Health, both data sources (read-only accounts), provisioned dashboard" "Zabbix and LibreNMS data sources OK; dashboard present; anonymous 401" $ok T20-grafana.txt

# ---------------------------------------------------------------- T21
f=$(ev T21-nmap-audit.txt); ok=PASS
capture "$f" bash "$REPO/testing/nmap/nmap-audit.sh"
grep -q '^failed checks: 0$' "$f" || ok=FAIL
record T21 "Nmap audit" "Sweep vs NetBox; srv01 ports per VLAN; ACLs; internet edge; SNMP" "No undocumented hosts; UFW, ACLs and edge behave as designed" $ok T21-nmap-audit.txt

# ---------------------------------------------------------------- T22
f=$(ev T22-packet-capture.txt); ok=PASS
P="$REPO/testing/results/pcap"
capture "$f" bash "$REPO/testing/capture/capture-lab.sh"
tsh() { tshark -r "$P/$1.pcap" -Y "$2" 2>/dev/null | wc -l; }
{
  echo "## Assertions"
  echo "OSPF LS Update packets after the flap: $(tsh 01-ospf-adjacency 'ospf.msg == 4')"
  echo "DHCP relayed with giaddr 192.168.20.1:  $(tsh 02-dhcp-relay 'dhcp.ip.relay == 192.168.20.1')"
  echo "SNMPv3 encrypted PDUs:                  $(tsh 03-snmpv3-authpriv 'snmp.msgVersion == 3 && snmp.encryptedPDU')"
  echo "SNMP replies to v2c 'public':           $(tsh 03-snmpv3-authpriv 'snmp.community && ip.src == 192.168.99.1')"
  echo "WireGuard data packets on the internet: $(tsh 04-wireguard-outer 'wg.type == 4')"
  echo "ICMP visible on the internet link:      $(tsh 04-wireguard-outer 'icmp')"
  echo "ICMP inside the tunnel (wg0):           $(tsh 05-wireguard-inner 'icmp')"
  echo "Syslog readable on the wire:            $(tsh 06-syslog-plaintext 'syslog.msg contains "LINEPROTO"')"
} >>"$f"
(( $(tsh 01-ospf-adjacency 'ospf.msg == 4') > 0 )) || ok=FAIL
(( $(tsh 02-dhcp-relay 'dhcp.ip.relay == 192.168.20.1') > 0 )) || ok=FAIL
(( $(tsh 03-snmpv3-authpriv 'snmp.msgVersion == 3 && snmp.encryptedPDU') > 0 )) || ok=FAIL
(( $(tsh 03-snmpv3-authpriv 'snmp.community && ip.src == 192.168.99.1') == 0 )) || ok=FAIL
(( $(tsh 04-wireguard-outer 'wg.type == 4') > 0 )) || ok=FAIL
(( $(tsh 04-wireguard-outer 'icmp') == 0 )) || ok=FAIL
(( $(tsh 05-wireguard-inner 'icmp') > 0 )) || ok=FAIL
record T22 "Packet analysis (tshark/Wireshark)" "Capture OSPF, DHCP relay, SNMPv3, WireGuard and Syslog during real events" "OSPF LSUs; giaddr 192.168.20.1; SNMP encrypted; only UDP 51820 outside the tunnel" $ok T22-packet-capture.txt

# ---------------------------------------------------------------- report
{
  echo "# Test report"
  echo
  echo "Run: $(date -u '+%Y-%m-%d %H:%M UTC') on $(hostname -f) — Ubuntu $(lsb_release -rs), FRR $(vtysh -N hq-r1 -c 'show version' 2>/dev/null | awk '/FRRouting/{print $2; exit}' || true)"
  echo
  echo "Environment: namespace emulation of the guide topology (see [testing/emulation](../emulation/))."
  echo
  echo "**Result: $pass passed, $fail failed**"
  echo
  echo "| ID | Test | Procedure | Expected | Result | Evidence |"
  echo "|---|---|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
} >"$REPORT"
# never publish lab secrets: redact every value from /root/lab-secrets.env in all evidence
while IFS='=' read -r k v; do
  [[ -n $k && -n $v && $k != \#* ]] && sed -i "s|$v|<$k>|g" "$EVID"/*.txt "$OUT"/nmap/*.txt "$OUT"/pcap/*.txt 2>/dev/null
done </root/lab-secrets.env
chown -R netadmin:netadmin "$OUT" "$REPO/automation" 2>/dev/null || true
echo
echo "$pass passed, $fail failed  ->  $REPORT"
[[ $fail -eq 0 ]]
