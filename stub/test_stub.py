"""Tests for the contract stub. Run: python3 -m unittest discover -s stub"""

import json
import os
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

    def start(self, stub_json: dict | None = None) -> subprocess.Popen:
        if stub_json is not None:
            with open(os.path.join(self.tmp.name, "stub.json"), "w") as f:
                json.dump(stub_json, f)
        env = dict(os.environ, NOTIFY_SOCKET=self.sock_path, BREWBERRYPI_WATCHDOG_MS="200",
                   BREWBERRYPI_STUB_PORT=str(self.port), BREWBERRYPI_STUB_START_DELAY_S="0.1",
                   BREWBERRYPI_STUB_VERSION="9.9.9")
        proc = subprocess.Popen([sys.executable, STUB, "--config", self.config], env=env,
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

    def test_landing_page_explains_the_placeholder(self) -> None:
        with open(self.config, "w") as f:
            f.write("{}")
        self.start()
        self.assertEqual(self.recv(), "READY=1")
        status, content_type, body = self.page()
        self.assertEqual(status, 200)
        self.assertEqual(content_type, "text/html; charset=utf-8")
        self.assertIn("The brewing app isn't installed yet", body)
        self.assertIn("version 9.9.9", body)
        self.assertIn("sudo brewberry-update install", body)
        self.assertIn("built-in defaults", body)
        self.assertIn("pinged every 0.2 s", body)
        self.assertIn("<dt>Heater test</dt><dd>off</dd>", body)
        for tag in ("<script", "<link", "src="):  # nothing to load: the Pi may be offline
            self.assertNotIn(tag, body)
        self.assertIn("The brewing app isn't installed yet", self.page("/index.html")[2])
        self.assertEqual(self.http("GET", "/healthz")["status"], "ok")  # contract unchanged

    def test_landing_page_shows_an_enabled_heater_test(self) -> None:
        self.start({"allowHeat": True})
        self.assertEqual(self.recv(), "READY=1")
        body = self.page()[2]
        self.assertIn("enabled (allowHeat in stub.json)", body)
        self.assertIn("Only the hardware heater test can switch the heater on", body)

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
