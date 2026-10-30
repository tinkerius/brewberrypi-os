#!/usr/bin/env python3
"""BrewberryPi contract stub (runtime contract version 2).

Stands in for the real app image (tinkerius/brewberrypi-app) until it is released, so the OS side of
the contract can be tested: READY=1, WATCHDOG=1 every BREWBERRYPI_WATCHDOG_MS, STOPPING=1, and
GET /healthz on port 8080. GET / is a page for people who open the Pi in a browser: it explains
that the app isn't installed yet, and that BrewberryPi OS installs it by itself (ADR-0007).

Version: the preloaded stub reports "placeholder" (image label and /healthz), because it is not an
app release; brewberry-update shows it as "no app installed". Test images for the OS4 check get
release versions (scripts/publish-test-stubs.sh), because they stand in for app releases.

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

PLACEHOLDER = "placeholder"
VERSION = os.environ.get("BREWBERRYPI_STUB_VERSION", PLACEHOLDER)
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

# The BrewberryPi brand files the page uses (copies made by scripts/sync-brand.sh;
# in the image under /usr/local/share/brewberrypi-stub). Only these paths are served.
STATIC_DIR = os.environ.get("BREWBERRYPI_STUB_STATIC",
                            os.path.join(os.path.dirname(os.path.abspath(__file__)), "static"))
STATIC = {
    "/favicon.ico": ("favicon.ico", "image/x-icon"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
    "/static/logo.svg": ("logo.svg", "image/svg+xml"),
    "/static/logo-dark.svg": ("logo-dark.svg", "image/svg+xml"),
    "/static/zilla-slab-medium.woff2": ("zilla-slab-medium.woff2", "font/woff2"),
}

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BrewberryPi: app not installed</title>
<meta name="theme-color" content="#fbf8f6" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1c1719" media="(prefers-color-scheme: dark)">
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
/* BrewberryPi brand (tinkerius/brewberrypi, brand/README.md): paper, ink, berry, brass and leaf;
   the darker values on light, the lighter ones on dark. The top bar and the cards look like the
   app's (tinkerius/brewberrypi-app, frontend/src/ui.ts) and the device web interface's, so that
   the page the app replaces already looks like it. */
@font-face {{ font-family: "Zilla Slab"; font-weight: 500; font-display: swap;
  src: url("/static/zilla-slab-medium.woff2") format("woff2"); }}
:root {{
  color-scheme: light dark;
  --bg: #fbf8f6; --card: #ffffff; --text: #2a1d22; --muted: oklch(55.3% .013 58.071);
  --line: rgb(42 29 34 / .1); --ring: rgb(42 29 34 / .05); --accent: #8a2a4a;
  --note-bg: rgb(196 130 26 / .1); --note-line: rgb(196 130 26 / .6); --ok: #3d7a3c; --code-bg: #fbf8f6;
  --shadow: 0 1px 3px 0 rgb(0 0 0 / .1), 0 1px 2px -1px rgb(0 0 0 / .1);
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg: #1c1719; --card: #262023; --text: #f1e8eb; --muted: oklch(70.9% .01 56.259);
    --line: rgb(255 255 255 / .1); --ring: rgb(255 255 255 / .1); --accent: #e0789a;
    --note-bg: rgb(233 176 79 / .1); --note-line: rgb(233 176 79 / .4); --ok: #8fc77f;
    --code-bg: rgb(255 255 255 / .05);
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased;
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", "Noto Sans",
    Arial, sans-serif;
}}
header {{
  display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; padding: 12px 16px;
  background: var(--card); border-bottom: 1px solid var(--line);
}}
header .logo {{ margin: 0; line-height: 0; }}
header .logo img {{ height: 32px; width: auto; }}
header .host {{ color: var(--muted); }}
header .device {{ margin-left: auto; font-size: 14px; font-weight: 500; text-decoration: none; }}
header .device:hover {{ text-decoration: underline; }}
main {{ max-width: 48rem; margin: 0 auto; padding: 24px 16px 48px; }}
@media (min-width: 640px) {{ main {{ padding: 24px 24px 48px; }} }}
.intro {{ margin: 8px 0 0; }}
.intro p {{ margin: 0; color: var(--muted); }}
h1, h2, .brand {{ font-family: "Zilla Slab", Rockwell, Georgia, serif; font-weight: 500; }}
h1 {{ font-size: 1.9rem; line-height: 1.2; margin: 0.25rem 0 0.75rem; color: var(--accent); }}
h2 {{ font-size: 1.125rem; line-height: 1.75rem; margin: 0 0 1rem; color: var(--text); }}
section {{
  background: var(--card); border-radius: 12px; padding: 20px; margin-top: 24px;
  box-shadow: 0 0 0 1px var(--ring), var(--shadow);
}}
@media (min-width: 640px) {{ section {{ padding: 24px; }} }}
section p {{ margin: 0.5rem 0 0; }}
section h2 + p {{ margin-top: 0; }}
.note {{ background: var(--note-bg); box-shadow: inset 0 0 0 1px var(--note-line); }}
.brand {{ color: var(--muted); font-size: 1.1rem; letter-spacing: 0.02em; }}
dl {{ display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1rem; margin: 0; }}
dt {{ color: var(--muted); }}
dd {{ margin: 0; }}
.ok {{ color: var(--ok); font-weight: 600; }}
pre, code {{ font: 0.875em/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
code {{
  background: var(--code-bg); padding: 0.1rem 0.3rem; border-radius: 4px; overflow-wrap: anywhere;
}}
pre {{
  background: var(--code-bg); box-shadow: inset 0 0 0 1px var(--ring); padding: 0.75rem 1rem;
  border-radius: 8px; overflow-x: auto; margin: 0.75rem 0;
}}
pre code {{ background: none; padding: 0; }}
a {{ color: var(--accent); }}
footer {{ margin-top: 1.5rem; color: var(--muted); font-size: 0.875rem; }}
</style>
</head>
<body>
<header>
<div class="logo"><picture>
<source srcset="/static/logo-dark.svg" media="(prefers-color-scheme: dark)">
<img src="/static/logo.svg" alt="BrewberryPi" width="145" height="32">
</picture></div>
<span class="host">{hostname} · {header_version}</span>
<a class="device" href="http://{hostname}.local:8081/">Device settings</a>
</header>
<main>
<div class="intro">
<p class="brand">BrewberryPi OS</p>
<h1>The brewing app isn't installed yet</h1>
<p>This Raspberry Pi is set up and running, but the BrewberryPi app is not on it yet. What answers
here is a small placeholder that comes with the operating system.</p>
</div>

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
<dt>Placeholder</dt><dd><span class="ok">running</span>{version}</dd>
<dt>Up for</dt><dd>{uptime}</dd>
<dt>Device</dt><dd>{hostname}</dd>
<dt>Watchdog</dt><dd>{watchdog}</dd>
<dt>Configuration</dt><dd>{config}</dd>
<dt>Heater test</dt><dd>{heat}</dd>
<dt>Demo mode</dt><dd>{demo}</dd>
</dl>
</section>

<section>
<h2>The app installs itself</h2>
<p>Once the Pi is online, it downloads the newest app version and installs it by itself. That takes
a few minutes (longer on a Pi 3); then this page is replaced by the app. Reload it now and then.
The device web interface at
<a href="http://{hostname}.local:8081/#versions">http://{hostname}.local:8081/</a>
(user <code>brewberry</code>, default password <code>pi</code>) shows how far it got under
<em>App versions</em>. If the app's registry is private, store a registry token there first.</p>
<p>To pick a version by hand, log in to the Pi over SSH (<code>ssh &lt;user&gt;@{hostname}.local</code>), then:</p>
<pre><code># only for a private registry: your GitHub user, and a classic token with read:packages
sudo brewberry-update login
# the released app versions
sudo brewberry-update list
# download one of them onto the Pi, then install it
sudo brewberry-update download 1.2.3
sudo brewberry-update install 1.2.3</code></pre>
<p>Every version must be signed by the app's developers, or the Pi refuses it. When the app runs,
this page is replaced by its web UI, and the app writes its <code>config.json</code> and recipes into
the file share's <code>app</code> folder.</p>
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
        return "no config.json yet (the app writes it at its first start)"
    except (OSError, ValueError):
        return "config.json can't be read"
    return "built-in defaults" if config == {} else "config.json from /data/config/app"


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
        version="" if VERSION == PLACEHOLDER else ", test version " + html.escape(VERSION),
        header_version=("no app installed" if VERSION == PLACEHOLDER
                        else "test version " + html.escape(VERSION)),
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

    def _reply_static(self, name: str, ctype: str) -> None:
        try:
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                data = f.read()
        except OSError:
            self._reply(404, {"error": "not found"})
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        path = urlparse(self.path).path
        if path == "/healthz":
            self._reply(200, {"status": "ok", "version": VERSION, "engine": "NoProcess"})
        elif path in ("/", "/index.html"):
            self._reply_html(landing_page())
        elif path in STATIC:
            self._reply_static(*STATIC[path])
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
