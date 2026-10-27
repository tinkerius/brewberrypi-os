"""Tests for the contract stub. Run: python3 -m unittest discover -s stub"""

import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

STUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "brewberrypi-stub.py")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class StubTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sock_path = os.path.join(self.tmp.name, "notify")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(self.sock_path)
        self.sock.settimeout(5)
        self.addCleanup(self.sock.close)
        self.config = os.path.join(self.tmp.name, "config.json")
        self.port = free_port()

    def start(self, stub_json: dict | None = None, *args: str, version: str = "9.9.9") -> subprocess.Popen:
        if stub_json is not None:
            with open(os.path.join(self.tmp.name, "stub.json"), "w") as f:
                json.dump(stub_json, f)
        env = dict(os.environ, NOTIFY_SOCKET=self.sock_path, BREWBERRYPI_WATCHDOG_MS="200",
                   BREWBERRYPI_STUB_PORT=str(self.port), BREWBERRYPI_STUB_START_DELAY_S="0.1",
                   BREWBERRYPI_STUB_VERSION=version)
        proc = subprocess.Popen([sys.executable, STUB, "--config", self.config, *args], env=env,
                                stdout=subprocess.DEVNULL)
        def stop() -> None:
            if proc.poll() is None:
                proc.kill()
            proc.wait()

        self.addCleanup(stop)
        return proc

    def recv(self) -> str:
        return self.sock.recv(256).decode()

    def http(self, method: str, path: str) -> dict:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.load(resp)

    def test_ready_watchdog_healthz_and_clean_stop(self) -> None:
        proc = self.start()
        messages = {self.recv() for _ in range(3)}
        self.assertIn("READY=1", messages)
        self.assertIn("WATCHDOG=1", messages)
        self.assertEqual(self.http("GET", "/healthz"),
                         {"status": "ok", "version": "9.9.9", "engine": "NoProcess"})
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(5), 0)
        rest = []
        try:
            while True:
                rest.append(self.recv())
        except TimeoutError:
            pass
        self.assertIn("STOPPING=1", rest)

    def page(self, path: str = "/") -> tuple[int, str, str]:
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as resp:
            return resp.status, resp.headers["Content-Type"], resp.read().decode()

    def fetch(self, path: str) -> tuple[int, str, bytes]:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as resp:
                return resp.status, resp.headers["Content-Type"], resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers["Content-Type"], e.read()

    def test_brand_files_and_nothing_else(self) -> None:
        self.start()
        self.assertEqual(self.recv(), "READY=1")
        for path, ctype in (("/favicon.ico", "image/x-icon"), ("/favicon.svg", "image/svg+xml"),
                            ("/static/logo.svg", "image/svg+xml"),
                            ("/static/logo-dark.svg", "image/svg+xml"),
                            ("/static/zilla-slab-medium.woff2", "font/woff2")):
            status, content_type, data = self.fetch(path)
            self.assertEqual((status, content_type), (200, ctype), path)
            self.assertGreater(len(data), 100, path)
        for path in ("/static/OFL.txt", "/static/../brewberrypi-stub.py", "/static/"):
            self.assertEqual(self.fetch(path)[0], 404, path)

    def test_preloaded_placeholder_reports_no_version_number(self) -> None:
        # The preloaded stub is not an app release (scripts/build-stub.sh).
        self.start(version="placeholder")
        self.assertEqual(self.recv(), "READY=1")
        self.assertEqual(self.http("GET", "/healthz"),
                         {"status": "ok", "version": "placeholder", "engine": "NoProcess"})
        body = self.page()[2]
        self.assertIn('<dt>Placeholder</dt><dd><span class="ok">running</span></dd>', body)
        self.assertNotIn("version placeholder", body)

    def test_landing_page_explains_the_placeholder(self) -> None:
        with open(self.config, "w") as f:
            f.write("{}")
        self.start()
        self.assertEqual(self.recv(), "READY=1")
        status, content_type, body = self.page()
        self.assertEqual(status, 200)
        self.assertEqual(content_type, "text/html; charset=utf-8")
        self.assertIn("The brewing app isn't installed yet", body)
        self.assertIn("test version 9.9.9", body)
        self.assertIn("sudo brewberry-update install", body)
        self.assertIn("built-in defaults", body)
        self.assertIn("pinged every 0.2 s", body)
        self.assertIn("<dt>Heater test</dt><dd>off</dd>", body)
        self.assertIn("<dt>Demo mode</dt><dd>off</dd>", body)
        # Nothing from the internet (the Pi may be offline): no scripts, and every file the
        # page loads (logo, font, favicon) comes from the stub itself.
        self.assertNotIn("<script", body)
        loads = re.findall(r'(?:src|srcset|href)="([^"]*)"', body.split("<body>")[0]) + \
            re.findall(r'(?:src|srcset)="([^"]*)"', body) + re.findall(r'url\("([^"]*)"\)', body)
        self.assertTrue(loads)
        for url in loads:
            self.assertTrue(url.startswith("/"), url)
            status, _, _ = self.fetch(url)
            self.assertEqual(status, 200, url)
        self.assertIn("The brewing app isn't installed yet", self.page("/index.html")[2])
        self.assertEqual(self.http("GET", "/healthz")["status"], "ok")  # contract unchanged

    def test_landing_page_shows_an_enabled_heater_test(self) -> None:
        self.start({"allowHeat": True})
        self.assertEqual(self.recv(), "READY=1")
        body = self.page()[2]
        self.assertIn("enabled (allowHeat in stub.json)", body)
        self.assertIn("Only the hardware heater test can switch the heater on", body)

    def test_landing_page_shows_demo_mode(self) -> None:
        self.start(None, "--dummymode")  # brewberry-update demo on
        self.assertEqual(self.recv(), "READY=1")
        self.assertIn("<dt>Demo mode</dt><dd>on: the app will simulate the kettle", self.page()[2])

    def test_hang_stops_watchdog_pings(self) -> None:
        self.start()
        self.assertEqual(self.recv(), "READY=1")
        self.http("POST", "/stub/hang")
        time.sleep(0.5)  # let pings already in flight arrive
        self.sock.settimeout(0.1)
        try:
            while True:
                self.recv()
        except TimeoutError:
            pass
        self.sock.settimeout(1)
        with self.assertRaises(TimeoutError):
            self.recv()

    def test_runtime_exit_code(self) -> None:
        proc = self.start()
        self.assertEqual(self.recv(), "READY=1")
        try:
            self.http("POST", "/stub/exit?code=4")
        except OSError:
            pass  # the process may exit before the reply is complete
        self.assertEqual(proc.wait(5), 4)

    def heat_status(self) -> int:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/stub/heat?on=1", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_heat_is_disabled_by_default(self) -> None:
        self.start()
        self.assertEqual(self.recv(), "READY=1")
        self.assertEqual(self.heat_status(), 403)

    def test_heat_without_gpio_fails_cleanly(self) -> None:
        self.start({"allowHeat": True})
        self.assertEqual(self.recv(), "READY=1")
        self.assertEqual(self.heat_status(), 500)  # no gpiod / GPIO chip here
        self.assertEqual(self.http("GET", "/healthz")["status"], "ok")

    def test_start_modes(self) -> None:
        for mode, code in (("crash", 1), ("config", 2), ("hwfail", 4)):
            with self.subTest(mode=mode):
                proc = self.start({"start": mode})
                self.assertEqual(proc.wait(5), code)

    def test_start_hang_never_sends_ready(self) -> None:
        self.start({"start": "hang"})
        self.sock.settimeout(1)
        with self.assertRaises(TimeoutError):
            self.recv()


if __name__ == "__main__":
    unittest.main()
