# Test report

Run: 2026-11-09 11:21 UTC on srv01.corp.lab — Ubuntu 22.04, FRR 8.1

Environment: namespace emulation of the guide topology (see [testing/emulation](../emulation/)).

**Result: 17 passed, 0 failed**

| ID | Test | Procedure | Expected | Result | Evidence |
|---|---|---|---|---|---|
| T01 | Basic reachability | Ping local gateway from each client | Every gateway replies | **PASS** | [T01](evidence/T01-gateway-ping.txt) |
| T02 | DHCP via relay | Clients lease through ip helper-address (dhcrelay) to Kea | Address from own VLAN pool, gateway .1, DNS 192.168.50.10 | **PASS** | [T02](evidence/T02-dhcp-leases.txt) |
| T03 | OSPF | show ip ospf neighbor / show ip route ospf | Neighbor Full; remote LANs installed | **PASS** | [T03](evidence/T03-ospf.txt) |
| T04 | Inter-VLAN and inter-site routing | Admin->IT, HR->server across the WAN, traceroute | Permitted flows pass; path is BR-R2 -> 10.0.12.1 -> server | **PASS** | [T04](evidence/T04-inter-vlan-and-wan.txt) |
| T05 | Web service | curl http://www.corp.lab from every VLAN | HTTP 200 from Nginx on 192.168.50.10 | **PASS** | [T05](evidence/T05-web.txt) |
| T06 | DNS | dig corp.lab records (forward, reverse, recursive) | Expected private IPs returned | **PASS** | [T06](evidence/T06-dns.txt) |
| T07 | ACL FINANCE-PROTECT | IT and HR ping a Finance host; Admin pings it | IT/HR blocked with counters incrementing; Admin allowed | **PASS** | [T07](evidence/T07-acl-finance.txt) |
| T08 | ACL MGMT-PROTECT | Reach switch management SVIs from IT, Admin, server | Only Admin VLAN and the server reach VLAN 99/199 | **PASS** | [T08](evidence/T08-acl-management.txt) |
| T09 | WAN failure | Shut HQ-R1 G0/1, verify, restore | Adjacency drops, branch unreachable, Syslog event logged, re-converges | **PASS** | [T09](evidence/T09-wan-failure.txt) |
| T10 | Centralised Syslog | Devices send to 192.168.50.10:514; controlled test event | Per-device files in /var/log/remote with source IPs | **PASS** | [T10](evidence/T10-syslog.txt) |
| T11 | SNMPv3 monitoring | snmpget/snmpwalk authPriv to all devices; v2c and bad keys | v3 authPriv answers; v2c/wrong keys refused | **PASS** | [T11](evidence/T11-snmpv3.txt) |
| T12 | Ansible backup | ansible-playbook backup-emulation.yml | Backups for routers and switches created, OSPF asserted Full | **PASS** | [T12](evidence/T12-ansible-backup.txt) |
| T13 | Python health check | health_check.py: ping + TCP/22 to every device | All devices reachable, CSV log written | **PASS** | [T13](evidence/T13-python-health-check.txt) |
| T14 | Server hardening | UFW policy, listening sockets, sshd effective config | UFW active default-deny; root SSH login disabled | **PASS** | [T14](evidence/T14-server-hardening.txt) |
| T15 | Linux services | systemctl status of all server services | All active (running) | **PASS** | [T15](evidence/T15-services.txt) |
| T16 | WireGuard remote access | Remote admin over the internet link: no VPN, VPN, permitted and denied routes | Handshake; servers + mgmt reachable via tunnel; Finance and untunnelled traffic dropped | **PASS** | [T16](evidence/T16-wireguard.txt) |
| T17 | LibreNMS (SNMPv3) | Web UI, device inventory and port status polled over SNMPv3 authPriv | Login page 200; 5 devices up via v3; port events logged | **PASS** | [T17](evidence/T17-librenms.txt) |
