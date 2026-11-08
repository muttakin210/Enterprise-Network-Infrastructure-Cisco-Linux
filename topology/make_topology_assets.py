#!/usr/bin/env python3
"""Generate topology/enterprise-topology.png and topology/addressing-plan.xlsx
from the design (single source: addressing-plan.csv + the device list below)."""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

HERE = Path(__file__).resolve().parent

# ----------------------------------------------------------------- diagram
NODES = {  # name: (x, y, label, kind)
    "HQ-R1":  (3.0, 7.2, "HQ-R1\nRID 1.1.1.1\nG0/0 trunk · G0/1 10.0.12.1", "router"),
    "BR-R2":  (9.0, 7.2, "BR-R2\nRID 2.2.2.2\nG0/0 trunk · G0/1 10.0.12.2", "router"),
    "HQ-SW1": (3.0, 4.6, "HQ-SW1\nVLAN 10,20,50,99\nSVI 192.168.99.2", "switch"),
    "BR-SW1": (9.0, 4.6, "BR-SW1\nVLAN 30,40,199\nSVI 192.168.199.2", "switch"),
    "ADMIN":  (0.75, 1.8, "ADMIN-PC\nVLAN 10\n192.168.10.0/24", "host"),
    "IT":     (2.85, 1.8, "IT-PC\nVLAN 20\n192.168.20.0/24", "host"),
    "SRV":    (5.1, 1.8, "srv01.corp.lab\nVLAN 50 · .50.10\nDNS DHCP Web Syslog NMS", "server"),
    "HR":     (7.9, 1.8, "HR-PC\nVLAN 30\n192.168.30.0/24", "host"),
    "FIN":    (10.1, 1.8, "FIN-PC\nVLAN 40\n192.168.40.0/24", "host"),
}
COLORS = {"router": "#1d4e89", "switch": "#2a7f62", "host": "#5c6770", "server": "#b5562b"}
LINKS = [
    ("HQ-R1", "BR-R2", "WAN 10.0.12.0/30 · OSPF area 0 (p2p)"),
    ("HQ-R1", "HQ-SW1", "802.1Q trunk\n10,20,50,99"),
    ("BR-R2", "BR-SW1", "802.1Q trunk\n30,40,199"),
    ("HQ-SW1", "ADMIN", "G0/1"), ("HQ-SW1", "IT", "G0/2"), ("HQ-SW1", "SRV", "G0/3"),
    ("BR-SW1", "HR", "G0/1"), ("BR-SW1", "FIN", "G0/2"),
]


def draw(path: Path) -> None:
    fig, ax = plt.subplots(figsize=(12, 8.2), dpi=150)
    ax.set_xlim(-0.6, 11.6); ax.set_ylim(0.4, 9.4); ax.axis("off")
    for x0, label, color in ((-0.3, "HEAD OFFICE (HQ)", "#e8f0fa"), (6.55, "BRANCH OFFICE", "#eaf5ef")):
        ax.add_patch(FancyBboxPatch((x0, 0.8), 6.4 if x0 < 0 else 4.9, 7.6,
                                    boxstyle="round,pad=0.05,rounding_size=0.25", fc=color, ec="#c3cfdc", lw=1))
        ax.text(x0 + 0.2, 8.15, label, fontsize=11, fontweight="bold", color="#3e4c59")
    for a, b, lbl in LINKS:
        (x1, y1, *_), (x2, y2, *_) = NODES[a], NODES[b]
        wan = a == "HQ-R1" and b == "BR-R2"
        ax.plot([x1, x2], [y1, y2], color="#b5562b" if wan else "#52606d", lw=2.4 if wan else 1.4,
                ls="--" if wan else "-", zorder=1)
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx, my + (0.28 if wan else 0), lbl, fontsize=7.5 if not wan else 9, ha="center", va="center",
                color="#1f2933", bbox=dict(fc="white", ec="none", alpha=0.85, pad=1.2), zorder=3)
    for name, (x, y, label, kind) in NODES.items():
        w, h = (2.3, 1.15) if kind in ("router", "switch") else (2.0, 1.05)
        ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h, boxstyle="round,pad=0.02,rounding_size=0.15",
                                    fc=COLORS[kind], ec="white", lw=1.5, zorder=2))
        ax.text(x, y, label, fontsize=7.6, ha="center", va="center", color="white", zorder=4, linespacing=1.35)
    ax.text(5.5, 9.05, "Cisco + Linux Enterprise Network — two-site topology", fontsize=14,
            fontweight="bold", ha="center", color="#1f2933")
    ax.text(5.5, 0.55, "Router-on-a-stick gateways .1 on each VLAN · DHCP via ip helper-address 192.168.50.10 · "
            "Mgmt VLANs 99 (HQ) / 199 (Branch)", fontsize=8, ha="center", color="#52606d")
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    print("wrote", path.name)


