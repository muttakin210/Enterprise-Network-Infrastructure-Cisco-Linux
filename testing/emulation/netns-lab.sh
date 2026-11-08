#!/usr/bin/env bash
# netns-lab.sh  -  software emulation of the guide's two-site topology on srv01.
#
# Why: GNS3 needs licensed Cisco images, which this lab does not have. The
# Cisco configs are validated in Packet Tracer (cisco/packet-tracer/). This script
# rebuilds the same L2/L3 design with Linux network namespaces so the Ubuntu
# services (DHCP relay, DNS, web, Syslog, SNMP, Ansible, Python checks) can be
# tested end to end against real routed traffic:
#
#   switches  = VLAN-aware Linux bridges (access ports = PVID untagged, trunk = tagged)
#   routers   = namespaces with 802.1Q subinterfaces, FRR OSPF, isc-dhcp-relay,
#               nftables ACLs equivalent to the Cisco ACLs, sshd for automation
#   clients   = namespaces running dhclient (like VPCS "ip dhcp")
#   srv01     = the real host, attached to HQ-SW1 VLAN 50 through bridge br-vlan50
#
# Usage: sudo ./netns-lab.sh up | down | status
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER=192.168.50.10
NS_ALL=(hq-r1 br-r2 hq-sw1 br-sw1 admin-pc it-pc hr-pc fin-pc)

nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }

link() {  # link NS_A IF_A NS_B IF_B  (veth cable)
  ip link add "$2" netns "$1" type veth peer name "$4" netns "$3"
  ip -n "$1" link set "$2" up
  ip -n "$3" link set "$4" up
}

mk_switch() {  # mk_switch NS
  ip -n "$1" link add sw type bridge vlan_filtering 1 vlan_default_pvid 0 stp_state 0
  ip -n "$1" link set sw up
}
access_port() { ip -n "$1" link set "$2" master sw; bridge -n "$1" vlan add dev "$2" vid "$3" pvid untagged; }
trunk_port()  { local ns=$1 p=$2; shift 2; ip -n "$ns" link set "$p" master sw; for v in "$@"; do bridge -n "$ns" vlan add dev "$p" vid "$v"; done; }
svi() {  # svi NS VLAN IP/LEN GW
  bridge -n "$1" vlan add dev sw vid "$2" self
  ip -n "$1" link add link sw name "vlan$2" type vlan id "$2"
  ip -n "$1" addr add "$3" dev "vlan$2"
  ip -n "$1" link set "vlan$2" up
  ip -n "$1" route add default via "$4"
}
subif() {  # subif NS PARENT VLAN IP/LEN
  ip -n "$1" link add link "$2" name "$2.$3" type vlan id "$3"
  ip -n "$1" addr add "$4" dev "$2.$3"
  ip -n "$1" link set "$2.$3" up
}

