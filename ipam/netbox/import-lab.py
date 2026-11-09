#!/usr/bin/env python3
"""Load the lab into NetBox through its REST API (idempotent, stdlib only).

Source of truth for addressing is topology/addressing-plan.csv; device and interface layout
follows the IOS configs in cisco/. Creates: sites, VLANs, prefixes (+ DHCP ranges),
manufacturer/device types/roles, the five devices, their interfaces (802.1Q modes, parent
subinterfaces), IP addresses (primary IPs, DNS names) and the physical cables.

Usage: NETBOX_ADMIN_PASS=... import-lab.py topology/addressing-plan.csv
Optional: NETBOX_URL (default http://127.0.0.1:8082)
"""
import csv
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("NETBOX_URL", "http://127.0.0.1:8082").rstrip("/")
HDR = {"Content-Type": "application/json", "Accept": "application/json"}


def req(method, path, data=None, auth=None):
    r = urllib.request.Request(BASE + path, json.dumps(data).encode() if data is not None else None,
                               dict(HDR, **({"Authorization": auth} if auth else {})), method=method)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path}: {e.code} {e.read().decode()[:400]}") from None


def get_token():
    """Provision an API token for admin (v2 tokens on NetBox >= 4.5, v1 before)."""
    t = req("POST", "/api/users/tokens/provision/",
            {"username": "admin", "password": os.environ["NETBOX_ADMIN_PASS"],
             "description": "import-lab.py"})
    candidates = []
    if t.get("version") == 2 or t.get("token", "").startswith("nbt_"):
        tok = t.get("token", "")
        candidates.append("Bearer " + (tok if tok.startswith("nbt_") else f"nbt_{t['key']}.{tok}"))
    for k in ("token", "key"):
        if t.get(k):
            candidates.append(f"Token {t[k]}")
    for auth in candidates:
        try:
            req("GET", "/api/status/", auth=auth)
            return auth, t["id"]
        except RuntimeError:
            continue
    sys.exit(f"could not use the provisioned token (fields: {sorted(t)})")


class NB:
    def __init__(self, auth):
        self.auth = auth

    def find(self, ep, **flt):
        q = "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in flt.items())
        res = req("GET", f"/api/{ep}/?{q}&limit=2", auth=self.auth)["results"]
        return res[0] if res else None

    def ensure(self, ep, lookup, data):
        """Create or update one object; `lookup` are the filters that identify it."""
        obj = self.find(ep, **lookup)
        if obj:
            return req("PATCH", f"/api/{ep}/{obj['id']}/", data, auth=self.auth)
        return req("POST", f"/api/{ep}/", data, auth=self.auth)


def slug(s):
    return "".join(c if c.isalnum() else "-" for c in s.lower()).strip("-")


