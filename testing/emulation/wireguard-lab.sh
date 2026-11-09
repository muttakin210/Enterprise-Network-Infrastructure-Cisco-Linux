#!/usr/bin/env bash
# wireguard-lab.sh  -  "WireGuard (optional): secure remote lab access" (guide section 9).
# Adds a remote administrator to the running emulation (netns-lab.sh up):
#
#   remote-admin (laptop on the internet)  eth0 203.0.113.2/30
#        |  untrusted "internet" link (TEST-NET-3, RFC 5737)
#   HQ-R1 G0/2  203.0.113.1/30  -- edge: only UDP/51820 accepted, nothing routed in
#   HQ-R1 wg0   10.99.0.1/24    <== WireGuard tunnel ==>  remote-admin wg0 10.99.0.2/24
#
# Least privilege, enforced twice:
#   * client side: AllowedIPs = Servers VLAN 50 + Management VLANs 99/199 only
#   * HQ-R1 side : nftables VPN-FILTER forwards wg0 traffic to those networks only
#                  (Finance, HR, IT, Admin stay unreachable even if the client adds routes)
# 10.99.0.0/24 is advertised into OSPF (passive) so BR-R2 can answer for VLAN 199.
# Keys are generated on the VM under /etc/wireguard/lab (mode 600) and never committed.
#
# Usage: sudo ./wireguard-lab.sh up | down | status
set -euo pipefail
KEYS=/etc/wireguard/lab
PORT=51820
PERMITTED="192.168.50.0/24, 192.168.99.0/24, 192.168.199.0/24"

nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }

keys() {
  install -d -m 700 $KEYS
  for k in hq-r1 remote-admin; do
    [[ -f $KEYS/$k.key ]] || (umask 077; wg genkey >$KEYS/$k.key)
    wg pubkey <$KEYS/$k.key >$KEYS/$k.pub
  done
}

up() {
  ip netns list | grep -q '^hq-r1' || { echo "run netns-lab.sh up first"; exit 1; }
  command -v wg >/dev/null || apt-get install -y -q wireguard-tools
  keys
  ip netns add remote-admin; ip -n remote-admin link set lo up

  # ---- internet link: HQ-R1 G0/2 <-> remote laptop ----
  ip link add g0-2 netns hq-r1 type veth peer name eth0 netns remote-admin
  ip -n hq-r1 addr add 203.0.113.1/30 dev g0-2;        ip -n hq-r1 link set g0-2 up
  ip -n remote-admin addr add 203.0.113.2/30 dev eth0; ip -n remote-admin link set eth0 up

  # ---- WireGuard on HQ-R1 (created in the netns, so the UDP socket lives there) ----
  ip -n hq-r1 link add wg0 type wireguard
  nsx hq-r1 wg set wg0 listen-port $PORT private-key $KEYS/hq-r1.key \
     peer "$(cat $KEYS/remote-admin.pub)" allowed-ips 10.99.0.2/32
  ip -n hq-r1 addr add 10.99.0.1/24 dev wg0; ip -n hq-r1 link set wg0 up

  # ---- WireGuard client on the remote laptop ----
  ip -n remote-admin link add wg0 type wireguard
  nsx remote-admin wg set wg0 private-key $KEYS/remote-admin.key \
     peer "$(cat $KEYS/hq-r1.pub)" endpoint 203.0.113.1:$PORT \
     allowed-ips "${PERMITTED// /}" persistent-keepalive 25
  ip -n remote-admin addr add 10.99.0.2/24 dev wg0; ip -n remote-admin link set wg0 up
  for net in ${PERMITTED//,/ }; do ip -n remote-admin route add "$net" dev wg0; done

  # ---- HQ-R1 policy: edge protection + VPN-FILTER ----
  nsx hq-r1 nft -f - <<EOF
table ip vpn {
  # EDGE-IN (ip access-group EDGE-IN in on G0/2): only WireGuard reaches the router
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "g0-2" udp dport $PORT counter accept
    iifname "g0-2" ct state established,related accept
    iifname "g0-2" counter log prefix "HQ-R1 EDGE-IN deny " drop
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "g0-2" counter log prefix "HQ-R1 EDGE-IN deny " drop
    oifname "g0-2" counter drop
    # VPN-FILTER: remote admins reach servers and management only
    iifname "wg0" ip daddr { ${PERMITTED} } counter accept
    iifname "wg0" counter log prefix "HQ-R1 VPN-FILTER deny " drop
  }
}
EOF
  # MGMT-PROTECT on both routers: permit the VPN pool like the Admin VLAN
  nsx hq-r1 nft insert rule ip cisco_acl mgmt_protect ip saddr 10.99.0.0/24 counter accept
  nsx br-r2 nft insert rule ip cisco_acl mgmt_protect ip saddr 10.99.0.0/24 counter accept

  # ---- OSPF: advertise the VPN pool (passive) so the branch can route replies ----
  vtysh -N hq-r1 -c 'configure terminal' -c 'interface wg0' -c 'ip ospf passive' \
        -c 'router ospf' -c 'network 10.99.0.0/24 area 0' >/dev/null

  # ---- srv01: return route for the VPN pool via HQ-R1 (also in linux/netplan) ----
  ip route replace 10.99.0.0/24 via 192.168.50.1

  # first packet triggers the handshake
  nsx remote-admin ping -c 1 -W 2 10.99.0.1 >/dev/null 2>&1 || true
  status
}

down() {
  vtysh -N hq-r1 -c 'configure terminal' -c 'router ospf' -c 'no network 10.99.0.0/24 area 0' \
        >/dev/null 2>&1 || true
  ip -n hq-r1 link del wg0 2>/dev/null || true
  ip -n hq-r1 link del g0-2 2>/dev/null || true
  ip netns exec hq-r1 nft delete table ip vpn 2>/dev/null || true
  for ns in hq-r1 br-r2; do
    h=$(ip netns exec $ns nft -a list chain ip cisco_acl mgmt_protect 2>/dev/null \
        | awk '/10.99.0.0/{print $NF}')
    [[ -n $h ]] && ip netns exec $ns nft delete rule ip cisco_acl mgmt_protect handle "$h" || true
  done
  ip netns del remote-admin 2>/dev/null || true
  ip route del 10.99.0.0/24 2>/dev/null || true
  echo "WireGuard remote access removed"
}

status() {
  echo "== HQ-R1 wg0 =="; nsx hq-r1 wg show wg0 | sed 's/^\(\s*\(preshared \)\?key: \).*/\1(hidden)/'
  echo "== remote-admin routes =="; ip -n remote-admin route
}

case "${1:-}" in
  up) up ;; down) down ;; status) status ;;
  *) echo "usage: $0 up|down|status"; exit 1 ;;
esac
