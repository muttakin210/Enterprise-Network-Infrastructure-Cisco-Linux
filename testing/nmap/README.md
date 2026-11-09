# Nmap: discovery and policy audit

[nmap-audit.sh](nmap-audit.sh) runs Nmap **from inside the lab** (client namespaces and the
internet-side `remote-admin`). It checks that the network matches its documentation and its
security policy. It is test T21.

```bash
sudo ./testing/nmap/nmap-audit.sh       # exit code = number of failed checks
```

| # | Scan | From | Expected |
|---|---|---|---|
| 1 | Ping sweep of all 8 lab subnets (`-sn`) | ADMIN-PC | every live host is in NetBox, as an IP or inside a DHCP range. Anything else is **UNDOCUMENTED** |
| 2 | srv01 TCP 22, 53, 80, 3000, 8000, 8081, 8082 (`-sT`) | ADMIN-PC and IT-PC | management UIs open from Admin, *filtered* from IT (UFW); intranet web open to all |
| 3 | Finance PC and HQ-SW1 management SSH | ADMIN-PC and IT-PC | Admin reaches both; IT is blocked (FINANCE-PROTECT, MGMT-PROTECT) |
| 4 | HQ-R1's internet address, top 100 TCP plus UDP 161/53/51820 | remote-admin | no open TCP port. SNMP is silently dropped, reported as `open\|filtered` (EDGE-IN) |
| 5 | UDP 161 with `-sV` and `snmp-info` | ADMIN-PC | 4 SNMPv3 agents; v2c `public` gets no answer |

Raw outputs (normal and XML) are in [testing/results/nmap/](../results/nmap/). Summary:
[T21 evidence](../results/evidence/T21-nmap-audit.txt).

## Reading the results

- **`filtered`** (TCP): no reply. A firewall dropped the SYN, which is what UFW and nftables do here.
- **`open|filtered`** (UDP): no reply either. A *closed* port would answer ICMP port-unreachable, and an *open* SNMP agent would answer. So the edge result shows a silent drop, as designed.
- The sweep also covers DHCP clients. They count as documented because their addresses fall inside the NetBox IP ranges that mirror the Kea pools.

On real hardware, run the same scans from the Admin VLAN and from an IT port. Run the edge scan
from outside the WAN with written authorisation, never against networks you do not own.
