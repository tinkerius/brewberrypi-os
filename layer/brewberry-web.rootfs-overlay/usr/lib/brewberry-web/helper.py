#!/usr/bin/python3
"""Root helper of the device web interface (ADR-0002, OS9).

brewberry-webcmd.socket starts one instance per connection (Accept=yes) with
the connection on stdin and stdout. It reads one JSON request line from the
unprivileged web server (brewberry-web.service) and answers with one JSON line.
It runs only commands from the catalogue (/usr/share/brewberry/commands.json)
with arguments that match the catalogue's patterns, never through a shell.
Actions marked "job" run as transient systemd units, so a closed browser or a
restarted web server never interrupts them.

Requests ("op"):
  auth      {password}                -> {ok, defaultPassword}
  passwd    {old, new}                -> {ok} | {error, status}
  run       {id, args, yes, stdin, files}
            -> {confirm} | {job} | {exit, output, stderr} | {exit, data} | {busy} | {error}
  job       {job}                     -> {id, cmd, started, state, exit, log}
  jobs                                -> {jobs: [...]}

With --job <id> -- <argv...> it is the job runner inside the transient unit:
it runs argv, copies its output to the job's log and records the exit code.
"""

import base64
import ctypes
import ctypes.util
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time

CATALOGUE = os.environ.get("BREWBERRY_CATALOGUE", "/usr/share/brewberry/commands.json")
SHADOW = os.environ.get("BREWBERRY_SHADOW", "/etc/shadow")
JOBS_DIR = os.environ.get("BREWBERRY_JOBS_DIR", "/run/brewberry-jobs")
UPLOAD_DIR = os.environ.get("BREWBERRY_UPLOAD_DIR", "/data/tmp/web-upload")
USER = "brewberry"
DEFAULT_PASSWORD = "pi"
NEED_CONFIRM = 10            # exit code of a CLI action that wants --yes (common.sh)
MAX_REQUEST = 16 * 1024 * 1024
MAX_UPLOAD = 8 * 1024 * 1024
MAX_LOG = 64 * 1024
KEEP_JOBS = 20
JOB_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}-[0-9a-f]{6}$")
UPLOAD_NAME_RE = re.compile(r"^(recipes/[A-Za-z0-9_-]+\.json|[A-Za-z0-9._-]+\.json|[A-Za-z0-9._-]+\.(tar\.gz|tgz))$")


class Refused(Exception):
    """A request the helper doesn't run; the message goes back to the browser."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


# --- passwords --------------------------------------------------------------

def _crypt(password, setting):
    lib = ctypes.CDLL(ctypes.util.find_library("crypt") or "libcrypt.so.1")
    lib.crypt.restype = ctypes.c_char_p
    lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    result = lib.crypt(password.encode(), setting.encode())
    return result.decode() if result else None


def stored_hash():
    with open(SHADOW, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split(":")
            if fields[0] == USER and len(fields) > 1:
                return fields[1]
    return None


def check_password(password):
    stored = stored_hash()
    if not stored or stored[0] in "!*" or not isinstance(password, str) or not password:
        return False
    hashed = _crypt(password, stored)
    return hashed is not None and hmac.compare_digest(hashed, stored)


def op_auth(req):
    ok = check_password(req.get("password", ""))
    return {"ok": ok, "defaultPassword": ok and check_password(DEFAULT_PASSWORD)}


def op_passwd(req):
    old, new = req.get("old", ""), req.get("new", "")
    if not check_password(old):
        raise Refused("The current password is wrong.", 401)
    if not isinstance(new, str) or not 8 <= len(new) <= 128:
        raise Refused("The new password needs 8 to 128 characters.")
    if any(c in new for c in ":\n\r") or not new.isprintable():
        raise Refused("The new password must not contain ':' or control characters.")
    if new == DEFAULT_PASSWORD:
        raise Refused("Choose a password other than the default.")
    # chpasswd hashes it as configured (yescrypt); brewberry-passwd-persist
    # saves it to /data, so it survives the reboot.
    done = subprocess.run(["chpasswd"], input=f"{USER}:{new}\n", text=True,
                          capture_output=True, timeout=30, check=False)
    if done.returncode != 0:
        raise Refused("chpasswd failed: " + done.stderr.strip(), 500)
    return {"ok": True}


# --- catalogue commands -----------------------------------------------------

def catalogue():
    with open(CATALOGUE, encoding="utf-8") as f:
        return {c["id"]: c for c in json.load(f)["commands"]}


def build_argv(cmd, args):
    """The command's argv with its {placeholders} filled in from args."""
    if not isinstance(args, dict):
        raise Refused("args must be an object")
    patterns = cmd.get("args", {})
    unknown = set(args) - set(patterns)
    if unknown:
        raise Refused("unknown arguments: " + ", ".join(sorted(unknown)))
    argv = []
    for part in cmd["argv"]:
        m = re.fullmatch(r"\{([a-z]+)\}", part)
        if not m or m.group(1) == "upload":
            argv.append(part)
            continue
        value = args.get(m.group(1))
        if not isinstance(value, str) or not re.fullmatch(patterns[m.group(1)], value):
            raise Refused(f"invalid {m.group(1)}: {value!r}")
        argv.append(value)
    return argv