# ----------------------------------------------------------------- workbook
def workbook(path: Path) -> None:
    rows = list(csv.reader((HERE / "addressing-plan.csv").open()))
    wb = Workbook()
    head_fill = PatternFill("solid", fgColor="1D4E89")
    thin = Side(style="thin", color="C3CFDC")

    def sheet(ws, data):
        for r in data:
            ws.append(r)
        for c in ws[1]:
            c.font = Font(bold=True, color="FFFFFF"); c.fill = head_fill
        for row in ws.iter_rows():
            for c in row:
                c.border = Border(top=thin, bottom=thin, left=thin, right=thin)
                c.alignment = Alignment(vertical="center", wrap_text=True)
        for i, col in enumerate(zip(*data), 1):
            ws.column_dimensions[get_column_letter(i)].width = min(48, max(len(str(v)) for v in col) + 2)
        ws.freeze_panes = "A2"

    ws = wb.active; ws.title = "VLANs & subnets"; sheet(ws, rows)
    sheet(wb.create_sheet("Devices"), [
        ["Device", "Role", "Interface", "Address", "Connected to"],
        ["HQ-R1", "HQ router, OSPF RID 1.1.1.1", "G0/0 (.10/.20/.50/.99)", "192.168.x.1", "HQ-SW1 G0/0 (trunk)"],
        ["HQ-R1", "", "G0/1", "10.0.12.1/30", "BR-R2 G0/1 (WAN)"],
        ["BR-R2", "Branch router, OSPF RID 2.2.2.2", "G0/0 (.30/.40/.199)", "192.168.x.1", "BR-SW1 G0/0 (trunk)"],
        ["BR-R2", "", "G0/1", "10.0.12.2/30", "HQ-R1 G0/1 (WAN)"],
        ["HQ-SW1", "HQ access switch", "Vlan99", "192.168.99.2/24", "G0/1 ADMIN, G0/2 IT, G0/3 SERVER"],
        ["BR-SW1", "Branch access switch", "Vlan199", "192.168.199.2/24", "G0/1 HR, G0/2 FINANCE"],
        ["srv01", "Ubuntu 22.04: DNS, DHCP, Nginx, Syslog, SNMP, Ansible", "br-vlan50", "192.168.50.10/24", "HQ-SW1 G0/3 (VLAN 50)"],
    ])
    sheet(wb.create_sheet("DHCP scopes"), [
        ["VLAN", "Subnet", "Pool", "Router", "DNS", "Domain"],
        *[[v, f"192.168.{v}.0/24", f"192.168.{v}.100 - 192.168.{v}.199", f"192.168.{v}.1", "192.168.50.10", "corp.lab"]
          for v in (10, 20, 30, 40, 60)],
    ])
    wb.save(path)
    print("wrote", path.name)


if __name__ == "__main__":
    draw(HERE / "enterprise-topology.png")
    workbook(HERE / "addressing-plan.xlsx")
