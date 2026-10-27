"""Tests for the device web interface (ADR-0002, OS9): server.py and helper.py.

The server runs as a subprocess on a free port. The root helper is started per
connection like brewberry-webcmd.socket does (Accept=yes), with fake CLIs,
systemd-run, systemctl and chpasswd on PATH and a fake shadow file. Run by
scripts/lint.sh: python3 -m unittest discover -s tests/web
"""

import ctypes
import ctypes.util
import json
import os
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import base64

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WEB = os.path.join(ROOT, "layer", "brewberry-web.rootfs-overlay", "usr", "lib", "brewberry-web")
CATALOGUE = os.path.join(ROOT, "layer", "brewberry-web.rootfs-overlay", "usr", "share", "brewberry", "commands.json")

FAKE_CLI = r"""#!/bin/bash
# Fake operator CLI: logs its arguments; confirm actions want --yes (exit 10).
echo "$(basename "$0") $*" >> "$FAKE/log"
args=" $* "
yes=0; case $args in *" --yes "*) yes=1 ;; esac
case "$(basename "$0") $1" in
   "brewberry-update status") echo '{"active": {"version": "0.3.0", "id": "abc"}, "previous": null, "service": "active", "engine": "NoProcess", "last": null, "safemode": null, "demo": false}' ;;
   "brewberry-update install" | "brewberry-update demo" | "brewberry-maint on")
      if [ $yes = 0 ]; then echo '{"confirm": "This installs '"$2"' and restarts the app."}'; exit 10; fi
      echo "working on $2"; sleep "${FAKE_SLEEP:-0}"; echo "done" ;;
   "brewberry-update login") cat > "$FAKE/token"; echo "Login Succeeded!" >&2 ;;
   "brewberry-config show") echo '{"config": {}, "files": ["config.json"], "recipes": null}' ;;
   "brewberry-config import") (cd "$2" 2>/dev/null && find . -type f | sort || echo "file:$(basename "$2")") >> "$FAKE/imported"; echo "imported" >&2 ;;
   "brewberry-config export") printf 'TARDATA' ;;
   "brewberry-system logs") echo '{"name": "'"$2"'", "lines": ["one"]}' ;;
   "brewberry-wifi add") IFS= read -r pw; printf '%s' "$pw" > "$FAKE/wifi-password"; echo "saved $2" >&2 ;;
   "brewberry-wifi forget")
      if [ "$2" = Home ] && [ $yes = 0 ]; then echo '{"confirm": "The Pi is connected to Home."}'; exit 10; fi
      echo "forgot $2" >&2 ;;
   *) echo '{}' ;;
esac
"""

FAKE_SYSTEMD_RUN = r"""#!/bin/bash
# Like systemd-run: the unit is active from the moment this returns until the
# command ends.
echo "systemd-run $*" >> "$FAKE/log"
unit=""
while [ "${1#--}" != "$1" ]; do
   case $1 in --unit=*) unit=${1#--unit=} ;; esac
   shift
done
touch "$FAKE/active-$unit.service"
nohup sh -c '"$@"; rm -f "$0"' "$FAKE/active-$unit.service" "$@" > /dev/null 2>&1 &
"""

FAKE_SYSTEMCTL = r"""#!/bin/bash
# is-active --quiet brewberry-job-<id>.service
[ -e "$FAKE/active-$3" ]
"""

FAKE_CHPASSWD = r"""#!/bin/bash
cat > "$FAKE/chpasswd"
"""