def run_cli(argv, stdin=None, timeout=60):
    try:
        done = subprocess.run(argv, input=stdin, capture_output=True, timeout=timeout, check=False,
                              stdin=None if stdin is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Refused(f"{' '.join(argv[:2])} did not finish within {timeout} s", 504)
    return done.returncode, done.stdout, done.stderr.decode(errors="replace")[-8000:]


def parse_json(data):
    try:
        return json.loads(data.decode())
    except (ValueError, UnicodeDecodeError):
        return None


def stage_upload(files):
    """Write uploaded files into a fresh folder; returns (folder, path to import)."""
    if not isinstance(files, list) or not files:
        raise Refused("no files")
    folder = os.path.join(UPLOAD_DIR, secrets.token_hex(8))
    os.makedirs(folder, mode=0o700)
    total, names = 0, []
    try:
        for f in files:
            name = f.get("name", "") if isinstance(f, dict) else ""
            if not UPLOAD_NAME_RE.fullmatch(name):
                raise Refused(f"not a configuration file name: {name!r}")
            data = base64.b64decode(f.get("data", ""), validate=True)
            total += len(data)
            if total > MAX_UPLOAD:
                raise Refused("the files are too large")
            path = os.path.join(folder, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as out:
                out.write(data)
            names.append(name)
    except (ValueError, TypeError) as e:
        shutil.rmtree(folder, ignore_errors=True)
        raise Refused(f"upload not readable: {e}") from None
    except Refused:
        shutil.rmtree(folder, ignore_errors=True)
        raise
    archives = [n for n in names if n.endswith((".tar.gz", ".tgz"))]
    if archives:
        if len(names) != 1:
            shutil.rmtree(folder, ignore_errors=True)
            raise Refused("upload an archive on its own")
        return folder, os.path.join(folder, archives[0])
    return folder, folder


def op_run(req):
    cmd = catalogue().get(req.get("id"))
    if not cmd or "argv" not in cmd:
        raise Refused(f"unknown command: {req.get('id')!r}", 404)
    argv = build_argv(cmd, req.get("args") or {})
    timeout = cmd.get("timeout", 60)

    if cmd.get("download"):
        rc, out, err = run_cli(argv, timeout=timeout)
        return {"exit": rc, "data": base64.b64encode(out).decode() if rc == 0 else "",
                "filename": cmd["download"], "stderr": err}
    if cmd["kind"] == "query":
        rc, out, err = run_cli(argv + ["--json"], timeout=timeout)
        return {"exit": rc, "output": parse_json(out), "stderr": err}

    if cmd.get("confirm") and not req.get("yes"):
        # The CLI validates its arguments, builds the prompt (with the brew
        # warning) and exits NEED_CONFIRM without changing anything.
        rc, out, err = run_cli(argv + ["--json"], timeout=60)
        result = parse_json(out) or {}
        if rc == NEED_CONFIRM and "confirm" in result:
            return {"confirm": result["confirm"]}
        return {"exit": rc, "output": result, "stderr": err}

    if cmd.get("job"):
        return start_job(cmd["id"], argv + (["--yes"] if cmd.get("confirm") else []))

    stdin = None
    if cmd.get("stdin"):
        value = req.get("stdin")
        if not isinstance(value, str) or not value or "\n" in value:
            raise Refused(f"{cmd['stdin']} missing")
        stdin = (value + "\n").encode()
    if cmd.get("upload"):
        folder, path = stage_upload(req.get("files"))
        try:
            rc, out, err = run_cli([path if a == "{upload}" else a for a in argv], timeout=timeout)
        finally:
            shutil.rmtree(folder, ignore_errors=True)
    else:
        rc, out, err = run_cli(argv, stdin=stdin, timeout=timeout)
    return {"exit": rc, "output": parse_json(out), "stderr": err}


# --- jobs --------------------------------------------------------------------

def job_path(job_id, ext):
    return os.path.join(JOBS_DIR, f"{job_id}.{ext}")


def unit_active(job_id):
    done = subprocess.run(["systemctl", "is-active", "--quiet", f"brewberry-job-{job_id}.service"],
                          capture_output=True, check=False)
    return done.returncode == 0


def job_info(job_id, with_log=True):
    with open(job_path(job_id, "json"), encoding="utf-8") as f:
        info = json.load(f)
    try:
        with open(job_path(job_id, "exit"), encoding="utf-8") as f:
            info["exit"] = int(f.read().strip())
        info["state"] = "done" if info["exit"] == 0 else "failed"
    except (OSError, ValueError):
        info["exit"] = None
        info["state"] = "running" if unit_active(job_id) else "lost"
    if with_log:
        try:
            with open(job_path(job_id, "log"), "rb") as f:
                f.seek(max(0, os.path.getsize(f.name) - MAX_LOG))
                info["log"] = f.read().decode(errors="replace")
        except OSError:
            info["log"] = ""
    return info


def job_ids():
    try:
        names = os.listdir(JOBS_DIR)
    except OSError:
        return []
    return sorted((n[:-5] for n in names if n.endswith(".json") and JOB_ID_RE.fullmatch(n[:-5])), reverse=True)


def start_job(cmd_id, argv):
    running = [j for j in job_ids() if job_info(j, with_log=False)["state"] == "running"]
    if running:
        return {"busy": running[0]}
    os.makedirs(JOBS_DIR, mode=0o700, exist_ok=True)
    for old in job_ids()[KEEP_JOBS:]:
        for ext in ("json", "log", "exit"):
            try:
                os.unlink(job_path(old, ext))
            except OSError:
                pass
    job_id = time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)
    with open(job_path(job_id, "json"), "w", encoding="utf-8") as f:
        json.dump({"id": job_id, "cmd": cmd_id, "argv": argv,
                   "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)
    done = subprocess.run(["systemd-run", f"--unit=brewberry-job-{job_id}", "--collect", "--quiet",
                           "--description=BrewberryPi web job: " + " ".join(argv),
                           sys.executable, os.path.abspath(__file__), "--job", job_id, "--", *argv],
                          capture_output=True, text=True, timeout=30, check=False)
    if done.returncode != 0:
        with open(job_path(job_id, "exit"), "w", encoding="utf-8") as f:
            f.write("127\n")
        raise Refused("could not start the job: " + done.stderr.strip(), 500)
    return {"job": job_id}


def run_job(job_id, argv):
    """Inside the transient unit: run argv, log its output, record its exit code."""
    with open(job_path(job_id, "log"), "ab") as log:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in proc.stdout:
            log.write(line)
            log.flush()
            sys.stdout.buffer.write(line)
            sys.stdout.flush()
        rc = proc.wait()
    tmp = job_path(job_id, "exit.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(f"{rc}\n")
    os.replace(tmp, job_path(job_id, "exit"))
    return rc


def op_job(req):
    job_id = req.get("job", "")
    if not isinstance(job_id, str) or not JOB_ID_RE.fullmatch(job_id) or not os.path.exists(job_path(job_id, "json")):
        raise Refused("no such job", 404)
    return job_info(job_id)


def op_jobs(_req):
    return {"jobs": [job_info(j, with_log=False) for j in job_ids()[:10]]}


OPS = {"auth": op_auth, "passwd": op_passwd, "run": op_run, "job": op_job, "jobs": op_jobs}


def handle(line):
    try:
        req = json.loads(line)
        if not isinstance(req, dict) or req.get("op") not in OPS:
            raise Refused("unknown request")
        return OPS[req["op"]](req)
    except Refused as e:
        return {"error": str(e), "status": e.status}
    except (ValueError, KeyError) as e:
        return {"error": f"bad request: {e}", "status": 400}


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--job" and sys.argv[3] == "--":
        if not JOB_ID_RE.fullmatch(sys.argv[2]):
            sys.exit(2)
        sys.exit(run_job(sys.argv[2], sys.argv[4:]))
    line = sys.stdin.buffer.readline(MAX_REQUEST)
    sys.stdout.write(json.dumps(handle(line)) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
