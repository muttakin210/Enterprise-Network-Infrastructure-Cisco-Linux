#!/usr/bin/env python3
"""Configure Zabbix for the lab through its JSON-RPC API (idempotent, stdlib only).

- Replaces the default Admin/zabbix password with ZABBIX_ADMIN_PASS.
- Stores the SNMPv3 keys as *secret* global macros, so they never appear in host settings.
- Creates the host groups and the five lab hosts:
    srv01.corp.lab  -> Zabbix agent 2 (template "Linux by Zabbix agent")
    hq-r1, br-r2, hq-sw1, br-sw1 -> SNMPv3 authPriv SHA1/AES128 (template "Linux by SNMP";
    on real Cisco IOS use "Cisco IOS by SNMP" instead)
- Forces "check now" on discovery rules so interfaces appear in minutes, not after an hour.

Environment: ZABBIX_ADMIN_PASS, SNMP_AUTH, SNMP_PRIV; optional ZABBIX_URL.
"""
import json
import os
import sys
import urllib.request

URL = os.environ.get("ZABBIX_URL", "http://127.0.0.1:8081/api_jsonrpc.php")
ADMIN_PASS = os.environ["ZABBIX_ADMIN_PASS"]

SNMP_HOSTS = [
    # name, ip, group
    ("hq-r1", "192.168.99.1", "Lab/Routers"),
    ("br-r2", "192.168.199.1", "Lab/Routers"),
    ("hq-sw1", "192.168.99.2", "Lab/Switches"),
    ("br-sw1", "192.168.199.2", "Lab/Switches"),
]


class Api:
    def __init__(self, url):
        self.url, self.token, self.n = url, None, 0

    def call(self, method, params=None):
        self.n += 1
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}, "id": self.n}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json-rpc"})
        if self.token and method not in ("apiinfo.version", "user.login"):
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=30) as r:
            res = json.load(r)
        if "error" in res:
            raise RuntimeError(f"{method}: {res['error'].get('data') or res['error']}")
        return res["result"]

    def login(self, user, password):
        try:
            self.token = self.call("user.login", {"username": user, "password": password})
            return True
        except RuntimeError:
            return False


def one(items, key):
    return items[0][key] if items else None


