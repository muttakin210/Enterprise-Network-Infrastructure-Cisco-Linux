#!/usr/bin/env python3
"""Print what NetBox says *should* be on the network, one entry per line:
    ip <address>            documented IP addresses (devices, gateways, SVIs, server)
    range <start> <end>     DHCP pools (any lease inside is expected)
Used by testing/nmap/nmap-audit.sh to compare a live Nmap sweep with the source of truth.
Env: NETBOX_ADMIN_PASS; optional NETBOX_URL. A temporary API token is created and deleted.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module  # noqa: E402

lab = import_module("import-lab")


def main():
    auth, token_id = lab.get_token()
    try:
        for a in lab.req("GET", "/api/ipam/ip-addresses/?limit=500", auth=auth)["results"]:
            print("ip", a["address"].split("/")[0], a.get("dns_name") or "")
        for r in lab.req("GET", "/api/ipam/ip-ranges/?limit=100", auth=auth)["results"]:
            print("range", r["start_address"].split("/")[0], r["end_address"].split("/")[0])
    finally:
        lab.req("DELETE", f"/api/users/tokens/{token_id}/", auth=auth)


if __name__ == "__main__":
    main()