def crypt(password, setting):
    lib = ctypes.CDLL(ctypes.util.find_library("crypt") or "libcrypt.so.1")
    lib.crypt.restype = ctypes.c_char_p
    lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    return lib.crypt(password.encode(), setting.encode()).decode()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HelperSocket(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Like brewberry-webcmd.socket with Accept=yes: one helper per connection."""
    daemon_threads = True


def make_helper_handler(env):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            fd = self.request.fileno()
            subprocess.run([sys.executable, os.path.join(WEB, "helper.py")], stdin=fd, stdout=fd, env=env, check=False)
    return Handler


class WebTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        t = cls.tmp
        cls.fake = os.path.join(t, "fake")
        bindir = os.path.join(t, "bin")
        os.makedirs(cls.fake)
        os.makedirs(bindir)
        for name in ("brewberry-update", "brewberry-config", "brewberry-system", "brewberry-maint", "brewberry-wifi"):
            cls._script(os.path.join(bindir, name), FAKE_CLI)
        cls._script(os.path.join(bindir, "systemd-run"), FAKE_SYSTEMD_RUN)
        cls._script(os.path.join(bindir, "systemctl"), FAKE_SYSTEMCTL)
        cls._script(os.path.join(bindir, "chpasswd"), FAKE_CHPASSWD)
        cls.shadow = os.path.join(t, "shadow")
        with open(cls.shadow, "w") as f:
            f.write("root:*:20000:0:99999:7:::\n")
            f.write(f"brewberry:{crypt('pi', '$6$testsalt$')}:20000:0:99999:7:::\n")
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], FAKE=cls.fake,
                   BREWBERRY_CATALOGUE=CATALOGUE, BREWBERRY_SHADOW=cls.shadow,
                   BREWBERRY_JOBS_DIR=os.path.join(t, "jobs"), BREWBERRY_UPLOAD_DIR=os.path.join(t, "uploads"))
        cls.env = env
        cls.sock_path = os.path.join(t, "webcmd.sock")
        cls.helper_server = HelperSocket(cls.sock_path, make_helper_handler(env))
        threading.Thread(target=cls.helper_server.serve_forever, daemon=True).start()
        cls.port = free_port()
        cls.server = subprocess.Popen([sys.executable, os.path.join(WEB, "server.py")],
                                      env=dict(env, BREWBERRY_WEB_PORT=str(cls.port), BREWBERRY_WEBCMD_SOCKET=cls.sock_path),
                                      stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        cls.cookie = cls.login("pi")[2]

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait()
        cls.helper_server.shutdown()
        cls.helper_server.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @staticmethod
    def _script(path, text):
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o755)

    @classmethod
    def request(cls, method, path, body=None, cookie=None, headers=None):
        h = {"Host": f"127.0.0.1:{cls.port}"}
        if method == "POST":
            h["X-Brewberry"] = "1"
            h["Content-Type"] = "application/json"
        if cookie:
            h["Cookie"] = cookie
        h.update(headers or {})
        data = json.dumps(body).encode() if body is not None else (b"{}" if method == "POST" else None)
        req = urllib.request.Request(f"http://127.0.0.1:{cls.port}{path}", data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    @classmethod
    def login(cls, password):
        status, body, headers = cls.request("POST", "/api/login", {"password": password})
        cookie = (headers.get("Set-Cookie") or "").split(";")[0]
        return status, json.loads(body), cookie

    def api(self, method, path, body=None, **kw):
        status, data, headers = self.request(method, path, body, cookie=self.cookie, **kw)
        try:
            return status, json.loads(data)
        except ValueError:
            return status, data

    def log(self):
        try:
            with open(os.path.join(self.fake, "log")) as f:
                return f.read()
        except OSError:
            return ""

    def wait_job(self, job):
        for _ in range(100):
            status, info = self.api("GET", f"/api/jobs/{job}")
            if info.get("state") != "running":
                return info
            time.sleep(0.1)
        self.fail("job did not finish")

    # --- login and request checks ------------------------------------------
    def test_page_without_login(self):
        status, body, _ = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"BrewberryPi OS", body)

    def test_brand_files_without_login(self):
        for path, ctype in (("/favicon.ico", "image/x-icon"), ("/favicon.svg", "image/svg+xml"),
                            ("/static/logo.svg", "image/svg+xml"), ("/static/logo-stacked-dark.svg", "image/svg+xml"),
                            ("/static/zilla-slab-medium.woff2", "font/woff2"), ("/apple-touch-icon.png", "image/png")):
            status, body, headers = self.request("GET", path)
            self.assertEqual((status, headers["Content-Type"]), (200, ctype), path)
            self.assertGreater(len(body), 100, path)
        # Only the listed files: nothing else from static/ or beside it.
        for path in ("/static/OFL.txt", "/static/../server.py", "/static/helper.py"):
            self.assertIn(self.request("GET", path)[0], (401, 404), path)

    def test_api_needs_a_session(self):
        self.assertEqual(self.request("GET", "/api/commands")[0], 401)
        self.assertEqual(self.request("GET", "/api/run/update.status")[0], 401)
        self.assertEqual(self.request("POST", "/api/run/update.install", {"args": {"version": "1.0.0"}})[0], 401)

    def test_aa_session_reports_the_default_password(self):
        status, data = self.api("GET", "/api/session")
        self.assertEqual((status, data["loggedIn"], data["user"], data["defaultPassword"]), (200, True, "brewberry", True))

    def test_wrong_password(self):
        status, data, cookie = self.login("wrong")
        self.assertEqual((status, cookie), (401, ""))

    def test_post_needs_our_header_and_origin(self):
        self.assertEqual(self.request("POST", "/api/run/update.restart", {}, cookie=self.cookie,
                                      headers={"X-Brewberry": ""})[0], 403)
        self.assertEqual(self.request("POST", "/api/run/update.restart", {}, cookie=self.cookie,
                                      headers={"Origin": "http://evil.example"})[0], 403)

    def test_foreign_host_name_refused(self):
        self.assertEqual(self.request("GET", "/", headers={"Host": "evil.example"})[0], 421)

    # --- commands --------------------------------------------------------------
    def test_catalogue_without_argv(self):
        status, data = self.api("GET", "/api/commands")
        self.assertEqual(status, 200)
        self.assertIn("update.install", [c["id"] for c in data["commands"]])
        self.assertFalse(any("argv" in c for c in data["commands"]))

    def test_query_runs_the_cli_with_json(self):
        status, data = self.api("GET", "/api/run/update.status")
        self.assertEqual((status, data["output"]["active"]["version"]), (200, "0.3.0"))
        self.assertIn("brewberry-update status --json", self.log())

    def test_query_argument_checked(self):
        status, data = self.api("GET", "/api/run/system.logs?name=app")
        self.assertEqual((status, data["output"]["lines"]), (200, ["one"]))
        self.assertEqual(self.api("GET", "/api/run/system.logs?name=../../etc")[0], 400)
        self.assertEqual(self.api("GET", "/api/run/system.logs?name=app&extra=1")[0], 400)

    def test_unknown_and_web_only_commands(self):
        self.assertEqual(self.api("POST", "/api/run/rm.rf", {})[0], 404)
        self.assertEqual(self.api("POST", "/api/run/account.password", {})[0], 404)
        self.assertEqual(self.api("GET", "/api/run/update.install")[0], 405)

    def test_install_asks_then_runs_as_a_job(self):
        status, data = self.api("POST", "/api/run/update.install", {"args": {"version": "1.2.3"}})
        self.assertEqual((status, data["confirm"]), (409, "This installs 1.2.3 and restarts the app."))
        status, data = self.api("POST", "/api/run/update.install", {"args": {"version": "1.2.3"}, "yes": True})
        self.assertEqual(status, 202)
        info = self.wait_job(data["job"])
        self.assertEqual((info["state"], info["exit"], info["cmd"]), ("done", 0, "update.install"))
        self.assertIn("working on 1.2.3", info["log"])
        self.assertIn("brewberry-update install 1.2.3 --yes", self.log())
        status, data = self.api("GET", "/api/jobs")
        self.assertIn(info["id"], [j["id"] for j in data["jobs"]])

    def test_download_is_a_job_remove_runs_at_once(self):
        status, data = self.api("POST", "/api/run/update.download", {"args": {"version": "1.4.0"}})
        self.assertEqual(status, 202)
        info = self.wait_job(data["job"])
        self.assertEqual((info["state"], info["cmd"]), ("done", "update.download"))
        self.assertIn("brewberry-update download 1.4.0\n", self.log())
        status, data = self.api("POST", "/api/run/update.remove", {"args": {"version": "1.4.0"}})
        self.assertEqual(status, 200)
        self.assertIn("brewberry-update remove 1.4.0\n", self.log())
        self.assertEqual(self.api("POST", "/api/run/update.remove", {"args": {"version": "active"}})[0], 400)

    def test_bad_version_refused_before_the_cli(self):
        before = self.log()
        status, data = self.api("POST", "/api/run/update.install", {"args": {"version": "1.2.3; reboot"}, "yes": True})
        self.assertEqual(status, 400)
        self.assertEqual(self.log(), before)

    def test_second_job_while_one_runs(self):
        self.helper_server.RequestHandlerClass = make_helper_handler(dict(self.env, FAKE_SLEEP="2"))
        try:
            status, first = self.api("POST", "/api/run/maint.on", {"yes": True})
            self.assertEqual(status, 202)
            status, data = self.api("POST", "/api/run/update.demo", {"args": {"mode": "on"}, "yes": True})
            self.assertEqual((status, data["job"]), (423, first["job"]))
            self.wait_job(first["job"])
        finally:
            self.helper_server.RequestHandlerClass = make_helper_handler(self.env)

    def test_registry_login_token_on_stdin(self):
        status, data = self.api("POST", "/api/run/update.login", {"args": {"username": "tinkerius"}, "stdin": "ghp_secret"})
        self.assertEqual(status, 200)
        with open(os.path.join(self.fake, "token")) as f:
            self.assertEqual(f.read(), "ghp_secret\n")
        self.assertIn("brewberry-update login --username tinkerius --password-stdin", self.log())
        self.assertNotIn("ghp_secret", self.log())

    def test_wifi_password_on_stdin_empty_for_an_open_network(self):
        status, data = self.api("POST", "/api/run/wifi.add", {"args": {"ssid": "Mein WLAN"}, "stdin": "secret pass"})
        self.assertEqual((status, data["stderr"]), (200, "saved Mein WLAN\n"))
        with open(os.path.join(self.fake, "wifi-password")) as f:
            self.assertEqual(f.read(), "secret pass")
        self.assertNotIn("secret pass", self.log())
        status, data = self.api("POST", "/api/run/wifi.add", {"args": {"ssid": "Guest"}, "stdin": ""})
        self.assertEqual(status, 200)
        with open(os.path.join(self.fake, "wifi-password")) as f:
            self.assertEqual(f.read(), "")
        # Other commands still need their secret.
        self.assertEqual(self.api("POST", "/api/run/update.login", {"args": {"username": "x"}, "stdin": ""})[0], 400)

    def test_wifi_names_checked_before_the_cli(self):
        before = self.log()
        for ssid in ("--yes", "a\nb", "x" * 33, ""):
            self.assertEqual(self.api("POST", "/api/run/wifi.forget", {"args": {"ssid": ssid}})[0], 400, ssid)
        self.assertEqual(self.log(), before)

    def test_wifi_forget_asks_only_for_the_current_network(self):
        status, data = self.api("POST", "/api/run/wifi.forget", {"args": {"ssid": "Shed"}})
        self.assertEqual((status, data["stderr"]), (200, "forgot Shed\n"))
        status, data = self.api("POST", "/api/run/wifi.forget", {"args": {"ssid": "Home"}})
        self.assertEqual((status, data["confirm"]), (409, "The Pi is connected to Home."))
        status, data = self.api("POST", "/api/run/wifi.forget", {"args": {"ssid": "Home"}, "yes": True})
        self.assertEqual((status, data["stderr"]), (200, "forgot Home\n"))
        self.assertIn("brewberry-wifi forget Home --yes", self.log())

    def test_upload_goes_through_brewberry_config(self):
        files = [{"name": "config.json", "data": base64.b64encode(b"{}").decode()},
                 {"name": "recipes/WIT.json", "data": base64.b64encode(b"{}").decode()}]
        status, data = self.api("POST", "/api/run/config.import", {"files": files})
        self.assertEqual(status, 200)
        with open(os.path.join(self.fake, "imported")) as f:
            self.assertIn("./config.json\n./recipes/WIT.json\n", f.read())
        self.assertEqual(os.listdir(os.path.join(self.tmp, "uploads")), [])
        bad = [{"name": "../evil.json", "data": base64.b64encode(b"{}").decode()}]
        self.assertEqual(self.api("POST", "/api/run/config.import", {"files": bad})[0], 400)

    def test_export_download(self):
        status, body, headers = self.request("GET", "/api/run/config.export", cookie=self.cookie)
        self.assertEqual((status, body), (200, b"TARDATA"))
        self.assertIn("brewberrypi-config.tar.gz", headers["Content-Disposition"])

    def test_password_change(self):
        self.assertEqual(self.api("POST", "/api/password", {"old": "wrong", "new": "brewing-2026"})[0], 401)
        self.assertEqual(self.api("POST", "/api/password", {"old": "pi", "new": "short"})[0], 400)
        self.assertEqual(self.api("POST", "/api/password", {"old": "pi", "new": "bad:pass:word"})[0], 400)
        status, data = self.api("POST", "/api/password", {"old": "pi", "new": "brewing-2026"})
        self.assertEqual(status, 200)
        with open(os.path.join(self.fake, "chpasswd")) as f:
            self.assertEqual(f.read(), "brewberry:brewing-2026\n")

    def test_zz_login_rate_limit(self):
        # 5 failures from an address are free (test_wrong_password made one).
        codes = [self.login("wrong")[0] for _ in range(6)]
        self.assertEqual(codes[:4], [401] * 4)
        self.assertIn(429, codes[4:])
        self.assertEqual(self.login("pi")[0], 429)


if __name__ == "__main__":
    unittest.main()
