# Build log

What was built on this PC (Windows 11, 16 GB, VirtualBox 7.2, Packet Tracer 9.0), and the
real problems hit along the way. Each problem is recorded with its root cause, because those
are the most useful part of a lab write-up.

## 2026-11-09

| Step | Result |
|---|---|
| Read the lab guide (14 pages); mapped it to this repo layout (guide section 12) | ✅ |
| Wrote IOSv/IOSvL2 configs for HQ-R1, BR-R2, HQ-SW1, BR-SW1, adding hardening, ACLs, SNMPv3, Syslog and DHCP relay | ✅ |
| Created VirtualBox VM `ENL-Ubuntu-Server` (Ubuntu 22.04.5, unattended install, 2 vCPU / 2 GB / 30 GB) | ✅ |
| `linux/setup-server.sh`: Nginx, BIND9, Kea, rsyslog, SNMPv3, UFW, SSH hardening | ✅ all services active on first run |
| Namespace emulation of the topology (FRR OSPF, dhcrelay, nftables ACLs, sshd, snmpd) | ✅ OSPF Full |
| Test plan `run-tests.sh` | first run 9/15 → after the fixes below, **15/15** |
| Troubleshooting challenges `run-challenges.sh` | **10/10** faults diagnosed and fixed |

## Problems found and fixed

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | VirtualBox could not create a host-only adapter ("Could not find Host Interface Networking driver") | The VirtualBox network driver is not installed on this host | Used NAT with port forwards bound to 127.0.0.1, plus an internal network `enl-vlan50` for the lab NIC. Reinstalling VirtualBox would have stopped other running VMs. |
| 2 | SSH answered during the install but refused the login after reboot | The SSH banner came from the **installer** environment; the unattended install did not include `openssh-server` | Logged in on the console (`VBoxManage keyboardputstring`) and installed it. `setup-server.sh` installs it too. |
| 3 | Branch clients (VLAN 30/40) got no DHCP lease while HQ clients did | `dhcrelay` on BR-R2 relays from its **upstream** interface, so requests reach Kea from 10.0.12.2. UFW only allowed udp/67 from 192.168.0.0/16. | Added a UFW rule for udp/67 from 10.0.12.0/30. |
| 4 | Clients could not resolve `www.corp.lab` (T05/T06) | Ubuntu's `dhclient-script` passes DNS to systemd-resolved, which is not running inside the namespace, so `resolv.conf` kept `127.0.0.53` | The emulation writes the leased DNS server and search domain into `/etc/netns/<pc>/resolv.conf`. |
| 5 | Traceroute to the server showed only `*` after the gateway (T04) | UDP traceroute probes hit UFW's default deny, so no ICMP port-unreachable is returned | Use ICMP traceroute (`-I`). Echo requests are allowed by UFW's `before.rules`. |
| 6 | `snmpget ... SNMPv2-MIB::sysName.0` → "Unknown Object Identifier" (T11) | Ubuntu ships without the MIB files (`mibs :` line in `/etc/snmp/snmp.conf`) | Install `snmp-mibs-downloader` and comment out `mibs :`. |
| 7 | SNMP keys appeared in evidence files | The test log echoed the full `snmpget` command line | Evidence is redacted (`<SNMP_AUTH>`/`<SNMP_PRIV>`) before it leaves the VM, and every exported file is scanned for the real secrets before commit. |
| 8 | Ansible backup failed: "Destination directory … does not exist" (T12) | The playbook assumed `backups/raw` existed | Added a task that creates `raw/` and `sanitized/` on the controller. |
| 9 | Checks failed although the output looked right (T14) | `set -o pipefail` plus `cmd \| grep -q`: grep exits at the first match, cmd gets SIGPIPE, and the pipeline returns non-zero | Removed `pipefail` from the test scripts. |

## Not done

- Driving Packet Tracer's GUI: automated control was not granted in this session. The topology,
  generated configs and verification checklist are ready in [cisco/packet-tracer](../cisco/packet-tracer/).
- LibreNMS dashboard (documented extension), WireGuard (optional in the guide).
