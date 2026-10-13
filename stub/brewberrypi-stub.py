#!/usr/bin/env python3
"""BrewberryPi contract stub (runtime contract version 1).

Stands in for the real app image (tinkerius/brewberrypi) until it is released, so the OS side of
the contract can be tested: READY=1, WATCHDOG=1 every BREWBERRYPI_WATCHDOG_MS, STOPPING=1, and
GET /healthz on port 8080. GET / is a page for people who open the Pi in a browser: it explains
that the app isn't installed yet and how to install it.

GPIO: only on request (POST /stub/heat?on=1), the stub drives the heater output like the app would
(libgpiod v2, header chip found by label, pin and polarity from config.json, defaults BCM 23
active-low) and keeps holding the line, so the host's outputs-off reset can be tested "while
heating". This is off unless /config/stub.json has {"allowHeat": true}: the stub listens on the
network without authentication. On SIGTERM it switches the heater off and releases the line first
(contract §2).

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
    POST /stub/heat?on=1|0  heater output on or off (holds the GPIO line); needs allowHeat

Only the Python standard library is used, plus the gpiod module for /stub/heat.
"""

import argparse
import html
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
    config_path = "/config/config.json"
    allow_heat = False
    dummymode = False
    started = time.time()


HEADER_CHIP_LABELS = ("pinctrl-bcm2835", "pinctrl-bcm2711", "pinctrl-rp1")


class Heater:
    """The heater output, requested on first use and then held, like the app's HAL."""

    request = None
    pin = 23
    lock = threading.Lock()

    @classmethod
    def set(cls, on: bool) -> None:
        import gpiod  # only needed for this test feature
        from gpiod.line import Direction, Value

        with cls.lock:
            if cls.request is None:
                cls.pin, active_low = cls._pin_from_config()
                chip = cls._header_chip()
                settings = gpiod.LineSettings(
                    direction=Direction.OUTPUT, active_low=active_low, output_value=Value.INACTIVE
                )
                cls.request = gpiod.request_lines(
                    chip, consumer="brewberrypi-stub", config={cls.pin: settings}
                )
                log(f"heater: holding BCM {cls.pin} on {chip} (activeLow {active_low})")
            cls.request.set_value(cls.pin, Value.ACTIVE if on else Value.INACTIVE)
            log(f"heater {'ON' if on else 'off'}")

    @classmethod
    def off_and_release(cls) -> None:
        with cls.lock:
            if cls.request is None:
                return
            from gpiod.line import Value

            cls.request.set_value(cls.pin, Value.INACTIVE)
            cls.request.release()
            cls.request = None
            log("heater off, line released")

    @staticmethod
    def _pin_from_config() -> tuple[int, bool]:
        try:
            with open(State.config_path, encoding="utf-8") as f:
                heating = json.load(f).get("hardware", {}).get("heating", {})
        except FileNotFoundError:
            heating = {}
        return int(heating.get("pin", 23)), bool(heating.get("activeLow", True))

    @staticmethod
    def _header_chip() -> str:
        import glob

        import gpiod

        for path in sorted(glob.glob("/dev/gpiochip*")):
            try:
                with gpiod.Chip(path) as chip:
                    if chip.get_info().label in HEADER_CHIP_LABELS:
                        return path
            except OSError:
                continue
        raise RuntimeError("no GPIO chip labelled " + "/".join(HEADER_CHIP_LABELS))


