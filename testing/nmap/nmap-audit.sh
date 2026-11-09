#!/usr/bin/env bash
# nmap-audit.sh  -  network discovery and policy audit with Nmap, from inside the emulated lab.
#   sudo ./testing/nmap/nmap-audit.sh      (emulation, WireGuard and NetBox must be up)
#
# 1. Discovery  : ping sweep of every lab subnet from ADMIN-PC; every live host must be documented
#                 in NetBox (an IP address, or inside a DHCP range). Anything else = undocumented host.
# 2. Server     : srv01 ports seen from ADMIN-PC vs IT-PC (UFW: management UIs only from Admin VLAN)
# 3. ACLs       : IT-PC vs ADMIN-PC towards Finance and the switch management SVI
# 4. Edge       : what the internet (remote-admin namespace) sees on HQ-R1's internet interface
# 5. SNMP       : the agents answer SNMPv3 only
# Raw outputs go to testing/results/nmap/ (normal + XML). Exit code = number of failed checks.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/testing/results/nmap"
mkdir -p "$OUT"; rm -f "$OUT"/*
fails=0
n() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
check() {  # check "description" expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS  $1  ($3)"; else echo "FAIL  $1  (expected $2, got $3)"; fails=$((fails+1)); fi
}
state() {  # state NS TARGET PORT [proto] -> open|closed|filtered|open|filtered
  local proto=${4:-T}
  n "$1" nmap -n -Pn -s"$proto" -p "$3" --max-retries 1 --host-timeout 20s "$2" -oG - 2>/dev/null \
    | grep -oE "$3/[a-z|]+" | head -1 | cut -d/ -f2
}

echo "## 1. Discovery vs NetBox"
SUBNETS="192.168.10.0/24 192.168.20.0/24 192.168.50.0/24 192.168.99.0/24 192.168.30.0/24 192.168.40.0/24 192.168.199.0/24 10.0.12.0/30"
n admin-pc nmap -n -sn $SUBNETS -oN "$OUT/01-discovery.txt" -oX "$OUT/01-discovery.xml" >/dev/null
live=$(grep -oE "Nmap scan report for [0-9.]+" "$OUT/01-discovery.txt" | awk '{print $5}' | sort -V)
source /root/lab-secrets.env
NETBOX_ADMIN_PASS="$NETBOX_ADMIN_PASS" python3 "$REPO/ipam/netbox/nb-expected.py" >"$OUT/netbox-expected.txt"
ip2n() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
undocumented=0
{
  printf '%-16s %s\n' "LIVE HOST" "NETBOX"
  for h in $live; do
    doc=$(awk -v h="$h" '$1=="ip" && $2==h {print "ip " ($3?$3:"documented"); exit}' "$OUT/netbox-expected.txt")
    if [[ -z $doc ]]; then
      hn=$(ip2n "$h")
      while read -r _ s e; do
        (( hn >= $(ip2n "$s") && hn <= $(ip2n "$e") )) && { doc="in DHCP range $s-$e"; break; }
      done < <(grep '^range' "$OUT/netbox-expected.txt")
    fi
    [[ -z $doc ]] && { doc="UNDOCUMENTED"; undocumented=$((undocumented+1)); }
    printf '%-16s %s\n' "$h" "$doc"
  done
} | tee "$OUT/01-discovery-vs-netbox.txt"
check "live hosts: $(echo "$live" | wc -w); undocumented hosts" 0 "$undocumented"

echo; echo "## 2. srv01 services by source VLAN (UFW)"
PORTS=22,53,80,3000,8000,8081,8082
for src in admin-pc it-pc; do
  n $src nmap -n -Pn -sT -p $PORTS --max-retries 1 192.168.50.10 -oN "$OUT/02-srv01-from-$src.txt" >/dev/null
done
for p in 3000 8000 8081 8082; do
  check "ADMIN-PC -> srv01:$p" open "$(state admin-pc 192.168.50.10 $p)"
  check "IT-PC    -> srv01:$p" filtered "$(state it-pc 192.168.50.10 $p)"
done
check "IT-PC    -> srv01:80 (intranet web)" open "$(state it-pc 192.168.50.10 80)"

echo; echo "## 3. ACLs (FINANCE-PROTECT, MGMT-PROTECT)"
FIN=$(n fin-pc ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
for src in admin-pc it-pc; do
  n $src nmap -n -sn "$FIN" 192.168.99.2 192.168.199.2 -oN "$OUT/03-acl-from-$src.txt" >/dev/null
done
check "ADMIN-PC -> HQ-SW1 mgmt 192.168.99.2:22" open "$(state admin-pc 192.168.99.2 22)"
check "IT-PC    -> HQ-SW1 mgmt 192.168.99.2:22" filtered "$(state it-pc 192.168.99.2 22)"
alive() { grep -q "Host is up" <(n "$1" nmap -n -sn "$2" 2>/dev/null) && echo up || echo down; }
check "ADMIN-PC -> FIN-PC $FIN" up "$(alive admin-pc "$FIN")"
check "IT-PC    -> FIN-PC $FIN" down "$(alive it-pc "$FIN")"

echo; echo "## 4. Internet edge: HQ-R1 203.0.113.1 seen from the internet"
n remote-admin nmap -n -Pn -sT --top-ports 100 --max-retries 1 203.0.113.1 -oN "$OUT/04-edge-tcp.txt" >/dev/null
n remote-admin nmap -n -Pn -sU -p 51820,161,53 --max-retries 1 203.0.113.1 -oN "$OUT/04-edge-udp.txt" >/dev/null
open_tcp=$(grep -cE "^[0-9]+/tcp +open " "$OUT/04-edge-tcp.txt")
check "open TCP ports on the internet side (top 100)" 0 "$open_tcp"
# UDP + silent drop = no reply at all, which Nmap reports as "open|filtered" (a closed port would
# answer ICMP port-unreachable, a reachable agent would answer SNMP)
check "SNMP 161/udp from the internet (silently dropped)" "open|filtered" "$(state remote-admin 203.0.113.1 161 U)"

echo; echo "## 5. SNMP agents (UDP 161)"
n admin-pc nmap -n -Pn -sU -sV -p 161 --version-intensity 3 192.168.99.1 192.168.199.1 192.168.99.2 192.168.199.2 \
  -oN "$OUT/05-snmp.txt" >/dev/null
check "SNMP agents answering (SNMPv3 engine discovery)" 4 "$(grep -c '161/udp open' "$OUT/05-snmp.txt")"
n admin-pc nmap -n -Pn -sU -p 161 --script snmp-info 192.168.99.1 -oN "$OUT/05-snmp-v3-engine.txt" >/dev/null
check "v2c community 'public' refused" "no answer" \
  "$(n admin-pc snmpget -v2c -c public -t 1 -r 0 192.168.99.1 1.3.6.1.2.1.1.5.0 >/dev/null 2>&1 && echo answered || echo 'no answer')"

echo; echo "failed checks: $fails"
exit $fails
