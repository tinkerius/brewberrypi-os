#!/usr/bin/python3
"""Device web interface of BrewberryPi OS (ADR-0002, OS9), port 8081.

Runs as the unprivileged user brewberry-web. It serves index.html and a JSON
API, checks sessions and request origins, and forwards every request to the
root helper over /run/brewberry-webcmd.sock (helper.py). It holds no device
logic: every action is a CLI command from the catalogue, run by the helper.

Login: the fixed user 'brewberry'; only the password is entered. Sessions are
random tokens in an HttpOnly, SameSite=Strict cookie, kept in memory (a
restart logs everyone out), and expire after 30 minutes without a request.
"""

import base64
import ipaddress
import json
import os
import secrets
import socket
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Overrides are for tests only (tests/web/test_web.py).
PORT = int(os.environ.get("BREWBERRY_WEB_PORT", "8081"))
HELPER_SOCKET = os.environ.get("BREWBERRY_WEBCMD_SOCKET", "/run/brewberry-webcmd.sock")
CATALOGUE = os.environ.get("BREWBERRY_CATALOGUE", "/usr/share/brewberry/commands.json")
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
# The BrewberryPi brand files the page uses (scripts/sync-brand.sh), served
# without a login: the login page shows them too. Only these paths.
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATIC = {
    "/favicon.ico": ("favicon.ico", "image/x-icon"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
    "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
    "/static/logo.svg": ("logo.svg", "image/svg+xml"),
    "/static/logo-dark.svg": ("logo-dark.svg", "image/svg+xml"),
    "/static/logo-stacked.svg": ("logo-stacked.svg", "image/svg+xml"),
    "/static/logo-stacked-dark.svg": ("logo-stacked-dark.svg", "image/svg+xml"),
    "/static/zilla-slab-medium.woff2": ("zilla-slab-medium.woff2", "font/woff2"),
}
USER = "brewberry"
COOKIE = "brewberry_session"
IDLE_SECONDS = 30 * 60
MAX_BODY = 12 * 1024 * 1024
FREE_FAILURES = 5        # failed logins per address before the delay starts
MAX_DELAY = 60

sessions = {}            # token -> {"seen": time, "defaultPassword": bool}
failures = {}            # address -> (count, not before)
lock = threading.Lock()


def helper(request, timeout=900):
    """One request to the root helper; its JSON answer."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(HELPER_SOCKET)
        s.sendall(json.dumps(request).encode() + b"\n")
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).decode())


def public_catalogue():
    with open(CATALOGUE, encoding="utf-8") as f:
        commands = json.load(f)["commands"]
    keep = ("id", "title", "screen", "kind", "args", "confirm", "job", "reboots", "upload", "download", "stdin", "stdinOptional", "webOnly")
    return [{k: c[k] for k in keep if k in c} for c in commands]


def host_allowed(host):
    """Host header check against DNS rebinding: this device's names or an IP address."""
    if not host:
        return False
    name = host.rsplit(":", 1)[0] if not host.endswith("]") else host
    name = name.strip("[]").lower()
    try:
        ipaddress.ip_address(name)
        return True
    except ValueError:
        pass
    own = socket.gethostname().lower()
    return name in (own, own + ".local", "localhost")


class Handler(BaseHTTPRequestHandler):
    server_version = "brewberry-web"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("brewberry-web: %s %s\n" % (self.address_string(), fmt % args))

    # --- replies -----------------------------------------------------------
    def _send(self, status, body, ctype="application/json", headers=(), cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                         "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj, headers=()):
        self._send(status, json.dumps(obj).encode(), headers=headers)

    # --- checks ------------------------------------------------------------
    def _session(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        token = cookie[COOKIE].value if COOKIE in cookie else None
        if not token:
            return None, None
        now = time.monotonic()
        with lock:
            s = sessions.get(token)
            if not s or now - s["seen"] > IDLE_SECONDS:
                sessions.pop(token, None)
                return None, None
            s["seen"] = now
            return token, s

    def _origin_ok(self):
        """Cross-site request protection for POST: same origin and our header."""
        if self.headers.get("X-Brewberry") != "1":
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin == "http://" + self.headers.get("Host", "")

    def _body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > MAX_BODY:
            raise ValueError("request too large")
        data = self.rfile.read(length) if length else b"{}"
        obj = json.loads(data.decode() or "{}")
        if not isinstance(obj, dict):
            raise ValueError("expected a JSON object")
        return obj

    # --- routing -----------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not host_allowed(self.headers.get("Host", "")):
            return self._json(421, {"error": "unknown host name"})
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            with open(PAGE, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if url.path in STATIC:
            name, ctype = STATIC[url.path]
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                return self._send(200, f.read(), ctype, cache="max-age=86400")
        if url.path == "/api/session":
            _, s = self._session()
            return self._json(200, {"user": USER, "loggedIn": s is not None,
                                    "defaultPassword": bool(s and s["defaultPassword"])})
        _, s = self._session()
        if s is None:
            return self._json(401, {"error": "log in first"})
        if url.path == "/api/commands":
            return self._json(200, {"commands": public_catalogue()})
        if url.path == "/api/jobs":
            return self._forward({"op": "jobs"})
        if url.path.startswith("/api/jobs/"):
            return self._forward({"op": "job", "job": url.path[len("/api/jobs/"):]})
        if url.path.startswith("/api/run/"):
            # Queries and downloads only; actions are POST.
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            return self._run(url.path[len("/api/run/"):], {"args": query}, get=True)
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        if not host_allowed(self.headers.get("Host", "")):
            return self._json(421, {"error": "unknown host name"})
        if not self._origin_ok():
            return self._json(403, {"error": "cross-site request refused"})
        try:
            body = self._body()
        except (ValueError, UnicodeDecodeError) as e:
            return self._json(400, {"error": str(e)})
        path = urlparse(self.path).path
        if path == "/api/login":
            return self._login(body)
        token, s = self._session()
        if s is None:
            return self._json(401, {"error": "log in first"})
        if path == "/api/logout":
            with lock:
                sessions.pop(token, None)
            return self._json(200, {"ok": True}, headers=[("Set-Cookie", f"{COOKIE}=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict")])
        if path == "/api/password":
            reply = self._helper({"op": "passwd", "old": body.get("old", ""), "new": body.get("new", "")})
            if reply is None:
                return None
            if reply.get("ok"):
                with lock:
                    s["defaultPassword"] = False
            return self._reply(reply)
        if path.startswith("/api/run/"):
            return self._run(path[len("/api/run/"):], body, get=False)
        return self._json(404, {"error": "not found"})

    # --- handlers ----------------------------------------------------------
    def _login(self, body):
        addr = self.client_address[0]
        now = time.monotonic()
        with lock:
            count, not_before = failures.get(addr, (0, 0))
        if now < not_before:
            return self._json(429, {"error": f"too many attempts; wait {int(not_before - now) + 1} s"})
        reply = self._helper({"op": "auth", "password": body.get("password", "")})
        if reply is None:
            return None
        if not reply.get("ok"):
            count += 1
            delay = 0 if count < FREE_FAILURES else min(MAX_DELAY, 2 ** (count - FREE_FAILURES))
            with lock:
                failures[addr] = (count, now + delay)
            return self._json(401, {"error": "wrong password"})
        token = secrets.token_urlsafe(32)
        with lock:
            failures.pop(addr, None)
            sessions[token] = {"seen": now, "defaultPassword": bool(reply.get("defaultPassword"))}
        return self._json(200, {"ok": True, "user": USER, "defaultPassword": bool(reply.get("defaultPassword"))},
                          headers=[("Set-Cookie", f"{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict")])

    def _run(self, cmd_id, body, get):
        commands = {c["id"]: c for c in public_catalogue()}
        cmd = commands.get(cmd_id)
        if not cmd or cmd.get("webOnly"):
            return self._json(404, {"error": f"unknown command: {cmd_id}"})
        if get != (cmd["kind"] == "query"):
            return self._json(405, {"error": "queries use GET, actions POST"})
        request = {"op": "run", "id": cmd_id, "args": body.get("args") or {}, "yes": bool(body.get("yes"))}
        if "stdin" in body:
            request["stdin"] = body["stdin"]
        if "files" in body:
            request["files"] = body["files"]
        reply = self._helper(request)
        if reply is None:
            return None
        if cmd.get("download") and reply.get("exit") == 0 and "data" in reply:
            return self._send(200, base64.b64decode(reply["data"]), "application/gzip",
                              headers=[("Content-Disposition", f'attachment; filename="{reply["filename"]}"')])
        return self._reply(reply)

    def _helper(self, request):
        try:
            return helper(request)
        except (OSError, ValueError) as e:
            self._json(503, {"error": f"the device helper is not available: {e}"})
            return None

    def _forward(self, request):
        """Job status: the job's own exit code is data, not the reply's status."""
        reply = self._helper(request)
        if reply is None:
            return None
        if "error" in reply:
            return self._json(reply.get("status", 400), reply)
        return self._json(200, reply)

    def _reply(self, reply):
        if reply is None:
            return None
        if "error" in reply:
            return self._json(reply.get("status", 400), reply)
        if "confirm" in reply:
            return self._json(409, reply)
        if "busy" in reply:
            return self._json(423, {"error": "another action is still running", "job": reply["busy"]})
        if "job" in reply and "exit" not in reply:
            return self._json(202, reply)
        if reply.get("exit", 0) != 0:
            return self._json(422, reply)
        return self._json(200, reply)


def main():
    server = ThreadingHTTPServer(("", PORT), Handler)
    server.daemon_threads = True
    print(f"brewberry-web: listening on port {PORT}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
