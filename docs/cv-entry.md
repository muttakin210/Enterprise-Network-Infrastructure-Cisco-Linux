# CV entry

Use these lines only for work that has been completed and tested (guide section 12).
Each claim below links to evidence in this repository.

**Enterprise Network Infrastructure with Cisco & Linux Automation**
_Cisco IOS, Packet Tracer, Ubuntu Server, VLAN, OSPF, ACL, Ansible, Python, SNMPv3, Syslog, FRR_

- Designed a two-site enterprise network (7 VLANs, router-on-a-stick, OSPF area 0 over a /30 WAN)
  and wrote sanitized Cisco IOS configs for routers and access switches.
- Hardened the network with SSH-only management, VTY and management ACLs, Finance segmentation ACLs,
  port security, DHCP snooping, BPDU Guard and SNMPv3 authPriv.
- Built an Ubuntu 22.04 services server (BIND9, Kea DHCP with relay, Nginx, rsyslog, SNMPv3, UFW)
  from one idempotent script.
- Automated configuration backups with sanitizing (Ansible) and reachability and SSH checks (Python, unit-tested).
- Validated the design end to end on a Linux network-namespace emulation with 15 automated tests and
  10 troubleshooting scenarios, including WAN failure with Syslog evidence and OSPF re-convergence time.
