# Device web interface: architecture and design

**Status:** design, decided in [ADR-0002](adr/0002-device-web-interface.md); implemented in milestone
OS9 ([implementation plan](implementation-plan.md)). This page describes the target state. The user
manual and the developer guide change when OS9 is implemented.

## Contents

1. [Goal and requirements](#1-goal-and-requirements)
2. [Principle: one implementation, two front ends](#2-principle-one-implementation-two-front-ends)
3. [Components](#3-components)
4. [The command catalogue](#4-the-command-catalogue)
5. [CLI changes](#5-cli-changes)
6. [Jobs: long-running actions](#6-jobs-long-running-actions)
7. [Accounts, login and passwords](#7-accounts-login-and-passwords)
8. [HTTP API](#8-http-api)
9. [User interface](#9-user-interface)
10. [Parity enforcement](#10-parity-enforcement)
11. [Security](#11-security)
12. [Tests](#12-tests)
13. [What does not change](#13-what-does-not-change)

## 1. Goal and requirements

Today the Pi is managed over SSH with root commands (`brewberry-update`, `brewberry-usb`,
`brewberry-maint` and a few plain Linux commands in the [user manual](user-manual.md)). The device
web interface offers **the same functions in a browser**, next to the app's own web UI.

Requirements (product owner, 2026-10-15):

| ID | Requirement |
|---|---|
| WEB-01 | The web interface offers every command that the user manual documents, with the same behaviour as the CLI. |
| WEB-02 | CLI and web interface keep offering the same functions in future. A command that exists in only one of them is a defect. |
| WEB-03 | It runs in parallel to the app's web UI: the app keeps port 8080, the device web interface listens on **port 8081** (`http://<hostname>.local:8081/`). |
| WEB-04 | No anonymous access. The login page shows the fixed user name `brewberry`; only the password is entered. |
| WEB-05 | The image has the system user `brewberry` with the default password `pi`, an administrator (passwordless `sudo`) like a user created by Raspberry Pi Imager. |
| WEB-06 | The web interface can change the password. The CLI has no command for it: `passwd` is the Linux way. Both changes survive a reboot. |
| WEB-07 | While the default password `pi` is in use, the web interface shows a reminder. It never forces a change. |
| WEB-08 | Actions that restart the app warn when a brew is loaded or running, and go ahead after confirmation. The CLI behaves exactly the same. |

## 2. Principle: one implementation, two front ends

The web interface contains **no device logic**. Every action runs the same CLI command a user types
over SSH, and every view shows that command's own `--json` output. The CLIs remain the single
implementation; the web interface is a second front end over them.

This keeps the behaviour identical by construction:

- checks, signature policy, soak, rollback, locks and safety measures run in one place;
- the confirmation and warning texts come from the CLI (§5.3), and the web interface only displays
  them;
- a bug fixed in a CLI is fixed in the web interface too.

The one function without a `brewberry-*` command is the password change: its CLI counterpart is
the standard `passwd`. It is declared as such in the catalogue (§4).

## 3. Components

```mermaid
flowchart LR
  B[Browser] -- "HTTP :8081<br/>session cookie" --> W
  A[Browser] -- "HTTP :8080" --> APP
  subgraph Pi[BrewberryPi OS]
    W["brewberry-web.service<br/>Python stdlib HTTP server<br/>user brewberry-web, no privileges"]
    H["brewberry-webcmd@.service<br/>root helper, one per request<br/>validates against the catalogue"]
    C["CLIs: brewberry-update, -usb,<br/>-maint, -config, -system"]
    J["brewberry-job-*.service<br/>transient units (systemd-run)"]
    APP["brewberrypi.service<br/>app container (unchanged)"]
    D[("/data: update/, config/,<br/>secrets/")]
    W -- "Unix socket<br/>/run/brewberry-webcmd.sock" --> H
    H -- "queries: exec --json" --> C
    H -- "actions: systemd-run" --> J
    J --> C
    C --> D
    C -- "GET /healthz" --> APP
    C -- "restart, re-tag" --> APP
  end
```

| Component | Runs as | Job |
|---|---|---|
| `brewberry-web.service` | system user `brewberry-web`, `NoNewPrivileges=`, `ProtectSystem=strict`, `PrivateTmp=`, no capabilities | Serves the page and the JSON API on port 8081, checks sessions and request origins, forwards each request over the Unix socket. Keeps sessions in memory only. |
| `brewberry-webcmd.socket` | root-owned socket `/run/brewberry-webcmd.sock`, mode `0660`, group `brewberry-web`, `Accept=yes` | Starts one helper instance per request. |
| `brewberry-webcmd@.service` | root, `StandardInput=socket` | Reads one JSON request, checks it against the command catalogue and runs the CLI **without a shell**: queries directly, actions as a job (§6). Also checks and changes the password (§7). |
| `brewberry-job-<id>.service` | root, transient unit from `systemd-run --collect` | Runs one action with `--yes`. Survives a closed browser and a restart of the web server. |

**Why two processes:** the HTTP server faces the LAN and parses untrusted input, so it has no
privileges. The root side accepts only commands that are in the catalogue, with arguments that
match the catalogue's patterns. A compromised web process can at most run catalogue commands, as
a logged-in user can; it cannot get a root shell, read the registry token or write files.

**Why not other options** (see [ADR-0002](adr/0002-device-web-interface.md)): a web server running
as root would expose the HTTP parser with full privileges; `sudo` rules are blocked by
`NoNewPrivileges=`; polkit would add a package and a rule language for what one small socket
service does; Cockpit is large, generic and can't present the BrewberryPi commands.

**Layer `brewberry-web`** (requires `brewberry-update` and `brewberry-readonly`):

- packages: `python3` (on the image today only as a cloud-init dependency, so it is listed
  explicitly), `curl` (the brew warning reads `/healthz`);
- `/usr/lib/brewberry-web/`: `server.py`, `helper.py`, `index.html` (self-contained: no CDN, the Pi
  may be offline);
- `/usr/share/brewberry/commands.json`: the command catalogue (§4);
- units: `brewberry-web.service`, `brewberry-webcmd.socket`, `brewberry-webcmd@.service`,
  `brewberry-passwd-persist.path`/`.service`, `brewberry-passwd-restore.service` (§7);
- `/etc/avahi/services/brewberry-web.service`: announces `_http._tcp` on port 8081, so the device
  appears in browsers' and routers' service lists;
- a system user `brewberry-web` (no login shell, no home).

Python with the standard library only, like the contract stub (`stub/brewberrypi-stub.py`), whose
`ThreadingHTTPServer` and test approach are reused. Memory use stays small enough for a Pi 3 next
to the app (app `NFR-052`).

## 4. The command catalogue

`/usr/share/brewberry/commands.json` is the **single source of truth** for what an operator can do.
The helper accepts only its entries, the web interface builds its buttons from it, and the parity
test (§10) checks the CLIs and the user manual against it.

```json
{
  "version": 1,
  "commands": [
    {
      "id": "update.install",
      "argv": ["brewberry-update", "install", "{version}"],
      "args": { "version": "^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)\\.[0-9]+)?$" },
      "kind": "action",
      "confirm": true,
      "job": true,
      "screen": "versions",
      "manual": "user-manual.md#list-install-roll-back"
    },
    {
      "id": "account.password",
      "web_only": "The CLI uses the standard 'passwd'; see user-manual.md#4-logging-in",
      "kind": "action",
      "screen": "account"
    }
  ]
}
```

Fields: `id`; `argv` with `{placeholders}`; `args` with an anchored pattern per placeholder; `kind`
(`query` or `action`); `confirm` (asks first, §5.3); `job` (runs as a transient unit, §6); `reboots`;
`upload` (takes files, §8); `screen`; `manual` (the section that documents it); `web_only` with a
reason, for the declared exceptions.

### Commands per screen

Every command of the user manual's command reference, plus the ones its other sections use:

| Screen | Catalogue ids → CLI | Notes |
|---|---|---|
| Overview | `update.status`, `maint.status`, `system.info` | `system.info` is new (§5.4): replaces `cat /etc/brewberry-release` and adds hostname, addresses, uptime, `/data` usage |
| App versions | `update.list`, `update.install <version>`, `update.rollback`, `update.demo on\|off`, `update.restart` | `restart` is new (§5.4): replaces `systemctl reset-failed` + `restart brewberrypi` |
| Registry | `update.login` | gets non-interactive input (§5.4) |
| Configuration | `config.import <files>`, `config.export` | new CLI `brewberry-config` (§5.4): replaces the manual's SSH steps (`jq`, `cp`, `sync`, `mv`) and `scp -r` backup |
| USB stick | `usb.list`, `usb.install <version>`, `usb.import-config` | existing |
| OS update | `maint.on`, `maint.off`, `maint.upgrade` | `upgrade` is new (§5.4): replaces `apt update && apt full-upgrade`; only in maintenance mode |
| Logs | `system.logs <app\|safemode\|firstload\|outputs-off>` | new (§5.4): replaces the manual's `journalctl` lines |
| Account | `account.password` | `web_only`: CLI counterpart is `passwd` |

## 5. CLI changes

The CLIs get one machine interface that both front ends use. Human output stays as it is today
where possible.

### 5.1 Shared library

`/usr/lib/brewberry/common.sh`, sourced by every CLI and by `brewberrypi-safemode`: `log`, `die`,
`write_atomic`, `lock`, `confirm`, `engine_state`, `json_out`. It removes today's copies in each
script and makes the confirmation and warning texts identical everywhere.

### 5.2 `--json`

Every query accepts `--json` and prints one JSON object on stdout. The human output is formatted
from the same data, so the CLI and the browser show the same facts. Example, `brewberry-update
status --json`:

```json
{
  "active":   { "version": "1.2.3", "id": "3f1c…" },
  "previous": { "version": "1.2.2", "id": "9a07…" },
  "service":  "active",
  "engine":   "NoProcess",
  "last":     { "time": "…", "phase": "done", "version": "1.2.3", "message": "1.2.3 is active" },
  "safemode": null,
  "demo":     false,
  "busy":     false
}
```

Errors keep going to stderr; with `--json`, a failing command also prints `{"error": "<message>"}`
on stdout and keeps its exit code.

### 5.3 Confirmation and the brew warning (WEB-08)

Every action marked `confirm` in the catalogue follows one protocol, in the CLI:

1. Validate the arguments (a bad version fails before any question).
2. Build the prompt. `engine_state` reads `GET http://127.0.0.1:<server.port>/healthz`, with
   `server.port` from `/data/config/config.json` (default 8080) and a 2 s timeout:
   - engine not `NoProcess`: "**A brew is loaded or running (engine: Running). This ends it.**"
     followed by what the action does;
   - engine `NoProcess`, or the app is down or not answering: only what the action does, for
     example "This installs 1.2.3 and restarts the app."
3. Then:
   - with `--yes`: go ahead;
   - on a terminal: print the prompt and read `yes`;
   - otherwise: print the prompt (as `{"confirm": "<prompt>"}` with `--json`) and exit with code
     **10**, "confirmation needed".

The web interface calls the command without `--yes`, shows the returned prompt in a dialog, and on
**Confirm** calls it again with `--yes`. It is a warning, never a refusal, on both sides.

This applies to `update install|rollback|demo|restart`, `usb install|import-config`,
`config import`, and `maint on|off|upgrade`.

**Behaviour change:** `brewberry-update install`, `rollback`, `demo` and `brewberry-usb install`
now ask for confirmation, as `brewberry-maint` already does. Scripts and
`tests/hardware/os4-check.sh` pass `--yes`.

### 5.4 New subcommands

| Command | Replaces in the manual | What it does |
|---|---|---|
| `brewberry-update restart` | `systemctl reset-failed brewberrypi; systemctl restart brewberrypi` | Restarts the app; reports a configuration error (exit 2/3) like `install` does |
| `brewberry-update login --username <u> --password-stdin` | interactive `login` (still works) | Non-interactive form for the web interface; the token is read from stdin and never appears in an argument list or log |
| `brewberry-config import <file>…` | the SSH steps in "Configuration → Over SSH" | Same checks, backup and atomic writes as `brewberry-usb import-config`, which then calls it; offers the app restart (confirm) |
| `brewberry-config export` | `scp -r …:/data/config` | Writes a `.tar.gz` of `/data/config` (without `backup/`) to stdout |
| `brewberry-maint upgrade` | `apt update && apt full-upgrade` | Refuses unless in maintenance mode; runs non-interactively (`-y`, keeps changed config files); logs to the job |
| `brewberry-system info` | `cat /etc/brewberry-release` | OS release, hostname, addresses, uptime, `/data` usage |
| `brewberry-system logs <unit> [--lines N]` | the `journalctl -u … -b` lines in "Troubleshooting" | Current boot's journal of `app`, `safemode`, `firstload` or `outputs-off` |

`systemctl`, `journalctl` and `apt` keep working as before; the manual then shows the
`brewberry-*` command first.

## 6. Jobs: long-running actions

An install can take minutes (pull, then a 60 s soak). Actions marked `job` therefore don't run
inside the request:

1. The helper starts `systemd-run --unit=brewberry-job-<UTC timestamp> --collect --property=…
   <argv> --yes` and returns the job id at once (`202`).
2. The web interface polls `GET /api/jobs/<id>`: unit state, exit code, the job's output
   (`journalctl -u brewberry-job-<id> -o cat`) and, for installs, `/data/update/state.json`'s phase.
3. A closed browser or a restarted web server doesn't interrupt the job. The overview lists the
   running job, so any browser can follow it.
4. The existing lock `/run/brewberry-update.lock` keeps a web job, a CLI command and safe mode from
   running at the same time; `status --json` reports `busy`.
5. Actions that reboot (`maint on|off`) show a "rebooting" page that reconnects when the Pi is back.

Job units and their logs live in RAM (volatile journal); a reboot clears them. The result of the
last install or rollback stays in `/data/update/state.json`, as today.

## 7. Accounts, login and passwords

### 7.1 The user `brewberry` (WEB-05)

`config/brewberrypi-base.yaml`:

```yaml
device:
  user1: brewberry
  user1passhash: '$y$j9T$…'    # yescrypt hash of "pi"
  user1sudo: nopasswd
```

- rpi-image-gen's plain-text `user1pass` enforces strong passwords and would reject `pi`.
  `user1passhash` is copied into `/etc/shadow` unchecked; the password typed at login is still
  `pi`. The hash is generated once with `mkpasswd -m yescrypt pi`.
- If Imager sets a password for `brewberry`, it replaces `pi`. If Imager creates another user,
  `brewberry` keeps `pi` and the web interface keeps logging in as `brewberry`.
- SSH stays key-only unless Imager enables password logins
  (`sshd_config.d/90-brewberry.conf`), so `pi` does not open SSH by default.

### 7.2 Passwords that survive a reboot (WEB-06)

The root is an overlay with a RAM upper layer, so today `passwd` changes `/etc/shadow` only until
the next reboot. Two units fix this for `passwd` and the web interface alike:

- `brewberry-passwd-persist.path` (`PathChanged=/etc/shadow`) starts a service that writes the
  hashes of the login users (UID ≥ 1000) to `/data/secrets/shadow.d/<user>`, mode `0600`, atomically
  (temp file, fsync, rename).
- `brewberry-passwd-restore.service` (after `data.mount`, before `ssh.service` and
  `brewberry-web.service`) applies them at boot with `usermod -p`. That changes only the RAM layer,
  so the rule "never write to root at runtime" holds.

### 7.3 Web login (WEB-04)

- The login page shows `brewberry` as fixed text and one password field.
- The helper checks the password against `/etc/shadow` with the system's `crypt()` (libcrypt via
  `ctypes`; Python 3.13 has no `crypt` module).
- On success the web server creates a session: a random 256-bit token in a cookie with
  `HttpOnly`, `SameSite=Strict` and `Path=/`, kept in memory, expiring after 30 minutes without
  activity. A web server restart logs everyone out.
- After 5 failed logins from an address, each further attempt waits longer (1 s, doubling, up to
  60 s).
- Every request except the login page and its assets needs a session (`401` otherwise).

### 7.4 Password change (WEB-06) and the reminder (WEB-07)

- **Account** screen: current password, new password twice; at least 8 characters; the helper sets
  it with `chpasswd` (yescrypt). The persistence unit (§7.2) saves it to `/data`.
- After each login the helper checks whether the hash still matches `pi`. If it does, every screen
  shows: "You are using the default password. Change it under *Account*." Everything keeps working;
  the change is never forced.

## 8. HTTP API

All JSON. Every `POST` must carry `Content-Type: application/json` (uploads: `multipart/form-data`)
and the header `X-Brewberry: 1`, and its `Origin` must match `Host` (§11).

| Request | Response |
|---|---|
| `POST /api/login` `{password}` | `200` + session cookie, `{defaultPassword: bool}`; `401` |
| `POST /api/logout` | `204` |
| `POST /api/password` `{old, new}` | `204`; `400` (too short), `401` (old wrong) |
| `GET /api/commands` | the catalogue, without `argv` |
| `GET /api/run/<id>?<arg>=…` (queries) | `200 {output}` (the CLI's JSON); `422 {error}` |
| `POST /api/run/<id>` `{args, yes}` (actions) | `409 {confirm}` (needs confirmation), `202 {job}` (job started), `200 {output}`, `422 {error}`, `423 {busy}` (lock held) |
| `GET /api/jobs/<id>` | `{state, exitCode, log, phase}` |
| `POST /api/run/config.import` (multipart) | as above; files are staged in `/data/tmp/web-upload/<id>/` (max 1 MiB each, like the USB import), handed to `brewberry-config import` and deleted |
| `GET /api/run/config.export` | `application/gzip` download |

## 9. User interface

One page, no build step: vanilla JavaScript and inline CSS in `index.html`, light and dark following
the browser, and the app's look (indigo/slate, cards). English, like the app.

- **Header:** "BrewberryPi device", hostname, OS version, user `brewberry`, **Log out**; a link to the
  app's UI (`http://<host>:<server.port>/`).
- **Banner** for the default password (§7.4) and for a running job.
- **Screens** as tabs, matching §4: Overview, App versions (with Registry), Configuration, USB stick,
  OS update, Logs, Account.
- Buttons carry the catalogue id (`data-cmd="update.install"`), which the parity test reads.
- Confirmation dialog shows the CLI's prompt text verbatim (§5.3); the brew warning appears in bold.
- The OS update screen repeats the manual's warning: the power must stay connected from
  maintenance mode on until it is off again.

## 10. Parity enforcement

WEB-02 is enforced by a test, not by discipline alone. `tests/unit/parity.sh`, run by
`scripts/lint.sh` and therefore by CI, fails if any of these differ:

1. **CLI ↔ catalogue:** the subcommands in each CLI's usage header and dispatcher, and the
   catalogue entries that name that CLI.
2. **Catalogue ↔ web:** the catalogue ids, the `data-cmd` ids in `index.html`, and the ids the
   helper accepts.
3. **Catalogue ↔ manual:** the commands in the user manual's command reference and the catalogue.

Declared exceptions (`web_only`, for example the password change) must name their CLI
counterpart. A new CLI command without a web control, or a web feature without a CLI command, is
therefore a red CI run. `CLAUDE.md` states the rule for contributors: change the CLI, the catalogue,
the web interface and the manual in one change.

## 11. Security

| Threat | Measure |
|---|---|
| Anonymous use on the LAN | Login required for everything (WEB-04); rate-limited login |
| Another web page in the user's browser triggers actions (CSRF, app `Q-17`) | `SameSite=Strict` cookie, `Origin` must equal `Host`, custom header on every `POST` |
| DNS rebinding | `Host` must be the Pi's hostname, `<hostname>.local`, one of its IP addresses, or `localhost` |
| Command injection | Catalogue only; anchored argument patterns; no shell anywhere (`argv` lists); uploads staged under a generated name |
| A compromised web server | It runs unprivileged and can only send catalogue requests over the socket |
| Weak default password | Reminder banner (WEB-07); SSH stays key-only by default |
| Downgrades | Allowed, as on the CLI: only signed versions install, and only logged-in users can ask. This answers ADR-0001's open question for the web interface. |
| **Plain HTTP** | Passwords, session cookies and the registry token cross the LAN unencrypted, as with the app (app `IF-060`). Accepted for a home LAN; TLS with a self-signed certificate is a follow-up. |

Safety is unchanged: the web interface only runs the CLIs, which keep the outputs-off reset,
watchdogs, signature policy and `/data`-only writes.

## 12. Tests

- **Unit (host, `scripts/lint.sh`):**
  - Python `unittest` for `server.py` and `helper.py`, modelled on `stub/test_stub.py`: the server
    as a subprocess on a free port, fake CLIs and a fake `systemd-run` on `PATH`, a fake shadow
    file. Covers login and sessions, `401` without a session, `Origin`/`Host` checks, rejection of
    unknown ids and bad arguments, the `409` → confirm → `202` flow, jobs and uploads.
  - Shell tests (`tests/unit/update.sh`, `usb.sh`, `maint.sh`, new `config.sh`, `system.sh`): `--json`
    output, `--yes`, exit code 10, the brew warning with a fake `curl`.
  - `tests/unit/parity.sh` (§10).
- **Hardware:** `tests/hardware/os9-check.sh`:
  - port 8081 answers, every API call without a session gets `401`;
  - an install started in the browser gives the same `brewberry-update status` as one from the CLI;
  - restarting `brewberry-web` during an install doesn't interrupt it;
  - with the stub reporting `Running`, the CLI and the web interface show the same warning;
  - a password changed in the web interface, and one changed with `passwd`, survive a reboot;
  - the reminder disappears after the change.

## 13. What does not change

- The **runtime contract** (version 1) and the app repository. The app's open question `Q-16`
  ("update from the web UI") can be answered there with: not part of the app; the OS's device web
  interface on port 8081 does it.
- The app container: no `/update` mount, no access to the registry token.
- Safety measures, `policy.json` and the image tags `active` and `previous`.
