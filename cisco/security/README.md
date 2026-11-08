# Security controls (guide section 9)

| Control | Where | Config | How it is verified |
|---|---|---|---|
| VLAN segmentation | HQ-SW1, BR-SW1 | access VLANs, native VLAN 999, unused ports parked and shut | `show vlan brief`, `show interfaces trunk` |
| SSH v2 only | all devices | `ip ssh version 2`, `transport input ssh`, local user | `show ip ssh`, SSH login from VLAN 10 |
| VTY access-class | routers | `VTY-ADMIN` standard ACL | SSH from VLAN 20 is refused and the ACL counter increments |
| Management protection | HQ-R1 `G0/0.99`, BR-R2 `G0/0.199` | `MGMT-PROTECT` (out) | ping 192.168.99.2 from IT-PC fails, from ADMIN-PC succeeds |
| Finance protection | BR-R2 `G0/0.40` | `FINANCE-PROTECT` (out) | HR-PC → FIN-PC blocked; ADMIN-PC → FIN-PC allowed |
| Port security | access ports | max 2 sticky MACs, violation `restrict` | `show port-security interface g0/1`; add a third MAC |
| DHCP snooping | VLANs 10,20 and 30,40 | uplink trusted, edge ports rate-limited | `show ip dhcp snooping binding`; a rogue server on an edge port is dropped |
| BPDU Guard | access ports | `spanning-tree bpduguard enable` | plug a switch into an edge port → err-disabled |
| SNMPv3 authPriv | all devices | group `NMS`, ACL `SNMP-NMS` | `snmpwalk -v3 -l authPriv ...` from 192.168.50.10 |
| Login hardening | routers | `login block-for`, `exec-timeout`, banner | `show login` |
| Guest isolation (optional) | HQ-R1 `G0/0.60` | [guest-vlan60-extension.cfg](guest-vlan60-extension.cfg) | guest → finance blocked, guest → web allowed |
| Host firewall | Ubuntu | [UFW script](../../linux/firewall/ufw-rules.sh) | `ufw status verbose` |

**Why `no ip dhcp snooping information option`:** with snooping on, IOS switches insert
option 82 with `giaddr 0.0.0.0`, and the relaying router (`ip helper-address`) drops those
requests by default. Turning off option-82 insertion on the access switch keeps the relay working.

**Why the ACLs are applied *outbound* on the protected subinterface:** one ACL then covers
traffic arriving from every other VLAN and from the WAN, and the router's own OSPF hellos are not
filtered (an outbound ACL does not apply to locally generated packets).
