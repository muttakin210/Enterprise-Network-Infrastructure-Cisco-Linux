# Monitoring and centralised logging (guide section 8)

## Syslog — rsyslog on srv01 (192.168.50.10)

- Config: [linux/syslog/10-remote-devices.conf](../linux/syslog/10-remote-devices.conf). It listens on UDP and TCP 514
  through a dedicated ruleset and writes one file per device to `/var/log/remote/<HOST>.log`,
  plus `all-devices.log`. Rotation is weekly, keeping 8 files.
- UFW accepts 514 only from device addresses (VLAN 99/199, the WAN and 192.168.50.1).
- Cisco side: `logging host 192.168.50.10`, `logging trap informational`,
  `service timestamps log datetime msec` ([HQ-R1.cfg](../cisco/routers/HQ-R1.cfg)).
- Evidence: the OSPF `AdjChg` events from the controlled WAN failure arrive within a second
  ([T09](../testing/results/evidence/T09-wan-failure.txt), [T10](../testing/results/evidence/T10-syslog.txt)).

## SNMPv3 — authPriv only

- Devices: `snmp-server group NMS v3 priv access SNMP-NMS` plus a user `monitor` with SHA/AES-128,
  and polling restricted by ACL to 192.168.50.10.
- srv01 agent: [linux/snmp/snmpd.conf](../linux/snmp/snmpd.conf), `rouser monitor priv` and no v1/v2c community.
  Keys are generated on the VM (`/root/lab-secrets.env`) and never committed.
- Emulated devices run the same SNMPv3 user, so the NMS polls real interfaces (`IF-MIB`)
  whose `ifOperStatus` changes during the WAN test.
- Evidence: [T11](../testing/results/evidence/T11-snmpv3.txt) shows authPriv answers from all 5 devices,
  while v2c `public` and wrong keys are refused.

```bash
snmpwalk -v3 -l authPriv -u monitor -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" 192.168.99.1 IF-MIB::ifOperStatus
```

## LibreNMS (extension)

LibreNMS adds dashboards and alert history on top of the SNMPv3 polling verified above.
It needs MariaDB, PHP-FPM and about 1 GB of extra RAM, so on a 16 GB host run it only once the core lab
is stable (guide section 8). See [librenms/README.md](librenms/README.md) for the steps and the
device-add commands that match this lab's SNMPv3 settings.

## Evidence checklist

| Item | Status | Where |
|---|---|---|
| Device availability and uptime | ✅ | `sysUpTime` in T11, health_check.py CSV log (T13) |
| Interface operational state | ✅ | `IF-MIB::ifOperStatus` walk (T11) |
| Syslog events for interface/adjacency changes | ✅ | T09, T10 |
| Test that generated each event | ✅ | T09 procedure (shut/no shut WAN) |
| Dashboard and alert history | Extension | LibreNMS guide |