frr_start() {  # frr_start NS HOSTNAME ROUTER_ID WAN_IF "net1 net2 ..." "passive_if ..."
  local ns=$1 host=$2 rid=$3 wan=$4 nets=$5 passive=$6
  install -d -o frr -g frr -m 755 "/etc/frr/$ns" "/var/run/frr/$ns"
  install -d -o frr -g frr -m 755 /var/log/frr
  {
    echo "hostname $host"
    echo "log file /var/log/frr/$ns-zebra.log informational"
  } >"/etc/frr/$ns/zebra.conf"
  {
    echo "hostname $host"
    echo "log file /var/log/frr/$ns-ospfd.log informational"
    echo "log timestamp precision 3"
    echo "interface $wan"
    echo " ip ospf network point-to-point"
    for p in $passive; do echo "interface $p"; echo " ip ospf passive"; done
    echo "router ospf"
    echo " ospf router-id $rid"
    echo " log-adjacency-changes detail"
    for n in $nets; do echo " network $n area 0"; done
  } >"/etc/frr/$ns/ospfd.conf"
  : >"/etc/frr/$ns/vtysh.conf"
  chown frr:frr /etc/frr/"$ns"/*.conf; chmod 640 /etc/frr/"$ns"/*.conf
  nsx "$ns" /usr/lib/frr/zebra -d -N "$ns" -A 127.0.0.1 -f "/etc/frr/$ns/zebra.conf"
  sleep 1
  nsx "$ns" /usr/lib/frr/ospfd -d -N "$ns" -A 127.0.0.1 -f "/etc/frr/$ns/ospfd.conf"
  # ship OSPF log lines to the central Syslog server, like "logging host" on IOS
  nsx "$ns" nohup python3 "$HERE/log-forwarder.py" "$host" "/var/log/frr/$ns-ospfd.log" "$SERVER" \
     >/dev/null 2>&1 &
  echo $! >"/run/lab-logfwd-$ns.pid"
}

relay_start() {  # relay_start NS UPSTREAM_IF DOWNSTREAM_IF...
  local ns=$1 up=$2; shift 2
  local args=(); for d in "$@"; do args+=(-id "$d"); done
  nsx "$ns" dhcrelay -4 -pf "/run/lab-dhcrelay-$ns.pid" "${args[@]}" -iu "$up" "$SERVER"
}

sshd_start() {  # sshd_start NS LISTEN_IP   (management SSH for Ansible / health checks)
  nsx "$1" /usr/sbin/sshd -o ListenAddress="$2" -o PidFile="/run/lab-sshd-$1.pid" \
     -o AllowUsers=netadmin -o PasswordAuthentication=no
}

client_dhcp() {  # client_dhcp NS
  local ns=$1
  install -d "/etc/netns/$ns/dhcp"
  echo "nameserver 127.0.0.53" >"/etc/netns/$ns/resolv.conf"     # replaced by the lease
  printf 'request subnet-mask, broadcast-address, routers, domain-name, domain-name-servers, domain-search;\ntimeout 20;\n' \
     >"/etc/netns/$ns/dhcp/dhclient.conf"
  nsx "$ns" dhclient -4 -1 -v -pf "/run/dhclient-$ns.pid" -lf "/var/lib/dhcp/dhclient-$ns.leases" eth0 \
     2>&1 | grep -E 'DHCPOFFER|DHCPACK|bound to' || true
}

acl_hq_r1() {
  nsx hq-r1 nft -f - <<'EOF'
table ip cisco_acl {
  # MGMT-PROTECT  (ip access-group MGMT-PROTECT out on G0/0.99)
  chain mgmt_protect {
    ip saddr 192.168.10.0/24 counter accept
    ip saddr 192.168.50.10 counter accept
    ip saddr 192.168.199.0/24 counter accept
    counter log prefix "HQ-R1 MGMT-PROTECT deny " drop
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
    oifname "g0-0.99" jump mgmt_protect
  }
}
EOF
}

acl_br_r2() {
  nsx br-r2 nft -f - <<'EOF'
table ip cisco_acl {
  # FINANCE-PROTECT  (ip access-group FINANCE-PROTECT out on G0/0.40)
  chain finance_protect {
    ip saddr 192.168.10.0/24 counter accept
    ip saddr 192.168.50.10 counter accept
    ip saddr 192.168.20.0/24 counter log prefix "BR-R2 FINANCE-PROTECT deny " drop
    ip saddr 192.168.30.0/24 counter log prefix "BR-R2 FINANCE-PROTECT deny " drop
    counter accept
  }
  # MGMT-PROTECT  (ip access-group MGMT-PROTECT out on G0/0.199)
  chain mgmt_protect {
    ip saddr 192.168.10.0/24 counter accept
    ip saddr 192.168.50.10 counter accept
    ip saddr 192.168.99.0/24 counter accept
    counter log prefix "BR-R2 MGMT-PROTECT deny " drop
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
    oifname "g0-0.40" jump finance_protect
    oifname "g0-0.199" jump mgmt_protect
  }
}
EOF
}

up() {
  [[ -d /sys/class/net/br-vlan50 ]] || { echo "br-vlan50 missing: run linux/setup-server.sh first"; exit 1; }
  for ns in "${NS_ALL[@]}"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done

  # ---- cabling (same ports as the guide) ----
  link hq-r1 g0-0  hq-sw1 g0-0          # trunk
  link br-r2 g0-0  br-sw1 g0-0          # trunk
  link hq-r1 g0-1  br-r2  g0-1          # WAN /30
  link admin-pc eth0 hq-sw1 g0-1
  link it-pc    eth0 hq-sw1 g0-2
  link hr-pc    eth0 br-sw1 g0-1
  link fin-pc   eth0 br-sw1 g0-2
  ip link add srv-uplink type veth peer name g0-3 netns hq-sw1   # UBUNTU-SERVER port
  ip link set srv-uplink master br-vlan50 up
  ip -n hq-sw1 link set g0-3 up

  # ---- HQ-SW1 ----
  mk_switch hq-sw1
  trunk_port  hq-sw1 g0-0 10 20 50 99
  access_port hq-sw1 g0-1 10
  access_port hq-sw1 g0-2 20
  access_port hq-sw1 g0-3 50
  svi hq-sw1 99 192.168.99.2/24 192.168.99.1

  # ---- BR-SW1 ----
  mk_switch br-sw1
  trunk_port  br-sw1 g0-0 30 40 199
  access_port br-sw1 g0-1 30
  access_port br-sw1 g0-2 40
  svi br-sw1 199 192.168.199.2/24 192.168.199.1

  # ---- HQ-R1 (router-on-a-stick) ----
  subif hq-r1 g0-0 10 192.168.10.1/24
  subif hq-r1 g0-0 20 192.168.20.1/24
  subif hq-r1 g0-0 50 192.168.50.1/24
  subif hq-r1 g0-0 99 192.168.99.1/24
  ip -n hq-r1 addr add 10.0.12.1/30 dev g0-1
  nsx hq-r1 sysctl -qw net.ipv4.ip_forward=1

  # ---- BR-R2 ----
  subif br-r2 g0-0 30  192.168.30.1/24
  subif br-r2 g0-0 40  192.168.40.1/24
  subif br-r2 g0-0 199 192.168.199.1/24
  ip -n br-r2 addr add 10.0.12.2/30 dev g0-1
  nsx br-r2 sysctl -qw net.ipv4.ip_forward=1

  # ---- OSPF (FRR) ----
  frr_start hq-r1 HQ-R1 1.1.1.1 g0-1 \
    "10.0.12.0/30 192.168.10.0/24 192.168.20.0/24 192.168.50.0/24 192.168.99.0/24" \
    "g0-0.10 g0-0.20 g0-0.50 g0-0.99"
  frr_start br-r2 BR-R2 2.2.2.2 g0-1 \
    "10.0.12.0/30 192.168.30.0/24 192.168.40.0/24 192.168.199.0/24" \
    "g0-0.30 g0-0.40 g0-0.199"

  # ---- ACLs, DHCP relay (ip helper-address), management SSH ----
  acl_hq_r1
  acl_br_r2
  relay_start hq-r1 g0-0.50 g0-0.10 g0-0.20
  relay_start br-r2 g0-1    g0-0.30 g0-0.40
  sshd_start hq-r1 192.168.99.1
  sshd_start br-r2 192.168.199.1
  sshd_start hq-sw1 192.168.99.2
  sshd_start br-sw1 192.168.199.2

  echo "Waiting for OSPF adjacency..."
  for _ in $(seq 1 30); do
    vtysh -N hq-r1 -c 'show ip ospf neighbor' 2>/dev/null | grep -q Full && break
    sleep 2
  done
  vtysh -N hq-r1 -c 'show ip ospf neighbor'

  echo "Clients requesting DHCP leases through the relays..."
  for pc in admin-pc it-pc hr-pc fin-pc; do echo "[$pc]"; client_dhcp "$pc"; done
  status
}

down() {
  for f in /run/lab-*.pid /run/dhclient-*-pc.pid; do
    [[ -f $f ]] && kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
  for ns in hq-r1 br-r2; do
    for d in ospfd zebra; do
      pf="/var/run/frr/$ns/$d.pid"; [[ -f $pf ]] && kill "$(cat "$pf")" 2>/dev/null || true
    done
  done
  sleep 1
  for ns in "${NS_ALL[@]}"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns"
  done
  ip link del srv-uplink 2>/dev/null || true
  echo "emulated topology removed"
}

status() {
  echo "== namespaces =="; ip netns list
  for pc in admin-pc it-pc hr-pc fin-pc; do
    printf '%-9s %s\n' "$pc" "$(ip -n "$pc" -4 -br addr show eth0 2>/dev/null | awk '{print $3}')"
  done
  echo "== HQ-R1 OSPF =="; vtysh -N hq-r1 -c 'show ip ospf neighbor' 2>/dev/null || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 up|down|status"; exit 1 ;;
esac
