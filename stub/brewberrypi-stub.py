#!/usr/bin/env python3
"""BrewberryPi contract stub (runtime contract version 1).

Stands in for the real app image (tinkerius/brewberrypi) until it is released, so the OS side of
the contract can be tested: READY=1, WATCHDOG=1 every BREWBERRYPI_WATCHDOG_MS, STOPPING=1, and
GET /healthz on port 8080. It never touches GPIO.

Failure modes, for testing supervision, rollback and safe mode:

- start mode, from /config/stub.json {"start": ...} or else the image default
  BREWBERRYPI_STUB_START (build arg START):
    ok      normal start (default)
    crash   exit 1 before READY
    hwfail  exit 4 before READY (hardware initialisation failed)
    config  exit 2 before READY (invalid configuration)
    hang    never send READY (start timeout)
- at runtime, over HTTP:
    POST /stub/crash        exit 1
    POST /stub/hang         stop the watchdog pings (the HTTP server keeps answering)
    POST /stub/exit?code=N  exit with code N

Only the Python standard library is used.
"""

import argparse
import json
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = os.environ.get("BREWBERRYPI_STUB_VERSION", "0.0.0")
PORT = int(os.environ.get("BREWBERRYPI_STUB_PORT", "8080"))  # override only for tests
START_DELAY_S = float(os.environ.get("BREWBERRYPI_STUB_START_DELAY_S", "2"))  # visible READY wait


def log(message: str) -> None:
    print(f"brewberrypi-stub: {message}", flush=True)


def notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET", "")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.sendto(message.encode(), address)
    except OSError as error:
        log(f"sd_notify {message} failed: {error}")


def read_stub_config(config_path: str) -> dict:
    path = os.path.join(os.path.dirname(config_path), "stub.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        log(f"ignoring {path}: {error}")
        return {}


class State:
    watchdog_alive = threading.Event()


def exit_now(code: int) -> None:
    log(f"exiting with code {code}")
    os._exit(code)


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if urlparse(self.path).path == "/healthz":
            self._reply(200, {"status": "ok", "version": VERSION, "engine": "NoProcess"})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        url = urlparse(self.path)
        if url.path == "/stub/crash":
            self._reply(200, {"stub": "crashing"})
            exit_now(1)
        elif url.path == "/stub/hang":
            State.watchdog_alive.clear()
            log("hanging: watchdog pings stopped")
            self._reply(200, {"stub": "hanging"})
        elif url.path == "/stub/exit":
            code = int(parse_qs(url.query).get("code", ["1"])[0])
            self._reply(200, {"stub": f"exiting {code}"})
            exit_now(code)
        else:
            self._reply(404, {"error": "not found"})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        log(format % args)


def watchdog_loop(interval_s: float) -> None:
    while True:
        if State.watchdog_alive.is_set():
            notify("WATCHDOG=1")
        time.sleep(interval_s)


def main() -> int:
    parser = argparse.ArgumentParser(prog="brewberrypi")
    parser.add_argument("--config", default="/config/config.json")
    parser.add_argument("--dummymode", action="store_true")
    args = parser.parse_args()

    start = read_stub_config(args.config).get("start", os.environ.get("BREWBERRYPI_STUB_START", "ok"))
    log(f"version {VERSION}, start mode {start}, uid {os.getuid()}")

    def on_term(signum: int, _frame: object) -> None:
        notify("STOPPING=1")
        log(f"signal {signum}: stopping")
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    time.sleep(START_DELAY_S)
    if start in ("crash", "hwfail", "config"):
        exit_now({"crash": 1, "hwfail": 4, "config": 2}[start])

    server = ThreadingHTTPServer(("", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    if start == "hang":
        log("start mode hang: not sending READY")
    else:
        notify("READY=1")
        log(f"ready, listening on port {PORT}")
        watchdog_ms = os.environ.get("BREWBERRYPI_WATCHDOG_MS", "")
        if watchdog_ms.isdigit() and int(watchdog_ms) > 0:
            State.watchdog_alive.set()
            threading.Thread(target=watchdog_loop, args=(int(watchdog_ms) / 1000,), daemon=True).start()

    signal.pause()
    return 0


if __name__ == "__main__":
    sys.exit(main())