def main():
    api = Api(URL)
    print("Zabbix API", api.call("apiinfo.version"))

    # 1. Admin password: first run uses the documented default, later runs the lab secret
    if not api.login("Admin", ADMIN_PASS):
        if not api.login("Admin", "zabbix"):
            sys.exit("cannot log in as Admin")
        uid = one(api.call("user.get", {"filter": {"username": "Admin"}}), "userid")
        api.call("user.update", {"userid": uid, "current_passwd": "zabbix", "passwd": ADMIN_PASS})
        api.login("Admin", ADMIN_PASS)
        print("Admin password changed from the default")

    # 2. SNMPv3 keys as secret global macros (type 1 = secret text)
    macros = {"{$SNMPV3_USER}": ("monitor", 0),
              "{$SNMPV3_AUTH}": (os.environ["SNMP_AUTH"], 1),
              "{$SNMPV3_PRIV}": (os.environ["SNMP_PRIV"], 1)}
    existing = {m["macro"]: m["globalmacroid"] for m in api.call("usermacro.get", {"globalmacro": True})}
    for name, (value, mtype) in macros.items():
        if name in existing:
            api.call("usermacro.updateglobal", {"globalmacroid": existing[name], "value": value, "type": mtype})
        else:
            api.call("usermacro.createglobal", {"macro": name, "value": value, "type": mtype})

    # 3. Host groups and templates
    gid = {}
    for g in ("Lab/Routers", "Lab/Switches", "Lab/Servers"):
        found = api.call("hostgroup.get", {"filter": {"name": g}})
        gid[g] = one(found, "groupid") or api.call("hostgroup.create", {"name": g})["groupids"][0]
    tid = {t["host"]: t["templateid"] for t in api.call(
        "template.get", {"filter": {"host": ["Linux by SNMP", "Linux by Zabbix agent"]}})}

    snmp_details = {"version": 3, "bulk": 1, "securityname": "{$SNMPV3_USER}", "securitylevel": 2,
                    "authprotocol": 1, "authpassphrase": "{$SNMPV3_AUTH}",   # 1 = SHA1
                    "privprotocol": 1, "privpassphrase": "{$SNMPV3_PRIV}",   # 1 = AES128
                    "contextname": "", "max_repetitions": 10}
    wanted = [(n, ip, g, 2, "161", snmp_details, ["Linux by SNMP"]) for n, ip, g in SNMP_HOSTS]
    wanted.append(("srv01.corp.lab", "127.0.0.1", "Lab/Servers", 1, "10050", None, ["Linux by Zabbix agent"]))

    for name, ip, group, itype, port, details, templates in wanted:
        iface = {"type": itype, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": port}
        if details:
            iface["details"] = details
        hid = one(api.call("host.get", {"filter": {"host": name}}), "hostid")
        spec = {"groups": [{"groupid": gid[group]}],
                "templates": [{"templateid": tid[t]} for t in templates]}
        if hid:
            # Zabbix 8.0 has no hostinterface.update: pass the interface (with its id) to host.update
            iid = one(api.call("host.get", {"hostids": hid, "selectInterfaces": ["interfaceid"]})[0]["interfaces"],
                      "interfaceid")
            api.call("host.update", {"hostid": hid, **spec, "interfaces": [{"interfaceid": iid, **iface}]})
            print(f"updated {name}")
        else:
            api.call("host.create", {"host": name, "interfaces": [iface], **spec})
            print(f"created {name}")

    # The default "Zabbix server" host duplicates srv01: disable it
    zs = one(api.call("host.get", {"filter": {"host": "Zabbix server"}}), "hostid")
    if zs:
        api.call("host.update", {"hostid": zs, "status": 1})

    # 4. Check now: discovery rules (interfaces, filesystems) instead of waiting an hour
    hids = [h["hostid"] for h in api.call("host.get", {"groupids": list(gid.values())})]
    rules = api.call("discoveryrule.get", {"hostids": hids, "output": ["itemid"]})
    if rules:
        api.call("task.create", [{"type": 6, "request": {"itemid": r["itemid"]}} for r in rules])
    print(f"{len(hids)} hosts, {len(rules)} discovery rules scheduled now")

    # 5. Read-only API user for Grafana (only if GRAFANA_ZBX_PASS is set)
    gpass = os.environ.get("GRAFANA_ZBX_PASS")
    if gpass:
        rights = [{"id": g, "permission": 2} for g in gid.values()]          # 2 = read-only
        ug = one(api.call("usergroup.get", {"filter": {"name": "Grafana readers"}}), "usrgrpid")
        if ug:
            api.call("usergroup.update", {"usrgrpid": ug, "hostgroup_rights": rights})
        else:
            ug = api.call("usergroup.create", {"name": "Grafana readers", "gui_access": 3,  # 3 = no GUI
                                               "hostgroup_rights": rights})["usrgrpids"][0]
        # Zabbix 8.0 disables API access in the built-in User/Admin roles, so Grafana gets its own
        # role: user type (read-only by design), API on, and only *.get methods allowed.
        rrules = {"api.access": 1, "api.mode": 1, "api": ["*.get"]}
        role = one(api.call("role.get", {"filter": {"name": "Grafana API read-only"}}), "roleid")
        if role:
            api.call("role.update", {"roleid": role, "rules": rrules})
        else:
            role = api.call("role.create", {"name": "Grafana API read-only", "type": 1,
                                            "rules": rrules})["roleids"][0]
        uid = one(api.call("user.get", {"filter": {"username": "grafana"}}), "userid")
        spec = {"roleid": role, "usrgrps": [{"usrgrpid": ug}], "passwd": gpass}
        if uid:
            api.call("user.update", {"userid": uid, **spec})
        else:
            api.call("user.create", {"username": "grafana", **spec})
        print("API user 'grafana' (read-only, no GUI) ready")


if __name__ == "__main__":
    main()
