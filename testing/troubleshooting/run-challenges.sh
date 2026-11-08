#!/usr/bin/env bash
# run-challenges.sh  -  guide section 10 "troubleshooting challenge checklist".
# Each challenge injects a real fault into the namespace emulation, captures the
# symptom and the diagnostic commands, applies the fix and verifies recovery.
# Output: testing/troubleshooting/TS-01.md ... TS-10.md and README.md (index)
#   sudo ./testing/troubleshooting/run-challenges.sh   (emulation must be up)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$REPO/testing/troubleshooting"
# shellcheck disable=SC1091
source /root/lab-secrets.env
SNMP=(-v3 -l authPriv -u monitor -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" -t 1 -r 0)
n() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
INDEX=()

# helpers to build one markdown record
start() { F="$DIR/$1.md"; ID=$1; TITLE=$2; { echo "# $1 — $2"; echo; echo "_Run $(date -u '+%Y-%m-%d %H:%M UTC') on the namespace emulation._"; echo; } >"$F"; }
para()  { { echo "$*"; echo; } >>"$F"; }
sect()  { echo "## $*" >>"$F"; echo >>"$F"; }
run()   { { echo '```'; echo "\$ $*"; timeout 20 "$@" 2>&1 | head -40; echo '```'; echo; } >>"$F"; }
finish() {  # finish PASS|FAIL "root cause"
  { echo "## Outcome"; echo; echo "**Root cause:** $2"; echo; echo "**Verified after fix:** $1"; } >>"$F"
  INDEX+=("| [$ID]($ID.md) | $TITLE | $2 | $1 |")
  printf '%s %-5s %s\n' "$ID" "$1" "$TITLE"
}
ping_ok() { n "$1" ping -c 2 -W 1 -q "$2" >/dev/null 2>&1; }
verdict() { if "$@"; then echo PASS; else echo FAIL; fi; }

# ------------------------------------------------------------------ TS-01
start TS-01 "PC cannot reach its default gateway"
para "**Fault injected:** ADMIN-PC's switch port (HQ-SW1 G0/1) moved to VLAN 20, as if someone typed \`switchport access vlan 20\` on the wrong port."
bridge -n hq-sw1 vlan del dev g0-1 vid 10; bridge -n hq-sw1 vlan add dev g0-1 vid 20 pvid untagged
sect "Symptom"; run ip netns exec admin-pc ping -c 2 -W 1 192.168.10.1
sect "Diagnosis (show vlan brief / show interfaces switchport equivalent)"
run bridge -n hq-sw1 vlan show dev g0-1
run ip netns exec admin-pc ip neigh show
para "The port's PVID is 20, but the PC is addressed in VLAN 10, so its ARP requests for 192.168.10.1 are flooded in VLAN 20 and never answered."
sect "Fix"; bridge -n hq-sw1 vlan del dev g0-1 vid 20; bridge -n hq-sw1 vlan add dev g0-1 vid 10 pvid untagged
run bridge -n hq-sw1 vlan show dev g0-1
run ip netns exec admin-pc ping -c 2 -W 1 192.168.10.1
finish "$(verdict ping_ok admin-pc 192.168.10.1)" "Access port in the wrong VLAN (PVID 20 instead of 10)."

# ------------------------------------------------------------------ TS-02
start TS-02 "VLAN 10 cannot communicate with VLAN 20"
para "**Fault injected:** HQ-R1 subinterface G0/0.20 administratively shut down."
ip -n hq-r1 link set g0-0.20 down
sect "Symptom"; run ip netns exec admin-pc ping -c 2 -W 1 192.168.20.1
sect "Diagnosis (show ip interface brief)"
run ip -n hq-r1 -br addr show
run vtysh -N hq-r1 -c "show ip route connected"
para "\`g0-0.20\` is DOWN, so 192.168.20.0/24 is no longer a connected route and inter-VLAN routing for VLAN 20 stops."
sect "Fix"; ip -n hq-r1 link set g0-0.20 up; sleep 1
run ip netns exec admin-pc ping -c 2 -W 1 192.168.20.1
finish "$(verdict ping_ok admin-pc 192.168.20.1)" "Router-on-a-stick subinterface for VLAN 20 was shut down."

# ------------------------------------------------------------------ TS-03
start TS-03 "Branch cannot reach HQ"
para "**Fault injected:** \`no network 192.168.50.0/24 area 0\` on HQ-R1, so the Servers VLAN is no longer advertised."
vtysh -N hq-r1 -c "conf t" -c "router ospf" -c "no network 192.168.50.0/24 area 0" >/dev/null; sleep 3
sect "Symptom"; run ip netns exec hr-pc ping -c 2 -W 1 192.168.50.10
sect "Diagnosis"
run vtysh -N br-r2 -c "show ip route 192.168.50.10"
run vtysh -N hq-r1 -c "show running-config ospfd"
para "BR-R2 has no route to 192.168.50.0/24 because HQ-R1 stopped advertising it. The adjacency is still Full, so this is a missing network statement, not a WAN fault."
sect "Fix"; vtysh -N hq-r1 -c "conf t" -c "router ospf" -c "network 192.168.50.0/24 area 0" >/dev/null
for _ in $(seq 1 20); do ping_ok hr-pc 192.168.50.10 && break; sleep 1; done
run vtysh -N br-r2 -c "show ip route 192.168.50.10"
run ip netns exec hr-pc ping -c 2 -W 1 192.168.50.10
finish "$(verdict ping_ok hr-pc 192.168.50.10)" "OSPF network statement for 192.168.50.0/24 missing on HQ-R1."

# ------------------------------------------------------------------ TS-04
start TS-04 "OSPF neighbor does not form"
para "**Fault injected:** OSPF hello/dead timers on BR-R2 G0/1 changed to 5/20 (HQ-R1 uses 10/40)."
vtysh -N br-r2 -c "conf t" -c "interface g0-1" -c "ip ospf hello-interval 5" -c "ip ospf dead-interval 20" >/dev/null
for _ in $(seq 1 50); do vtysh -N hq-r1 -c "show ip ospf neighbor" | grep -q Full || break; sleep 1; done
sect "Symptom"; run vtysh -N hq-r1 -c "show ip ospf neighbor"
sect "Diagnosis (show ip ospf interface)"
run bash -c "vtysh -N hq-r1 -c 'show ip ospf interface g0-1' | grep -E 'Timer|Hello'"
run bash -c "vtysh -N br-r2 -c 'show ip ospf interface g0-1' | grep -E 'Timer|Hello'"
para "The hello and dead intervals must match on both ends of a link. With 10/40 against 5/20, hellos are discarded and the adjacency never reaches Full."
sect "Fix"; vtysh -N br-r2 -c "conf t" -c "interface g0-1" -c "no ip ospf hello-interval" -c "no ip ospf dead-interval" >/dev/null
for _ in $(seq 1 60); do vtysh -N hq-r1 -c "show ip ospf neighbor" | grep -q Full && break; sleep 1; done
run vtysh -N hq-r1 -c "show ip ospf neighbor"
finish "$(verdict bash -c 'vtysh -N hq-r1 -c "show ip ospf neighbor" | grep -q Full')" "OSPF hello/dead interval mismatch on the WAN link."

# ------------------------------------------------------------------ TS-05
start TS-05 "Trunk does not carry a required VLAN"
para "**Fault injected:** VLAN 50 removed from the HQ-SW1 → HQ-R1 trunk (\`switchport trunk allowed vlan remove 50\`)."
bridge -n hq-sw1 vlan del dev g0-0 vid 50
sect "Symptom"; run ip netns exec it-pc ping -c 2 -W 1 192.168.50.10
sect "Diagnosis (show interfaces trunk)"
run bridge -n hq-sw1 vlan show dev g0-0
run ip neigh show dev br-vlan50
para "The trunk allows 10, 20 and 99 but not 50, so frames between the server and its gateway 192.168.50.1 are dropped at the switch."
sect "Fix"; bridge -n hq-sw1 vlan add dev g0-0 vid 50; sleep 1
run bridge -n hq-sw1 vlan show dev g0-0
run ip netns exec it-pc ping -c 2 -W 1 192.168.50.10
finish "$(verdict ping_ok it-pc 192.168.50.10)" "VLAN 50 pruned from the 802.1Q trunk."

# ------------------------------------------------------------------ TS-06
start TS-06 "Ubuntu DNS service is unreachable"
para "**Fault injected:** the UFW DNS rules for the lab networks are deleted."
ufw delete allow from 192.168.0.0/16 to any port 53 proto udp >/dev/null
ufw delete allow from 192.168.0.0/16 to any port 53 proto tcp >/dev/null
sect "Symptom"; run ip netns exec fin-pc dig +time=2 +tries=1 srv01.corp.lab
sect "Diagnosis"
run bash -c "ss -ulpn | grep ':53 '"
run bash -c "ufw status | grep -E '53|Status'"
run bash -c "timeout 4 tcpdump -ni br-vlan50 -c 2 udp port 53 & sleep 1; ip netns exec fin-pc dig +time=1 +tries=1 srv01.corp.lab >/dev/null; wait"
para "named is listening and queries reach br-vlan50 (tcpdump), but no reply is sent. UFW has no rule permitting 53/udp from 192.168.0.0/16, so the default-deny policy drops the queries."
sect "Fix"; bash "$REPO/linux/firewall/ufw-rules.sh" >/dev/null
run ip netns exec fin-pc dig +short srv01.corp.lab
finish "$(verdict bash -c '[[ $(ip netns exec fin-pc dig +short srv01.corp.lab) == 192.168.50.10 ]]')" "Host firewall had no rule for DNS from the lab networks."

# ------------------------------------------------------------------ TS-07
start TS-07 "DHCP clients do not receive leases"
para "**Fault injected:** DHCP relay on BR-R2 stopped (equivalent to a missing \`ip helper-address\`); HR-PC releases its lease and asks again."
kill "$(cat /run/lab-dhcrelay-br-r2.pid)"; rm -f /run/lab-dhcrelay-br-r2.pid
n hr-pc dhclient -r -pf /run/dhclient-hr-pc.pid -lf /var/lib/dhcp/dhclient-hr-pc.leases eth0 2>/dev/null
sect "Symptom"; run ip netns exec hr-pc dhclient -4 -1 -v -timeout 8 -pf /run/dhclient-hr-pc.pid -lf /var/lib/dhcp/dhclient-hr-pc.leases eth0
sect "Diagnosis"
run bash -c "pgrep -af 'dhcrelay.*br-r2' || echo 'no dhcrelay process for BR-R2'"
run bash -c "timeout 6 ip netns exec br-r2 tcpdump -ni g0-0.30 -c 2 udp port 67 2>&1 & sleep 1; ip netns exec hr-pc dhclient -4 -1 -timeout 4 -pf /run/dhclient-hr-pc.pid -lf /var/lib/dhcp/dhclient-hr-pc.leases eth0 >/dev/null 2>&1; wait"
para "DHCPDISCOVER broadcasts arrive on G0/0.30 but routers do not forward broadcasts. With no relay (helper) nothing reaches Kea on 192.168.50.10."
sect "Fix"
ip netns exec br-r2 dhcrelay -4 -pf /run/lab-dhcrelay-br-r2.pid -id g0-0.30 -id g0-0.40 -iu g0-1 192.168.50.10
run ip netns exec hr-pc dhclient -4 -1 -v -pf /run/dhclient-hr-pc.pid -lf /var/lib/dhcp/dhclient-hr-pc.leases eth0
run ip -n hr-pc -4 -br addr show eth0
finish "$(verdict bash -c 'ip -n hr-pc -4 -br addr show eth0 | grep -q 192.168.30.')" "DHCP relay (ip helper-address) missing on the branch router."

# ------------------------------------------------------------------ TS-08
start TS-08 "ACL blocks legitimate traffic"
para "**Fault injected:** a deny for the Admin VLAN inserted at the top of FINANCE-PROTECT (wrong ACE order), as if \`1 deny ip 192.168.10.0 0.0.0.255 any\` were added."
n br-r2 nft insert rule ip cisco_acl finance_protect ip saddr 192.168.10.0/24 counter drop
FIN=$(ip -n fin-pc -4 -br addr show eth0 | awk '{print $3}' | cut -d/ -f1)
sect "Symptom"; run ip netns exec admin-pc ping -c 2 -W 1 "$FIN"
sect "Diagnosis (show access-lists — check hit counters and ordering)"
run ip netns exec br-r2 nft list chain ip cisco_acl finance_protect
para "Rules are matched top-down. The new first rule drops Admin traffic before the intended \`permit 192.168.10.0/24\` is reached; its counter increments with each ping."
sect "Fix"
H=$(n br-r2 nft -a list chain ip cisco_acl finance_protect | awk '/192.168.10.0\/24 counter packets [0-9]+ bytes [0-9]+ drop/{print $NF; exit}')
n br-r2 nft delete rule ip cisco_acl finance_protect handle "$H"
run ip netns exec admin-pc ping -c 2 -W 1 "$FIN"
finish "$(verdict ping_ok admin-pc "$FIN")" "Deny entry placed above the permit in FINANCE-PROTECT."

# ------------------------------------------------------------------ TS-09
start TS-09 "Ansible cannot connect to a router"
para "**Fault injected:** SSH service on HQ-R1 stopped (like \`transport input none\` on the VTY lines)."
kill "$(cat /run/lab-sshd-hq-r1.pid)"; rm -f /run/lab-sshd-hq-r1.pid
cd "$REPO/automation/ansible" || exit 1
sect "Symptom"; run sudo -u netadmin -H ansible -i inventory/emulation.yml HQ-R1 -m ping
sect "Diagnosis"
run ping -c 1 -W 1 192.168.99.1
run bash -c "nc -zv -w 2 192.168.99.1 22 2>&1"
para "ICMP works but TCP/22 is refused, so it is not a routing or ACL problem: the SSH service on the device is not listening."
sect "Fix"
ip netns exec hq-r1 /usr/sbin/sshd -o ListenAddress=192.168.99.1 -o PidFile=/run/lab-sshd-hq-r1.pid -o AllowUsers=netadmin -o PasswordAuthentication=no
run sudo -u netadmin -H ansible -i inventory/emulation.yml HQ-R1 -m ping
finish "$(verdict sudo -u netadmin -H ansible -i inventory/emulation.yml HQ-R1 -m ping)" "SSH not running/allowed on the router's management address."
cd - >/dev/null || true

# ------------------------------------------------------------------ TS-10
start TS-10 "SNMP monitoring cannot detect a device"
para "**Fault injected:** BR-R2's SNMP agent restarted with a different SNMPv3 auth key (credential mismatch between NMS and device)."
kill "$(cat /run/lab-snmpd-br-r2.pid)"; sleep 1
sed -i "s/^createUser monitor SHA \"[^\"]*\"/createUser monitor SHA \"MismatchedKey123\"/" /etc/snmp/lab-br-r2.conf
rm -rf /var/lib/snmp/lab-br-r2/*
n br-r2 /usr/sbin/snmpd -LS0-5d -Lf /dev/null -C -c /etc/snmp/lab-br-r2.conf -p /run/lab-snmpd-br-r2.pid; sleep 1
sect "Symptom"; run snmpget "${SNMP[@]}" 192.168.199.1 SNMPv2-MIB::sysName.0
sect "Diagnosis"
run ping -c 1 -W 1 192.168.199.1
run bash -c "ip netns exec br-r2 ss -ulpn | grep ':161'"
para "The device is reachable and snmpd listens on 161/udp, but the NMS reports an authentication failure. The v3 user's auth key differs between the device and the NMS."
sect "Fix"
kill "$(cat /run/lab-snmpd-br-r2.pid)"; sleep 1
sed -i "s/^createUser monitor SHA \"[^\"]*\"/createUser monitor SHA \"$SNMP_AUTH\"/" /etc/snmp/lab-br-r2.conf
rm -rf /var/lib/snmp/lab-br-r2/*
n br-r2 /usr/sbin/snmpd -LS0-5d -Lf /dev/null -C -c /etc/snmp/lab-br-r2.conf -p /run/lab-snmpd-br-r2.pid; sleep 1
run snmpget "${SNMP[@]}" 192.168.199.1 SNMPv2-MIB::sysName.0
finish "$(verdict snmpget "${SNMP[@]}" 192.168.199.1 SNMPv2-MIB::sysName.0)" "SNMPv3 auth key mismatch between device and NMS."
# keep secrets out of the published record
sed -i "s/$SNMP_AUTH/<SNMP_AUTH>/g; s/$SNMP_PRIV/<SNMP_PRIV>/g" "$DIR"/TS-*.md

# ------------------------------------------------------------------ index
{
  echo "# Troubleshooting challenges (guide section 10)"
  echo
  echo "Each record shows the fault injected, the symptom, the diagnostic commands with real output,"
  echo "the root cause and the verified fix. Generated by [run-challenges.sh](run-challenges.sh)."
  echo
  echo "| ID | Challenge | Root cause | Fixed |"
  echo "|---|---|---|---|"
  printf '%s\n' "${INDEX[@]}"
} >"$DIR/README.md"
chown -R netadmin:netadmin "$DIR"
