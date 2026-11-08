"""Unit tests for health_check.py (no network needed):  python3 -m unittest -v"""
import csv
import tempfile
import unittest
from pathlib import Path

import health_check as hc

LINUX_PING = """--- 192.168.50.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 0.081/0.095/0.110/0.014 ms"""

WINDOWS_PING = """Approximate round trip times in milli-seconds:
    Minimum = 1ms, Maximum = 3ms, Average = 2ms"""


class ParseRtt(unittest.TestCase):
    def test_linux(self):
        self.assertAlmostEqual(hc.parse_rtt(LINUX_PING), 0.095)

    def test_windows(self):
        self.assertEqual(hc.parse_rtt(WINDOWS_PING), 2.0)

    def test_no_reply(self):
        self.assertIsNone(hc.parse_rtt("100% packet loss"))


class Inventory(unittest.TestCase):
    def test_invalid_ip_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "inv.csv"
            p.write_text("name,ip,site,role\nA,192.168.99.1,HQ,router\nB,999.1.1.1,HQ,router\n")
            devs = hc.load_devices(p)
        self.assertEqual([x.name for x in devs], ["A"])


class Output(unittest.TestCase):
    def _results(self):
        d = hc.Device("HQ-R1", "192.168.99.1", "HQ", "router")
        return [hc.Result("2026-11-09T00:00:00+00:00", d, True, 0.5, {22: True}),
                hc.Result("2026-11-09T00:00:00+00:00", hc.Device("BR-R2", "192.168.199.1"), False, None, {22: False})]

    def test_csv_header_written_once(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "log.csv"
            hc.write_csv(self._results(), out, [22])
            hc.write_csv(self._results(), out, [22])
            rows = list(csv.reader(out.open()))
        self.assertEqual(rows[0][0], "timestamp")
        self.assertEqual(len(rows), 5)
        self.assertEqual(rows[2][5], "unreachable")
        self.assertEqual(rows[1][7], "open")

    def test_summary_lists_unreachable(self):
        s = hc.summary(self._results(), [22])
        self.assertIn("1/2 devices reachable", s)
        self.assertIn("UNREACHABLE: BR-R2", s)


if __name__ == "__main__":
    unittest.main()