MANUAL = "https://github.com/tinkerius/brewberrypi-os/blob/main/docs/user-manual.md"

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BrewberryPi: app not installed</title>
<style>
:root {{
  --bg: #f6f4ef; --card: #ffffff; --text: #24211c; --muted: #6b655b; --line: #e3ded3;
  --accent: #8a4b14; --note-bg: #fff4e0; --note-line: #f0c27a; --ok: #2f7a3e; --code-bg: #f1eee7;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg: #1b1916; --card: #24221e; --text: #ece8e0; --muted: #a59e92; --line: #3a362f;
    --accent: #e3a35f; --note-bg: #3a2c17; --note-line: #8a6326; --ok: #6cc47c; --code-bg: #2e2b26;
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}}
main {{ max-width: 44rem; margin: 0 auto; padding: 2rem 1rem 3rem; }}
header p {{ margin: 0; color: var(--muted); }}
h1 {{ font-size: 1.7rem; line-height: 1.25; margin: 0.25rem 0 0.75rem; }}
h2 {{ font-size: 1.1rem; margin: 0 0 0.5rem; }}
section {{
  background: var(--card); border: 1px solid var(--line); border-radius: 12px;
  padding: 1.1rem 1.25rem; margin-top: 1rem;
}}
.note {{ background: var(--note-bg); border-color: var(--note-line); }}
.brand {{ color: var(--accent); font-weight: 600; letter-spacing: 0.02em; }}
dl {{ display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1rem; margin: 0; }}
dt {{ color: var(--muted); }}
dd {{ margin: 0; }}
.ok {{ color: var(--ok); font-weight: 600; }}
pre, code {{ font: 0.9rem/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
code {{
  background: var(--code-bg); padding: 0.1rem 0.3rem; border-radius: 4px; overflow-wrap: anywhere;
}}
pre {{ background: var(--code-bg); padding: 0.75rem 1rem; border-radius: 8px; overflow-x: auto; }}
pre code {{ background: none; padding: 0; }}
a {{ color: var(--accent); }}
footer {{ margin-top: 1.5rem; color: var(--muted); font-size: 0.9rem; }}
</style>
</head>
<body>
<main>
<header>
<p class="brand">BrewberryPi OS</p>
<h1>The brewing app isn't installed yet</h1>
<p>This Raspberry Pi is set up and running, but the BrewberryPi app is not on it yet. What answers
here is a small placeholder that comes with the operating system.</p>
</header>

<section class="note">
<h2>What's running instead</h2>
<p>The <strong>contract stub</strong> stands in for the app until the app is installed. It tests
that the operating system can start, watch over and update an app. It has no brewing functions,
and it <strong>never switches the heater or the pump</strong> by itself: the outputs stay
off.{heat_note}</p>
</section>

<section>
<h2>Status</h2>
<dl>
<dt>Placeholder</dt><dd><span class="ok">running</span>, version {version}</dd>
<dt>Up for</dt><dd>{uptime}</dd>
<dt>Device</dt><dd>{hostname}</dd>
<dt>Watchdog</dt><dd>{watchdog}</dd>
<dt>Configuration</dt><dd>{config}</dd>
<dt>Heater test</dt><dd>{heat}</dd>
<dt>Demo mode</dt><dd>{demo}</dd>
</dl>
</section>

<section>
<h2>Install the app</h2>
<p>Log in to the Pi over SSH (<code>ssh &lt;user&gt;@{hostname}.local</code>), then:</p>
<pre><code># once: your GitHub user, and a classic token with read:packages
sudo brewberry-update login
# the released app versions
sudo brewberry-update list
# install one of them
sudo brewberry-update install 1.2.3</code></pre>
<p>Without internet, install from a USB stick instead: <code>sudo brewberry-usb list</code> and
<code>sudo brewberry-usb install 1.2.3</code>. Every version must be signed by the app's
developers, or the Pi refuses it. When the app runs, this page is replaced by its web UI.</p>
<p>More in the <a href="{manual}#6-app-versions">user manual</a>.</p>
</section>

<footer>Health check for tools: <a href="/healthz"><code>/healthz</code></a></footer>
</main>
</body>
</html>
"""


def duration(seconds: float) -> str:
    minutes, _ = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    if days:
        return f"{days} d {hours} h"
    if hours:
        return f"{hours} h {minutes} min"
    return f"{minutes} min"


def config_summary() -> str:
    try:
        with open(State.config_path, encoding="utf-8") as f:
            config = json.load(f)
    except FileNotFoundError:
        return "no config.json"
    except (OSError, ValueError):
        return "config.json can't be read"
    return "built-in defaults" if config == {} else "config.json from /data/config"


def landing_page() -> str:
    watchdog_ms = os.environ.get("BREWBERRYPI_WATCHDOG_MS", "")
    if not State.watchdog_alive.is_set():
        watchdog = "not pinged"
    elif watchdog_ms.isdigit():
        watchdog = f"pinged every {int(watchdog_ms) / 1000:g} s"
    else:
        watchdog = "pinged"
    if State.allow_heat:
        heat = "enabled (allowHeat in stub.json)"
        heat_note = (" Only the hardware heater test can switch the heater on, and it is enabled"
                     " on this Pi (<code>allowHeat</code> in <code>stub.json</code>).")
    else:
        heat, heat_note = "off", ""
    return PAGE.format(
        version=html.escape(VERSION),
        uptime=duration(time.time() - State.started),
        hostname=html.escape(socket.gethostname()),
        watchdog=watchdog,
        config=html.escape(config_summary()),
        heat=heat,
        heat_note=heat_note,
        demo=("on: the app will simulate the kettle (brewberry-update demo off to end it)"
              if State.dummymode else "off"),
        manual=MANUAL,
    )


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

    def _reply_html(self, body: str) -> None:
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        path = urlparse(self.path).path
        if path == "/healthz":
            self._reply(200, {"status": "ok", "version": VERSION, "engine": "NoProcess"})
        elif path in ("/", "/index.html"):
            self._reply_html(landing_page())
        elif path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
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
        elif url.path == "/stub/heat":
            on = parse_qs(url.query).get("on", ["0"])[0] == "1"
            if on and not State.allow_heat:
                self._reply(403, {"error": 'heater test disabled; set "allowHeat": true in stub.json'})
                return
            try:
                Heater.set(on)
            except Exception as error:  # noqa: BLE001 (report any GPIO failure to the tester)
                self._reply(500, {"error": f"heater: {error}"})
                return
            self._reply(200, {"heater": "on" if on else "off"})
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
    State.config_path = args.config
    State.dummymode = args.dummymode

    stub_config = read_stub_config(args.config)
    start = stub_config.get("start", os.environ.get("BREWBERRYPI_STUB_START", "ok"))
    State.allow_heat = stub_config.get("allowHeat") is True
    log(f"version {VERSION}, start mode {start}, uid {os.getuid()}")
    State.started = time.time()

    def on_term(signum: int, _frame: object) -> None:
        notify("STOPPING=1")
        log(f"signal {signum}: stopping")
        Heater.off_and_release()
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
