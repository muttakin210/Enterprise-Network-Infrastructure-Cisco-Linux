# Known limitations

| Area | Limitation | Mitigation in this repo |
|---|---|---|
| Cisco images | No licensed IOSv/IOSvL2 images, so GNS3 with Cisco nodes was not used (the guide forbids unofficial images). | IOS configs target IOSv/IOSvL2 and are converted for Packet Tracer 9.0 (2911/2960), where the topology is built and verified ([results](../cisco/packet-tracer/README.md#build-result-2026-11-09)). |
| Packet Tracer | Cannot connect to external VMs and has no SNMPv3 agent. | End-to-end tests run on a namespace emulation of the same design. SNMPv3 is tested there. |
| Emulation fidelity | Linux bridges, FRR and nftables behave like, but are not, IOS. Port security, DHCP snooping and BPDU Guard have no emulated equivalent. | Those controls are configured in the IOS configs and verified in Packet Tracer ([screenshot](../screenshots/packet-tracer/10-hq-sw1-security.jpg)). |
| ACL semantics | nftables chains mirror the stateless Cisco ACLs rule for rule (outbound on the protected subinterface). | Same permit/deny order. Counters shown in T07/T08. |
| Hypervisor | VirtualBox instead of VMware (already installed on this PC). The host-only adapter driver is missing, so the VM is reached through NAT port forwards. | Forwards: SSH 2222, HTTP 8080, LibreNMS 8000, DNS 5353, Syslog 5514/udp, SNMP 1161/udp (all bound to 127.0.0.1). |
| WireGuard | IOS has no WireGuard, so the tunnel ends on HQ-R1's Linux emulation, not on IOS. | Same policy as an IOS IPsec/IKEv2 remote-access VPN with an inbound filter ([linux/wireguard](../linux/wireguard/README.md)). Tested in T16. |
| LibreNMS | Polls the emulated devices (detected as `os=linux`), not real IOS. Needs the VM at 3 GB. | Same SNMPv3 user/algorithms as the IOS configs, so the add command is unchanged for real devices (T17). |
| Guest VLAN 60 | Optional extension config provided, not part of the base topology. | [guest-vlan60-extension.cfg](../cisco/security/guest-vlan60-extension.cfg); Kea already has the scope. |
