#!/usr/bin/env python3
"""Derive Packet Tracer configs from the IOSv/IOSvL2 configs in cisco/routers and cisco/switches.

Packet Tracer models used: ISR 2911 routers, Catalyst 2960-24TT switches.
Changes applied (and why):
  * switch ports  G0/0 -> Gi0/1 (uplink), G0/1..3 -> Fa0/1..3 (2960 port names)
  * unused-port range rewritten for the 2960
  * 'switchport trunk encapsulation dot1q' removed (2960 is dot1q-only)
  * SNMPv3 lines removed (Packet Tracer has no SNMPv3 agent; SNMP is tested on Ubuntu)
  * 'logging source-interface' and buffered size removed (not in PT's parser)
  * 'crypto key generate rsa modulus N' -> PT form 'crypto key generate rsa general-keys modulus N'
Placeholders (<ENABLE_SECRET> etc.) are kept; substitute lab-only values when pasting.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).resolve().parent / "configs"

SWITCH_PORTS = {
    "GigabitEthernet0/0": "GigabitEthernet0/1",
    "GigabitEthernet0/1": "FastEthernet0/1",
    "GigabitEthernet0/2": "FastEthernet0/2",
    "GigabitEthernet0/3": "FastEthernet0/3",
}
UNUSED = {
    "HQ-SW1": "interface range FastEthernet0/4 - 24, GigabitEthernet0/2",
    "BR-SW1": "interface range FastEthernet0/3 - 24, GigabitEthernet0/2",
}
DROP = [
    r"^\s*switchport trunk encapsulation dot1q\s*$",
    r"^\s*snmp-server .*$",
    r"^ip access-list standard SNMP-NMS\s*$",
    r"^\s*logging source-interface .*$",
]


def convert(text: str, name: str, is_switch: bool) -> str:
    out, skip_acl = [], False
    for line in text.splitlines():
        if skip_acl:                      # body of the SNMP-NMS ACL
            if line.startswith(" "):
                continue
            skip_acl = False
        if re.match(r"^ip access-list standard SNMP-NMS", line):
            skip_acl = True
            continue
        if any(re.match(p, line) for p in DROP):
            continue
        line = re.sub(r"^logging buffered \d+ (\w+)", r"logging buffered \1", line)
        line = re.sub(r"crypto key generate rsa modulus (\d+)",
                      r"crypto key generate rsa general-keys modulus \1", line)
        if is_switch:
            if line.startswith("interface range"):
                line = UNUSED[name]
            m = re.match(r"^interface (GigabitEthernet0/[0-3])$", line)
            if m:
                line = "interface " + SWITCH_PORTS[m.group(1)]
            line = line.replace("Target: Cisco IOSvL2 (G0/0 trunk; G0/1-3 access). Adapt port names.",
                                "Target: Packet Tracer 2960-24TT (Gi0/1 trunk; Fa0/x access).")
        else:
            line = re.sub(r"Target: Cisco IOSv / ISR", "Target: Packet Tracer ISR 2911", line)
        out.append(line)
    return "\n".join(out) + "\n"


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for sub, is_switch in (("routers", False), ("switches", True)):
        for cfg in sorted((ROOT / sub).glob("*.cfg")):
            name = cfg.stem
            (OUT / f"{name}.txt").write_text(convert(cfg.read_text(), name, is_switch), newline="\n")
            print("wrote", (OUT / f"{name}.txt").relative_to(ROOT.parent))


if __name__ == "__main__":
    main()
