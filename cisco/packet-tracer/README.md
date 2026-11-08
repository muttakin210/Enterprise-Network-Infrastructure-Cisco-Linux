# Packet Tracer build (Cisco Packet Tracer 9.0)

The IOS configs in [`configs/`](configs/) are generated from the IOSv/IOSvL2 configs by
[`make_pt_configs.py`](make_pt_configs.py), so the two never drift:

```bash
python cisco/packet-tracer/make_pt_configs.py
```

## Devices and cabling

| Device | PT model | Port | Connects to | Cable |
|---|---|---|---|---|
| HQ-R1 | ISR 2911 | G0/0 | HQ-SW1 Gi0/1 (trunk) | Copper straight-through |
| HQ-R1 | | G0/1 | BR-R2 G0/1 (WAN) | Copper cross-over |
| BR-R2 | ISR 2911 | G0/0 | BR-SW1 Gi0/1 (trunk) | Copper straight-through |
| HQ-SW1 | 2960-24TT | Fa0/1 | ADMIN-PC | Copper straight-through |
| HQ-SW1 | | Fa0/2 | IT-PC | Copper straight-through |
| HQ-SW1 | | Fa0/3 | SRV01 (Server-PT) | Copper straight-through |
| BR-SW1 | 2960-24TT | Fa0/1 | HR-PC | Copper straight-through |
| BR-SW1 | | Fa0/2 | FIN-PC | Copper straight-through |

## Steps

1. Place the devices and cable them as in the table.
2. On each router or switch, open **CLI**, press Enter, and paste the matching `configs/*.txt`
   after replacing `<ENABLE_SECRET>` / `<NETADMIN_SECRET>` with lab-only values.
3. **SRV01 (Server-PT):** set a static IP of 192.168.50.10/24 with gateway 192.168.50.1, then under Services:
   - DNS: on, A records `srv01.corp.lab` and `www.corp.lab` → 192.168.50.10
   - HTTP: on
   - DHCP: one pool per VLAN (10, 20, 30, 40), default gateway `.1`, DNS 192.168.50.10, start `.100`
   - SYSLOG: on
4. Set each PC to **DHCP** under Desktop → IP Configuration.
5. Save as `enterprise-lab.pkt` in this folder and record evidence (below) in `../../screenshots/`.

## Verification to capture

| Check | Command / action | Expected |
|---|---|---|
| VLANs | `show vlan brief` (switches) | Ports Fa0/1–3 in VLANs 10/20/50 (HQ) or 30/40 (Branch) |
| Trunk | `show interfaces trunk` | Gi0/1 trunking; allowed 10,20,50,99 / 30,40,199; native 999 |
| OSPF | `show ip ospf neighbor` | 2.2.2.2 / 1.1.1.1 FULL on G0/1 |
| Routes | `show ip route ospf` | Remote site subnets learned |
| DHCP | PC → IP Configuration → DHCP | Address from its VLAN, gateway `.1` |
| ACL | IT-PC / HR-PC ping FIN-PC; `show access-lists` | Timeouts; deny counters increment |
| Web/DNS | PC → Web Browser → `http://www.corp.lab` | Page loads |
| Syslog | SRV01 → Services → SYSLOG after `shutdown`/`no shutdown` on G0/1 | `%OSPF-5-ADJCHG` entries |
| Port security | `show port-security interface fa0/1` | Secure-up, sticky MAC learned |

## Packet Tracer limitations (and where they are covered instead)

| Not in PT | Covered by |
|---|---|
| SNMPv3 agent | SNMPv3 tests on the Ubuntu server and emulated devices ([T11](../../testing/results/test-report.md)) |
| `logging source-interface` | Kept in the IOSv configs ([cisco/routers](../routers/)) |
| Attaching the real Ubuntu VM | Namespace emulation ([testing/emulation](../../testing/emulation/)) |
| Ansible / SSH automation from a controller | Emulation ([T12](../../testing/results/test-report.md)) |
