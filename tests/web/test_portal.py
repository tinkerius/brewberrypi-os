"""Tests for the redirect on port 80 (ADR-0004, OS11): portal.py.

The redirector runs as a subprocess on a free port on 127.0.0.1. Run by
scripts/lint.sh: python3 -m unittest discover -s tests/web
"""

import http.client
import os
import socket
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORTAL = os.path.join(ROOT, "layer", "brewberry-wifi.rootfs-overlay", "usr", "lib", "brewberry-wifi", "portal.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class PortalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.proc = subprocess.Popen([sys.executable, PORTAL], env=dict(os.environ, BREWBERRY_PORTAL_PORT=str(cls.port)),
                                    stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait()

    def get(self, host, path="/", method="GET"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, headers={"Host": host})
        r = conn.getresponse()
        body = r.read()
        conn.close()
        return r.status, r.getheader("Location"), body

    def test_captive_checks_go_to_the_wifi_page_at_the_local_address(self):
        for host, path in (("captive.apple.com", "/hotspot-detect.html"),
                           ("connectivitycheck.gstatic.com", "/generate_204"),
                           ("www.msftconnecttest.com", "/connecttest.txt")):
            status, location, body = self.get(host, path)
            self.assertEqual((status, location), (302, "http://127.0.0.1:8081/#wifi"), host)
            self.assertIn(b"http://127.0.0.1:8081/#wifi", body)

    def test_own_name_and_addresses_keep_the_host(self):
        name = socket.gethostname().lower()
        self.assertEqual(self.get(f"{name}.local")[1], f"http://{name}.local:8081/")
        self.assertEqual(self.get(name.upper())[1], f"http://{name}:8081/")
        self.assertEqual(self.get("192.168.1.23")[1], "http://192.168.1.23:8081/")
        self.assertEqual(self.get("[fe80::1]:80")[1], "http://[fe80::1]:8081/")

    def test_head_and_post_redirect_too(self):
        self.assertEqual(self.get("example.com", method="HEAD")[:2], (302, "http://127.0.0.1:8081/#wifi"))
        self.assertEqual(self.get("example.com", method="POST")[:2], (302, "http://127.0.0.1:8081/#wifi"))


if __name__ == "__main__":
    unittest.main()
