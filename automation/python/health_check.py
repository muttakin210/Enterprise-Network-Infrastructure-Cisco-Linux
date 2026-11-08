#!/usr/bin/env python3
"""Network health check (guide section 7, Python assignment).

Reads device IPs from a CSV inventory, pings each device and checks TCP port 22,
records reachable/unreachable status with a timestamp, appends the results to a
CSV log and prints a short summary. No credentials are used or stored.

    python3 health_check.py                      # devices.csv -> results/health_log.csv
    python3 health_check.py -i devices.csv -o out.csv --port 22 --port 80

Exit code: 0 if every device answered ping, 1 otherwise (useful in cron/CI).
"""
from __future__ import annotations

import argparse
import csv
import ipaddress
import platform
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent


@dataclass
class Device:
    name: str
    ip: str
    site: str = ""
    role: str = ""


@dataclass
class Result:
    timestamp: str
    device: Device
    ping_ok: bool
    rtt_ms: float | None
    ports: dict[int, bool] = field(default_factory=dict)

    @property
    def status(self) -> str:
        return "reachable" if self.ping_ok else "unreachable"


def load_devices(path: Path) -> list[Device]:
    """Read the inventory; rows with an invalid IP are reported and skipped."""
    devices: list[Device] = []
    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            ip = (row.get("ip") or "").strip()
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                print(f"skipping {row.get('name')!r}: invalid IP {ip!r}", file=sys.stderr)
                continue
            devices.append(Device(row["name"].strip(), ip,
                                  (row.get("site") or "").strip(), (row.get("role") or "").strip()))
    return devices


def ping(ip: str, count: int = 2, timeout_s: int = 1) -> tuple[bool, float | None]:
    """Return (reachable, average RTT in ms) using the OS ping command."""
    if platform.system() == "Windows":
        cmd = ["ping", "-n", str(count), "-w", str(timeout_s * 1000), ip]
    else:
        cmd = ["ping", "-c", str(count), "-W", str(timeout_s), "-q", ip]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=count * timeout_s + 5)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False, None
    return out.returncode == 0, parse_rtt(out.stdout)


def parse_rtt(output: str) -> float | None:
    """Extract the average RTT from Linux ('min/avg/max') or Windows ('Average =') ping output."""
    for line in output.splitlines():
        if "min/avg/max" in line and "=" in line:
            try:
                return float(line.split("=")[1].split("/")[1])
            except (IndexError, ValueError):
                return None
        if "Average =" in line:
            try:
                return float(line.split("Average =")[1].strip().rstrip("ms"))
            except ValueError:
                return None
    return None


def tcp_open(ip: str, port: int, timeout_s: float = 2.0) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout_s):
            return True
    except OSError:
        return False


def check(device: Device, ports: list[int]) -> Result:
    ok, rtt = ping(device.ip)
    return Result(
        timestamp=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        device=device,
        ping_ok=ok,
        rtt_ms=rtt,
        ports={p: tcp_open(device.ip, p) for p in ports},
    )


def write_csv(results: list[Result], path: Path, ports: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(["timestamp", "name", "ip", "site", "role", "status", "rtt_ms"]
                       + [f"tcp_{p}" for p in ports])
        for r in results:
            w.writerow([r.timestamp, r.device.name, r.device.ip, r.device.site, r.device.role,
                        r.status, "" if r.rtt_ms is None else f"{r.rtt_ms:.2f}"]
                       + ["open" if r.ports.get(p) else "closed" for p in ports])


def summary(results: list[Result], ports: list[int]) -> str:
    up = sum(r.ping_ok for r in results)
    lines = [f"{'DEVICE':<11} {'IP':<15} {'STATUS':<12} {'RTT ms':>7}  "
             + "  ".join(f"tcp/{p}" for p in ports)]
    for r in results:
        rtt = "-" if r.rtt_ms is None else f"{r.rtt_ms:.2f}"
        lines.append(f"{r.device.name:<11} {r.device.ip:<15} {r.status:<12} {rtt:>7}  "
                     + "  ".join(f"{('open' if r.ports.get(p) else 'closed'):<6}" for p in ports))
    lines.append(f"\n{up}/{len(results)} devices reachable")
    down = [r.device.name for r in results if not r.ping_ok]
    if down:
        lines.append("UNREACHABLE: " + ", ".join(down))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-i", "--inventory", type=Path, default=HERE / "devices.csv")
    ap.add_argument("-o", "--output", type=Path, default=HERE / "results" / "health_log.csv")
    ap.add_argument("--port", type=int, action="append", help="TCP port to test (repeatable, default 22)")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args(argv)
    ports = args.port or [22]

    devices = load_devices(args.inventory)
    if not devices:
        print("no valid devices in inventory", file=sys.stderr)
        return 2
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda d: check(d, ports), devices))
    write_csv(results, args.output, ports)
    print(summary(results, ports))
    print(f"\nresults appended to {args.output}")
    return 0 if all(r.ping_ok for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
