#!/usr/bin/env python3
"""Capture portfolio screenshots of the lab web UIs with headless Chromium (Playwright).

Runs on the Windows host against the VirtualBox NAT forwards (127.0.0.1:8081/8082/3000).
Passwords are read from a local, git-ignored file (KEY=value lines), never from the command line:
    python testing/screenshots/capture-ui.py .lab-local/ui-admin.txt
Output: screenshots/{zabbix,netbox,grafana}/*.png
"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "screenshots"


def secrets(path):
    return dict(line.strip().split("=", 1) for line in Path(path).read_text().splitlines() if "=" in line)


def shot(page, url, out, wait_ms=2500, full=False):
    page.goto(url, wait_until="networkidle")
    page.wait_for_timeout(wait_ms)
    out.parent.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(out), full_page=full)
    print("saved", out.relative_to(ROOT))


def main(secret_file):
    s = secrets(secret_file)
    with sync_playwright() as p:
        browser = p.chromium.launch()

        # --- Zabbix
        page = browser.new_context(viewport={"width": 1400, "height": 850}).new_page()
        z = "http://127.0.0.1:8081"
        page.goto(z + "/")
        page.fill("#name", "Admin")
        page.fill("#password", s["ZABBIX_ADMIN_PASS"])
        page.click("#enter")
        page.wait_for_load_state("networkidle")
        shot(page, z + "/zabbix.php?action=host.view", SHOTS / "zabbix/01-hosts-snmpv3-agent.png")
        shot(page, z + "/zabbix.php?action=problem.view&show=2&from=now-3h&to=now&filter_set=1",
             SHOTS / "zabbix/02-problems-wan-link-down.png")
        shot(page, z + "/zabbix.php?action=latest.view&hostids%5B%5D=&name=g0-1&filter_set=1",
             SHOTS / "zabbix/03-latest-data-wan-g0-1.png")

        # --- NetBox
        page = browser.new_context(viewport={"width": 1400, "height": 850}).new_page()
        nb = "http://127.0.0.1:8082"
        page.goto(nb + "/login/")
        page.fill("input[name=username]", "admin")
        page.fill("input[name=password]", s["NETBOX_ADMIN_PASS"])
        page.click("button[type=submit]")
        page.wait_for_load_state("networkidle")
        shot(page, nb + "/ipam/prefixes/", SHOTS / "netbox/01-prefixes.png")
        shot(page, nb + "/ipam/vlans/", SHOTS / "netbox/02-vlans.png")
        shot(page, nb + "/dcim/devices/", SHOTS / "netbox/03-devices.png")
        shot(page, nb + "/dcim/interfaces/?q=&device=HQ-SW1&device=HQ-R1", SHOTS / "netbox/04-interfaces-hq.png")

        # --- Grafana
        page = browser.new_context(viewport={"width": 1600, "height": 1000}).new_page()
        g = "http://127.0.0.1:3000"
        page.goto(g + "/login")
        page.fill("input[name=user]", "admin")
        page.fill("input[name=password]", s["GRAFANA_ADMIN_PASS"])
        page.click("button[type=submit]")
        page.wait_for_load_state("networkidle")
        shot(page, g + "/d/enl-lab-overview/enl-lab-overview?orgId=1&from=now-3h&to=now&kiosk",
             SHOTS / "grafana/01-enl-lab-overview.png", wait_ms=8000)
        browser.close()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".lab-local/ui-admin.txt"))
