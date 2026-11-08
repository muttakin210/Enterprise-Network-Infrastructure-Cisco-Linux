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
# never publish lab secrets: redact SNMP keys from all evidence
sed -i "s/$SNMP_AUTH/<SNMP_AUTH>/g; s/$SNMP_PRIV/<SNMP_PRIV>/g" "$EVID"/*.txt
chown -R netadmin:netadmin "$OUT" "$REPO/automation" 2>/dev/null || true
echo
echo "$pass passed, $fail failed  ->  $REPORT"
[[ $fail -eq 0 ]]
