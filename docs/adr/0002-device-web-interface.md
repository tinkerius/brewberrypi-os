# ADR-0002: Device web interface with CLI parity

- **Status:** Accepted (2026-10-15, implemented in OS9)
- **Note (2026-10-23):** the USB stick and `brewberry-usb` are removed by [ADR-0005](0005-config-folders-and-no-usb.md).
- **Date:** 2026-10-15
- **Deciders:** Benedikt Hauptmann (product owner); proposal by Claude Code

## Context

The Pi is managed only over SSH with root commands: `brewberry-update`, `brewberry-usb`,
`brewberry-maint`, plus a few plain Linux commands in the user manual. The product owner wants a
**web interface with exactly the same functions**, next to the app's web UI, and wants the CLI and
the web interface to keep offering the same functions in future.

Product-owner decisions (2026-10-15):

- Scope: every command the user manual documents.
- Port 8081; the app keeps 8080 (`Network=host`).
- No anonymous access. The image has the user `brewberry` with the default password `pi`, an
  administrator like an Imager user. The web login shows the user name; only the password is
  entered. The web interface can change the password; on the CLI that stays `passwd`.
- While `pi` is in use, the web interface shows a reminder; it never forces a change.
- Actions that restart the app warn when a brew is loaded or running, and go ahead after
  confirmation. The CLI must behave exactly the same, and changes where it doesn't.

Facts this ADR relies on:

- ADR-0001 planned updates from the **app's** web UI: request files in `/update`, a `.path` unit,
  a root oneshot. None of it was built (no `/update` mount, no path unit), and the app's spec
  question `Q-16` still defaults to "versions are changed with the OS tooling only". The app's UI
  has no login (app `IF-060`).
- The root is an overlay with a RAM upper layer, so `passwd` today lasts only until the next
  reboot.
- rpi-image-gen's `user1pass` rejects weak passwords such as `pi`, and its config values are
  expanded as shell variables, so a `$y$…` hash in `user1passhash` doesn't survive either.
- Python 3.13 (Trixie) has no `crypt` module; the system's libcrypt (yescrypt) is reachable
  through `ctypes`. python3 is on the image only as a cloud-init dependency.
- The CLIs print text only; just `brewberry-maint` asks for confirmation (`--yes`).

## Options considered

1. **Update UI inside the app (ADR-0001's plan, app `Q-16`).** Needs a runtime contract change
   (version 2), authentication the app doesn't have, and still a root service on the host. It
   would cover only versions, not USB, configuration or maintenance mode. Rejected.
2. **Cockpit.** Generic system administration, large, with its own login (PAM). It can't present the
   BrewberryPi commands or their confirmations without writing a Cockpit plugin, and would be a
   second implementation next to the CLIs. Rejected.
3. **A web server running as root that calls the CLIs.** Simple, but the HTTP parser faces the LAN
   with full privileges. Rejected.
4. **An unprivileged web server plus a root helper behind a Unix socket that only runs commands
   from a catalogue.** Small, no new packages besides python3 and curl, the CLIs stay the single
   implementation. `sudo` is blocked by `NoNewPrivileges=`, and polkit would add a package and a
   rule language for the same effect.
5. **Re-implement the device logic in Python and make the CLIs thin wrappers.** Parity by shared
   code, but it rewrites tested shell code (`tests/unit/update.sh`) for no user benefit. Rejected.

## Decision

We choose **option 4**. The design is specified in [docs/device-web-ui.md](../device-web-ui.md):

- **The CLIs stay the only implementation.** The web interface runs the same commands and shows
  their output. Every query gets `--json`; every action that restarts the app or reboots uses one
  confirmation protocol in the CLI (`--yes`, a terminal prompt, or exit code 10 with the prompt),
  including the brew warning from the app's `/healthz`. `brewberry-update install` and `rollback`
  therefore start asking for confirmation, like `brewberry-maint`.
- **New CLI commands** replace the plain Linux commands in the manual, so every function has a
  `brewberry-*` command: `brewberry-update restart`, non-interactive `login`, `brewberry-config
  import|export`, `brewberry-maint upgrade`, `brewberry-system info|logs`.
- **A command catalogue** (`/usr/share/brewberry/commands.json`) lists every operator command
  with argument patterns. The root helper runs only catalogue entries, the web interface builds its
  controls from it, and a parity test (`tests/unit/parity.sh`, in `scripts/lint.sh`) fails when the
  CLIs, the catalogue, the web interface and the manual's command reference differ. The password
  change is the one declared exception (CLI counterpart: `passwd`).
- **Processes:** `brewberry-web.service` (Python standard library, unprivileged user, port 8081)
  talks to `brewberry-webcmd@.service` (root, socket-activated per request). Long actions run as
  transient `systemd-run` units, so a closed browser or a restarted web server doesn't interrupt an
  install. The existing update lock serialises CLI, web and safe mode.
- **Accounts:** `brewberry` (`config/brewberrypi-base.yaml`, passwordless `sudo`) gets the
  password `pi` from a build hook with `chpasswd` (yescrypt); cloud-init leaves it unlocked. Password changes (web or `passwd`) are saved to `/data/secrets/shadow.d/`
  and applied at boot, which changes only the RAM layer.
- **Login:** session cookie (`HttpOnly`, `SameSite=Strict`), `Origin`/`Host` checks, a custom
  header on every `POST`, rate-limited failures.
- **Supersedes in part ADR-0001**, "Updating and selecting versions", steps 1 and 2 (request from
  the app's web UI, `.path` trigger) and the `/update` mount. Steps 3–6 (pull, soak, rollback,
  `tags.json`, safe mode, offline) stand; they are what `brewberry-update` implements.
- **Answers ADR-0001's open question** "Allow downgrades from the unauthenticated UI?": the device
  web interface is authenticated, so it allows any signed version, as the CLI does.

## Consequences

- **Positive:**
  - Everything an operator does over SSH can be done from a browser, with the same checks and the
    same texts.
  - Parity is checked in CI, not left to discipline.
  - The runtime contract and the app repository don't change; the registry token never reaches the
    app container.
  - `passwd` finally survives a reboot, for SSH users too.
- **Negative / risks:**
  - **Plain HTTP:** passwords, cookies and the registry token cross the LAN unencrypted, as the app's
    traffic does. Accepted for a home LAN.
  - **Default password `pi`** is the same on every device until changed; only a reminder.
  - Install, rollback and demo now ask for confirmation on the CLI: scripts need `--yes`.
  - A second network service on the Pi (memory on a Pi 3, attack surface).
  - Not yet tested on hardware: libcrypt via `ctypes` on Trixie arm64, `PathChanged=` on an
    overlay root, `systemd-run` jobs under the update lock.
- **Follow-ups:**
  - Milestone OS9 in the [implementation plan](../implementation-plan.md).
  - App repository: answer `Q-16` with "not part of the app; the OS's device web interface on port
    8081", and drop the pending `/update` and `updateAllowed` items from the runtime contract in
    its next version.
  - TLS with a self-signed certificate.
