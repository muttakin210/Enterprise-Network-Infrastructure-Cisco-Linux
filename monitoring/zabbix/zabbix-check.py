#!/usr/bin/env python3
"""Zabbix checks used by testing/run-tests.sh (T18). Stdlib only.

  zabbix-check.py hosts                     availability of every enabled host (exit 1 if any is down)
  zabbix-check.py poll HOST ITEM_REGEX      'check now' for matching items (no wait for the interval)
  zabbix-check.py problem HOST TEXT [--resolved] [--timeout S] [--since EPOCH]
                                            wait until a problem whose name contains TEXT is open
                                            (or, with --resolved, has been resolved) on HOST
Env: ZABBIX_ADMIN_PASS (or ZABBIX_USER/ZABBIX_PASS); optional ZABBIX_URL.
"""
import json
import os
import re
import sys
import time
import urllib.request

URL = os.environ.get("ZABBIX_URL", "http://127.0.0.1:8081/api_jsonrpc.php")


def call(method, params, token=None):
    r = urllib.request.Request(URL, json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode(),
                               {"Content-Type": "application/json-rpc"})
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    res = json.load(urllib.request.urlopen(r, timeout=30))
    if "error" in res:
        sys.exit(f"{method}: {res['error'].get('data')}")
    return res["result"]


def login():
    return call("user.login", {"username": os.environ.get("ZABBIX_USER", "Admin"),
                               "password": os.environ.get("ZABBIX_PASS") or os.environ["ZABBIX_ADMIN_PASS"]})


def hostid(tok, host):
    h = call("host.get", {"filter": {"host": host}, "output": ["hostid"]}, tok)
    if not h:
        sys.exit(f"no host {host}")
    return h[0]["hostid"]


def cmd_hosts(tok):
    down = 0
    print(f"{'host':16} {'interface':22} {'type':6} available")
    for h in call("host.get", {"output": ["host"], "filter": {"status": 0},
                               "selectInterfaces": ["ip", "port", "type", "available", "details"]}, tok):
        i = h["interfaces"][0]
        kind = {"1": "agent", "2": f"snmpv{i['details'].get('version', '?') if i['details'] else '?'}"}.get(i["type"], i["type"])
        ok = i["available"] == "1"
        down += not ok
        print(f"{h['host']:16} {i['ip'] + ':' + i['port']:22} {kind:6} {'yes' if ok else 'NO'}")
    return 1 if down else 0


def cmd_poll(tok, host, rx):
    allitems = {i["itemid"]: i for i in call("item.get", {"hostids": hostid(tok, host),
                "output": ["itemid", "name", "type", "master_itemid"]}, tok)}
    items = [i for i in allitems.values() if re.search(rx, i["name"])]
    # interface items are dependent items (type 18) of one SNMP walk: poll the master item
    targets = {}
    for i in items:
        t = allitems.get(i["master_itemid"], i) if i["type"] == "18" else i
        targets[t["itemid"]] = t
    if targets:
        call("task.create", [{"type": 6, "request": {"itemid": k}} for k in targets], tok)
    for i in items:
        print("matched:", i["name"])
    for t in targets.values():
        print("check now:", t["name"])
    return 0 if targets else 1


def cmd_problem(tok, host, text, resolved=False, timeout=180, since=None):
    """Only events that started at or after `since` (default: 60 s before the call) count."""
    hid = hostid(tok, host)
    start = time.time()
    since = int(since or start - 60)
    while time.time() - start < timeout:
        evs = call("event.get", {"hostids": hid, "source": 0, "object": 0, "value": 1, "output": "extend",
                                 "selectAcknowledges": "count", "sortfield": ["clock"], "sortorder": "DESC",
                                 "time_from": since, "limit": 10}, tok)
        for e in evs:
            if text in e["name"] and (not resolved or e["r_eventid"] != "0"):
                state = "RESOLVED" if e["r_eventid"] != "0" else "PROBLEM"
                print(f"{time.strftime('%H:%M:%S', time.localtime(int(e['clock'])))} {state:8} "
                      f"severity={e['severity']} {host}: {e['name']}  (after {int(time.time() - start)}s)")
                return 0
        time.sleep(5)
    print(f"timeout: no {'resolved ' if resolved else ''}problem '{text}' on {host}")
    return 1


def main(a):
    tok = login()
    if a[:1] == ["hosts"]:
        return cmd_hosts(tok)
    if a[:1] == ["poll"] and len(a) == 3:
        return cmd_poll(tok, a[1], a[2])
    if a[:1] == ["problem"] and len(a) >= 3:
        t = int(a[a.index("--timeout") + 1]) if "--timeout" in a else 180
        since = int(a[a.index("--since") + 1]) if "--since" in a else None
        return cmd_problem(tok, a[1], a[2], "--resolved" in a, t, since)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
