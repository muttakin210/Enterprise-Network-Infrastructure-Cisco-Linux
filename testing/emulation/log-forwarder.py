#!/usr/bin/env python3
"""Tail a router log file and forward each new line to a Syslog server (RFC 3164, UDP 514).

Run inside a router namespace so the packet leaves from the router's own interface,
which makes the server see the router's source IP, as with IOS "logging host".

usage: log-forwarder.py HOSTNAME LOGFILE SERVER [PORT]
"""
import os
import socket
import sys
import time

FACILITY_LOCAL7 = 23
SEV = {"emergencies": 0, "alerts": 1, "critical": 2, "errors": 3,
       "warnings": 4, "notifications": 5, "informational": 6, "debugging": 7}


def severity(line: str) -> int:
    low = line.lower()
    if "adjchg" in low or "down" in low:
        return SEV["notifications"]
    if "error" in low:
        return SEV["errors"]
    return SEV["informational"]


def follow(path: str):
    while not os.path.exists(path):
        time.sleep(0.5)
    with open(path, "r", errors="replace") as fh:
        fh.seek(0, os.SEEK_END)
        while True:
            line = fh.readline()
            if line:
                yield line.rstrip("\n")
            else:
                time.sleep(0.3)


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    host, path, server = sys.argv[1], sys.argv[2], sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 514
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for line in follow(path):
        pri = FACILITY_LOCAL7 * 8 + severity(line)
        stamp = time.strftime("%b %d %H:%M:%S")
        msg = f"<{pri}>{stamp} {host} ospfd: {line}"
        try:
            sock.sendto(msg.encode()[:1024], (server, port))
        except OSError:
            pass  # server unreachable (e.g. during the WAN failure test): drop like UDP syslog
    return 0


if __name__ == "__main__":
    sys.exit(main())