def main(csv_path):
    auth, token_id = get_token()
    nb = NB(auth)
    status = req("GET", "/api/status/", auth=auth)
    print("NetBox", status.get("netbox-version"))

    # --- organisation
    site = {}
    for name, desc in (("HQ", "Head office: Admin, IT, Servers, Management"),
                       ("Branch", "Branch office: HR, Finance, Management")):
        site[name] = nb.ensure("dcim/sites", {"slug": slug(name)},
                               {"name": name, "slug": slug(name), "status": "active", "description": desc})["id"]

    # --- VLANs and prefixes from the addressing plan
    vlan = {}   # (site, vid) -> id
    rows = list(csv.DictReader(open(csv_path, encoding="utf-8")))
    for r in rows:
        sites = ["HQ", "Branch"] if r["Site"] == "Both" else [r["Site"]] if r["Site"] in site else []
        for s in sites:
            if r["VLAN"].isdigit():
                v = nb.ensure("ipam/vlans", {"site_id": site[s], "vid": r["VLAN"]},
                              {"site": site[s], "vid": int(r["VLAN"]), "name": r["Name"],
                               "status": "reserved" if r["VLAN"] == "60" else "active",
                               "description": r["Purpose"]})
                vlan[(s, int(r["VLAN"]))] = v["id"]
        if r["Subnet"] == "-":
            continue
        data = {"prefix": r["Subnet"], "description": f'{r["Name"]}: {r["Purpose"]}',
                "status": "reserved" if r["VLAN"] == "60" else "active",
                "comments": f'Gateway {r["Gateway"]} ({r["Gateway device"]}). {r["Notes"]}'}
        if r["Site"] in site:
            data.update(scope_type="dcim.site", scope_id=site[r["Site"]])
        if r["VLAN"].isdigit():
            data["vlan"] = vlan[(r["Site"], int(r["VLAN"]))]
        nb.ensure("ipam/prefixes", {"prefix": r["Subnet"]}, data)
        # DHCP pools (Kea) on the client VLANs
        if r["VLAN"] in ("10", "20", "30", "40"):
            net = r["Subnet"].rsplit(".", 1)[0]
            nb.ensure("ipam/ip-ranges", {"start_address": f"{net}.100/24"},
                      {"start_address": f"{net}.100/24", "end_address": f"{net}.199/24",
                       "status": "active", "description": f'Kea DHCP pool {r["Name"]}'})
    nb.ensure("ipam/prefixes", {"prefix": "10.99.0.0/24"},
              {"prefix": "10.99.0.0/24", "status": "active",
               "description": "WireGuard remote-admin pool (HQ-R1 wg0)"})

    # --- device types and roles
    vendor = {}
    for m in ("Cisco", "Canonical"):
        vendor[m] = nb.ensure("dcim/manufacturers", {"slug": slug(m)}, {"name": m, "slug": slug(m)})["id"]
    dtype = {}
    for m, model, desc in (("Cisco", "IOSv", "ISR 2911 in Packet Tracer"),
                           ("Cisco", "IOSvL2", "Catalyst 2960-24TT in Packet Tracer"),
                           ("Canonical", "Ubuntu Server VM", "VirtualBox VM, Ubuntu 22.04")):
        dtype[model] = nb.ensure("dcim/device-types", {"slug": slug(model)},
                                 {"manufacturer": vendor[m], "model": model, "slug": slug(model),
                                  "u_height": 1, "comments": desc})["id"]
    role = {}
    for name, color in (("Router", "2196f3"), ("Switch", "4caf50"), ("Server", "9c27b0")):
        role[name] = nb.ensure("dcim/device-roles", {"slug": slug(name)},
                               {"name": name, "slug": slug(name), "color": color})["id"]

    devices = {
        "HQ-R1": ("HQ", "IOSv", "Router"), "BR-R2": ("Branch", "IOSv", "Router"),
        "HQ-SW1": ("HQ", "IOSvL2", "Switch"), "BR-SW1": ("Branch", "IOSvL2", "Switch"),
        "srv01": ("HQ", "Ubuntu Server VM", "Server"),
    }
    dev = {}
    for name, (s, t, ro) in devices.items():
        dev[name] = nb.ensure("dcim/devices", {"name": name},
                              {"name": name, "site": site[s], "device_type": dtype[t], "role": role[ro],
                               "status": "active"})["id"]

    # --- interfaces
    def iface(device, name, itype="1000base-t", **extra):
        return nb.ensure("dcim/interfaces", {"device_id": dev[device], "name": name},
                         {"device": dev[device], "name": name, "type": itype, **extra})["id"]

    ifs = {}
    def ip(address, device, ifname, dns="", primary=False, desc=""):
        obj = nb.ensure("ipam/ip-addresses", {"address": address},
                        {"address": address, "status": "active", "dns_name": dns, "description": desc,
                         "assigned_object_type": "dcim.interface",
                         "assigned_object_id": ifs[(device, ifname)]})
        if primary:
            req("PATCH", f"/api/dcim/devices/{dev[device]}/", {"primary_ip4": obj["id"]}, auth=auth)

    routers = {"HQ-R1": ("HQ", "TRUNK-TO-HQ-SW1", {10: "ADMIN", 20: "IT", 50: "SERVERS", 99: "MANAGEMENT"},
                         "10.0.12.1/30", "WAN-to-BR-R2"),
               "BR-R2": ("Branch", "TRUNK-TO-BR-SW1", {30: "HR", 40: "FINANCE", 199: "MANAGEMENT"},
                         "10.0.12.2/30", "WAN-to-HQ-R1")}
    for r, (s, trunk_desc, subs, wan_ip, wan_desc) in routers.items():
        parent = iface(r, "GigabitEthernet0/0", description=trunk_desc)
        ifs[(r, "GigabitEthernet0/0")] = parent
        for vid, nm in subs.items():
            n = f"GigabitEthernet0/0.{vid}"
            ifs[(r, n)] = iface(r, n, "virtual", parent=parent, mode="access",
                                untagged_vlan=vlan[(s, vid)], description=f"VLAN{vid}-{nm}")
            ip(f"192.168.{vid}.1/24", r, n, desc=f"Gateway VLAN {vid}",
               primary=vid in (99, 199), dns=f"{r.lower()}.corp.lab" if vid in (99, 199) else "")
        ifs[(r, "GigabitEthernet0/1")] = iface(r, "GigabitEthernet0/1", description=wan_desc)
        ip(wan_ip, r, "GigabitEthernet0/1", desc="OSPF area 0 point-to-point")

    switches = {"HQ-SW1": ("HQ", "TRUNK-TO-HQ-R1", [10, 20, 50, 99],
                           {1: (10, "ADMIN-PC"), 2: (20, "IT-PC"), 3: (50, "UBUNTU-SERVER")}, 99, "192.168.99.2/24"),
                "BR-SW1": ("Branch", "TRUNK-TO-BR-R2", [30, 40, 199],
                           {1: (30, "HR-PC"), 2: (40, "FINANCE-PC")}, 199, "192.168.199.2/24")}
    for sw, (s, trunk_desc, allowed, access, mgmt_vid, mgmt_ip) in switches.items():
        ifs[(sw, "GigabitEthernet0/0")] = iface(
            sw, "GigabitEthernet0/0", description=trunk_desc, mode="tagged",
            untagged_vlan=vlan[(s, 999)], tagged_vlans=[vlan[(s, v)] for v in allowed])
        for port, (vid, desc) in access.items():
            n = f"GigabitEthernet0/{port}"
            ifs[(sw, n)] = iface(sw, n, description=desc, mode="access", untagged_vlan=vlan[(s, vid)])
        n = f"Vlan{mgmt_vid}"
        ifs[(sw, n)] = iface(sw, n, "virtual", description="MANAGEMENT-SVI")
        ip(mgmt_ip, sw, n, primary=True, dns=f"{sw.lower()}.corp.lab", desc="Management SVI")

    ifs[("srv01", "enp0s8")] = iface("srv01", "enp0s8", description="VLAN 50 access (bridge br-vlan50)")
    ip("192.168.50.10/24", "srv01", "enp0s8", dns="srv01.corp.lab", primary=True,
       desc="DNS, DHCP, web, Syslog, SNMP, LibreNMS, Zabbix, NetBox, Grafana")

    # --- cables
    def cable(a, b, label):
        ida, idb = ifs[a], ifs[b]
        existing = req("GET", f"/api/dcim/interfaces/{ida}/", auth=auth).get("cable")
        if existing:
            return
        req("POST", "/api/dcim/cables/", {
            "a_terminations": [{"object_type": "dcim.interface", "object_id": ida}],
            "b_terminations": [{"object_type": "dcim.interface", "object_id": idb}],
            "status": "connected", "label": label}, auth=auth)

    cable(("HQ-R1", "GigabitEthernet0/1"), ("BR-R2", "GigabitEthernet0/1"), "WAN")
    cable(("HQ-R1", "GigabitEthernet0/0"), ("HQ-SW1", "GigabitEthernet0/0"), "HQ trunk")
    cable(("BR-R2", "GigabitEthernet0/0"), ("BR-SW1", "GigabitEthernet0/0"), "Branch trunk")
    cable(("HQ-SW1", "GigabitEthernet0/3"), ("srv01", "enp0s8"), "srv01")

    # --- summary
    for ep in ("dcim/sites", "ipam/vlans", "ipam/prefixes", "ipam/ip-ranges", "dcim/devices",
               "dcim/interfaces", "ipam/ip-addresses", "dcim/cables"):
        print(f"{ep:20} {req('GET', f'/api/{ep}/?limit=1', auth=auth)['count']}")

    # the import token is single-use: remove it
    req("DELETE", f"/api/users/tokens/{token_id}/", auth=auth)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "topology/addressing-plan.csv")
