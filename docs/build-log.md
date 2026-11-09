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
| Packet Tracer 9.0 build ([enterprise-lab.pkt](../cisco/packet-tracer/enterprise-lab.pkt)): 9 devices, generated configs, SRV01 services | ✅ DHCP relay, OSPF, ACLs, DNS, web, Syslog verified ([results](../cisco/packet-tracer/README.md#build-result-2026-11-09)) |
| BR-SW1 in Packet Tracer: trunk native 999, DHCP snooping, BPDU Guard, port security, Rapid-PVST | ✅ ([screenshots 13–14](../screenshots/packet-tracer/)) |
| LibreNMS ([install script](../monitoring/librenms/install-librenms.sh)), VM raised to 3 GB | ✅ 5/5 devices up over SNMPv3, WAN down/up events logged |
| WireGuard remote admin VPN on HQ-R1 ([wireguard-lab.sh](../testing/emulation/wireguard-lab.sh)) | ✅ handshake, permitted routes only, VPN-FILTER blocks Finance |
| Test plan with T16 (WireGuard) and T17 (LibreNMS) | **17/17** |
| Zabbix 8.0 LTS ([install](../monitoring/zabbix/install-zabbix.sh), [API config](../monitoring/zabbix/zabbix-configure.py)) | ✅ 4 SNMPv3 hosts + agent, WAN problem opens/resolves |
| NetBox 4.7.4 ([install](../ipam/netbox/install-netbox.sh), [import](../ipam/netbox/import-lab.py)) | ✅ 2 sites, 10 VLANs, 10 prefixes, 5 devices, 21 interfaces, 12 IPs, 4 cables |
| Grafana 13 ([install](../monitoring/grafana/install-grafana.sh)) with Zabbix + LibreNMS data sources | ✅ provisioned dashboard, read-only accounts |
| Nmap audit ([nmap-audit.sh](../testing/nmap/nmap-audit.sh)) | ✅ 16 live hosts, 0 undocumented; UFW/ACL/edge as designed |
| Packet captures ([capture-lab.sh](../testing/capture/capture-lab.sh)), Wireshark 4.6 on the host | ✅ OSPF, DHCP relay, SNMPv3, WireGuard, Syslog |
| Test plan with T18–T22 | first run 20/22 → after fixes 16–23, **22/22** |

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

| 10 | Packet Tracer rejected lines of the pasted configs (`... log` on ACL entries, `logging trap`, `logging buffered`); the ACLs ended up without their final `deny` | PT's IOS parser lacks these keywords, and a rejected line is skipped silently in a paste | `make_pt_configs.py` drops or rewrites them; `show access-lists` is checked after every paste. |
| 11 | "Invalid DNS entered" on SRV01 | An earlier keystroke batch had already typed into the field, so the address was entered twice | Clear the field fully, then enter the address once. |
| 12 | LibreNMS `composer install`: "Your lock file does not contain a compatible set of packages" | The current LibreNMS (26.11) and its Symfony 8 dependencies require **PHP ≥ 8.4**; the script installed 8.3 | Install `php8.4-*` from `ppa:ondrej/php` and `update-alternatives --set php`. |
| 13 | `lnms migrate`: "No application encryption key has been specified" | `APP_KEY` is normally created by the web installer, which a scripted install skips | The script runs `php artisan key:generate` when `.env` has no key. |
| 14 | `lnms device:add`: "The --seclevel option does not exist"; no devices added | SNMPv3 options were renamed (`--security-name`, `--auth-protocol`, `--auth-password`, `--privacy-protocol`, `--privacy-password`) | Use the new names; checked with `lnms device:add --help`. |
| 15 | T17 SQL failed: "Unknown column 'snmpver'" | LibreNMS 26.10 moved SNMP credentials out of `devices` into the encrypted `secrets` table (via `device_polling_methods`) | T17 joins those tables and checks `secret_type='snmp-v3'` and `last_check_successful=1`. |

| 16 | Zabbix server would not start: "unsupported MariaDB database version (10.6.23). Must be at least (10.11.0)" | Zabbix 8.0 raised the minimum; Ubuntu 22.04 ships 10.6, shared with LibreNMS | `AllowUnsupportedDBVersions=1` (documented override) instead of upgrading the DB under LibreNMS. On a new build use Ubuntu 24.04. |
| 17 | `zabbix-configure.py` re-run: "Incorrect method hostinterface.update" | Not in the Zabbix 8.0 API | Update interfaces through `host.update` with the `interfaceid`. |
| 18 | Grafana Zabbix data source: "No permissions to call hostgroup.get" | Zabbix 8.0 turns API access **off** in the built-in User/Admin roles | Dedicated role `Grafana API read-only` (user type, API allow-list `*.get`). |
| 19 | NetBox 4.7 would not install on stock 22.04 | Needs Python ≥ 3.12 and PostgreSQL ≥ 15 (22.04: 3.10 and 14) | Python 3.12 from deadsnakes, PostgreSQL 17 from PGDG. |
| 20 | Zabbix WAN test (T18) timed out; Grafana WAN traffic "No data" | `ip link set down` (= IOS `shutdown`) makes ifAdminStatus down, the discovery filter drops the port and Zabbix 8 **disables the lost items**. Interface items are also dependent on one SNMP walk, so "check now" on them is refused | Fail the WAN from the far end (carrier loss, admin stays up) and poll the master walk item. Items re-enable on the next discovery. |
| 21 | Nmap: SNMP on the internet side reported `open\|filtered`, the test expected `filtered` | For UDP a silent drop gives no reply, which Nmap can only call `open\|filtered` | Corrected the expectation: a closed port would answer ICMP, an open agent would answer SNMP. |
| 22 | Grafana problems panel empty; state timeline showed "< 2" | Zabbix plugin 6.x panel id is `alexanderzobnin-zabbix-triggers-panel`, and `showProblems` sits at the top level of the query | Fixed the panel type and query; colour-only state timeline. |
| 23 | LibreNMS events 6 h in the future in Grafana | LibreNMS stores local time; Grafana reads SQL datetimes as UTC | Format the time as text in the SQL. |

## Not done

- Nothing from the guide or the requested additions. Possible next step: real Cisco IOS devices (licensed images) polled by the same LibreNMS/Zabbix setup.
