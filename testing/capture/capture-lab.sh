#!/usr/bin/env bash
# capture-lab.sh  -  protocol evidence with tcpdump + tshark (Wireshark CLI) in the emulated lab.
#   sudo ./testing/capture/capture-lab.sh     (emulation and WireGuard must be up)
# Each scenario triggers one event, captures it at the right interface, saves a .pcap for
# Wireshark and a tshark summary. Outputs: testing/results/pcap/
#   01-ospf-adjacency   WAN flap on BR-R2 g0-1 -> Hello / DB Description / LS Request / LS Update
#   02-dhcp-relay       IT-PC renews its lease -> relayed unicast to Kea with giaddr 192.168.20.1
#   03-snmpv3-authpriv  srv01 polls HQ-R1 -> USM user visible, PDU encrypted (no community string)
#   04-wireguard-outer  ping srv01 over the VPN, seen on the internet link -> only UDP 51820
#   05-wireguard-inner  the same ping on HQ-R1 wg0 -> cleartext ICMP inside the tunnel
#   06-syslog-plaintext an IOS-style log line to srv01:514 -> readable on the wire (limitation)
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/testing/results/pcap"
mkdir -p "$OUT"; rm -f "$OUT"/*
# shellcheck disable=SC1091
source /root/lab-secrets.env
n() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
command -v tshark >/dev/null || {
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q tshark >/dev/null
}

# cap NAME NS IFACE FILTER SECONDS  (background; returns after tcpdump is ready)
cap() {
  local name=$1 ns=$2 ifc=$3 flt=$4 secs=$5 pre=()
  [[ $ns != - ]] && pre=(ip netns exec "$ns")
  timeout "$secs" "${pre[@]}" tcpdump -i "$ifc" -nn -U -s 256 -w "$OUT/$name.pcap" "$flt" 2>/dev/null &
  sleep 1
}
summary() {  # summary NAME "title" tshark-args...
  local name=$1 title=$2; shift 2
  { echo "# $title"; echo "\$ tshark -r $name.pcap $*"; tshark -r "$OUT/$name.pcap" "$@" 2>/dev/null; echo; } \
    >"$OUT/$name.txt"
  printf '%-22s %4s packets  %s\n' "$name" "$(tshark -r "$OUT/$name.pcap" 2>/dev/null | wc -l)" "$title"
}

echo "== 01 OSPF adjacency after a WAN flap"
cap 01-ospf-adjacency hq-r1 g0-1 "proto ospf" 45
sleep 2; n br-r2 ip link set g0-1 down; sleep 3; n br-r2 ip link set g0-1 up
wait
summary 01-ospf-adjacency "OSPF on the WAN (10.0.12.0/30) during a link flap" \
  -T fields -E header=y -e frame.time_relative -e ip.src -e ip.dst -e ospf.msg -e ospf.srcrouter

echo "== 02 DHCP relay (IT-PC renews)"
cap 02-dhcp-relay hq-r1 g0-0.50 "udp port 67 or udp port 68" 15
n it-pc dhclient -r eth0 2>/dev/null; n it-pc dhclient -1 eth0 2>/dev/null
wait
summary 02-dhcp-relay "DHCP between HQ-R1 (relay) and Kea on srv01" \
  -T fields -E header=y -e ip.src -e ip.dst -e dhcp.option.dhcp -e dhcp.ip.relay -e dhcp.ip.your -e dhcp.hw.mac_addr

echo "== 03 SNMPv3 authPriv"
cap 03-snmpv3-authpriv - br-vlan50 "udp port 161 and host 192.168.99.1" 10
snmpget -v3 -l authPriv -u monitor -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" 192.168.99.1 SNMPv2-MIB::sysName.0 >/dev/null
snmpget -v2c -c public -t 1 -r 0 192.168.99.1 SNMPv2-MIB::sysName.0 >/dev/null 2>&1
wait
summary 03-snmpv3-authpriv "SNMP on the wire: v3 user name visible, PDU encrypted; v2c 'public' gets no reply" \
  -T fields -E header=y -e ip.src -e ip.dst -e snmp.msgVersion -e snmp.msgUserName -e snmp.msgFlags \
  -e snmp.community -e snmp.encryptedPDU

echo "== 04/05 WireGuard outer and inner"
cap 04-wireguard-outer hq-r1 g0-2 "udp port 51820" 10
cap 05-wireguard-inner hq-r1 wg0 "icmp" 9
n remote-admin ping -c 3 -q 192.168.50.10 >/dev/null
wait
summary 04-wireguard-outer "Internet link: only WireGuard UDP 51820, payload encrypted" \
  -T fields -E header=y -e ip.src -e ip.dst -e udp.dstport -e wg.type -e wg.receiver -e frame.len
summary 05-wireguard-inner "Inside the tunnel (HQ-R1 wg0): the admin's ICMP in clear" \
  -T fields -E header=y -e ip.src -e ip.dst -e icmp.type

echo "== 06 Syslog over UDP 514"
cap 06-syslog-plaintext - br-vlan50 "udp port 514" 6
n hq-r1 logger -n 192.168.50.10 -P 514 -d -t HQ-R1 "%LINEPROTO-5-UPDOWN: Line protocol on Interface g0-1, changed state to down (capture test)"
wait
summary 06-syslog-plaintext "Syslog is plaintext on the wire (protect with TLS/RELP or a management VLAN)" \
  -T fields -E header=y -e ip.src -e ip.dst -e syslog.msg

ls -la "$OUT"
