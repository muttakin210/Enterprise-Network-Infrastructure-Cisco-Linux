# OSPF design

| Item | HQ-R1 | BR-R2 |
|---|---|---|
| Process / area | `ospf 1`, area 0 | `ospf 1`, area 0 |
| Router ID | 1.1.1.1 | 2.2.2.2 |
| WAN | G0/1 10.0.12.1/30 | G0/1 10.0.12.2/30 |
| WAN network type | point-to-point (no DR/BDR on a /30) | point-to-point |
| Advertised LANs | 10, 20, 50, 99 | 30, 40, 199 |
| Passive interfaces | all except G0/1 | all except G0/1 |

`passive-interface default` stops OSPF hellos leaking onto user VLANs, where a rogue
device could otherwise form an adjacency and inject routes. The LAN subnets are still advertised.

## Expected verification output

```
HQ-R1# show ip ospf neighbor
Neighbor ID     Pri   State           Dead Time   Address         Interface
2.2.2.2           0   FULL/  -        00:00:35    10.0.12.2       GigabitEthernet0/1

HQ-R1# show ip route ospf
O     192.168.30.0/24 [110/2] via 10.0.12.2, GigabitEthernet0/1
O     192.168.40.0/24 [110/2] via 10.0.12.2, GigabitEthernet0/1
O     192.168.199.0/24 [110/2] via 10.0.12.2, GigabitEthernet0/1
```

## Optional hardening

```
interface GigabitEthernet0/1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 <OSPF_KEY>
```

## WAN failure test (guide section 10)

1. `HQ-R1(config)# interface g0/1` → `shutdown`
2. Expect `%OSPF-5-ADJCHG: Process 1, Nbr 2.2.2.2 on GigabitEthernet0/1 from FULL to DOWN`
   on the console and on the Syslog server (`/var/log/remote/HQ-R1.log`).
3. `show ip route ospf` is empty; branch pings fail.
4. `no shutdown` → adjacency returns to FULL within about 10 s and routes are reinstalled.
