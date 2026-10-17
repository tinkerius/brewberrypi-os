# ADR-0003: File share of the app's configuration (SMB)

- **Status:** Proposed (implemented in OS10, not yet tested on hardware)
- **Date:** 2026-10-17
- **Deciders:** Benedikt Hauptmann (product owner); proposal by Claude Code

## Context

The product owner wants an SMB share of the app's configuration folder: users download, upload
and change `config.json`, recipes and other files directly in the share, from Windows, macOS or
Linux, without SSH, a USB stick or the device web interface's upload form (2026-10-17).

Facts this ADR relies on:

- `/data/config` holds `config.json`, `recipes/<id>.json` and `backup/<date>/`. It is mounted
  read-only into the app container, which reads it as UID 10001 and only **at start**.
- The root is an overlay with a RAM upper layer; only `/data` keeps anything (ADR-0001).
- `brewberrypi-outputs-off` reads the pins from `config.json` **when the app stops**. Until now
  the config changed only through `brewberry-config import`; a share makes changes while the app
  runs routine, so the reset could miss the pins the running app drives.
- SMB authenticates with NTLMv2 or Kerberos. NTLM needs the password's NT hash, which can't be
  derived from the account's yescrypt hash, so Samba keeps its own password database.
- Linux-PAM 1.6.0 and newer (Trixie: 1.7.0) give `pam_exec` with `expose_authtok` the **new**
  password in the password phase, after `pam_unix` has written it (`pam_sm_chauthtok`, not in the
  preliminary check). 1.5.x supported only the auth phase. Debian's `passwd` and `chpasswd` (the
  web interface's password change) both run the `common-password` stack; `usermod -p` and
  cloud-init's hashed passwords (Imager) do not.
- Debian's `smb.conf` is kept by `ucf`, not as a dpkg conffile.
- Verified with Samba 4.19 on Ubuntu 24.04 (and a `pam_exec` built from Linux-PAM 1.7.0): the
  configuration below, logins after `passwd` and `chpasswd`, the old password refused after a
  change, guests and SMB 2 refused, links out of the share refused, files created `0644` as
  `brewberry`.

## Options considered

1. **Samba sharing `/data/config` itself** (live): what the product owner asked for. Changes take
   effect at the next app start; nothing checks a file when it is saved.
2. **Samba sharing a staging folder**, applied with `brewberry-config import` (checks, backup,
   atomic writes). Safer, but not "directly in the share", and adds a step users forget.
3. **ksmbd** (in-kernel SMB server). Lighter, but a younger code base with a record of remote
   kernel vulnerabilities, and the Raspberry Pi kernel's support is not verified. Rejected.
4. **WebDAV in the device web interface.** No new package, but clients are clumsy (Windows'
   WebClient service, no `.local` names), and it isn't what was asked for. Rejected.
5. **Password for the share:** its own password (a second secret to manage, and a second
   web-only command), guest access (anyone on the LAN could move the heater pin), or **the
   `brewberry` account's password, kept in step**.

## Decision

We choose **option 1** with the account's password (option 5, last), in a new layer
`brewberry-share`:

- **Samba, smbd only:** one share `config` = `/data/config`, user `brewberry` only (`valid
  users`, `force user`/`group`), SMB 3 only, signing required, encryption when offered, no
  guests, no NetBIOS (nmbd disabled, `disable netbios`), no printers, home or user shares, no
  links out of the folder. macOS metadata goes to extended attributes (`vfs_fruit`,
  `streams_xattr`); `.DS_Store`, `Thumbs.db` and `desktop.ini` are refused. mDNS announces
  `_smb._tcp`.
- **Files belong to `brewberry`** (`0644`, folders `0755`), readable by the app's container user.
  `brewberry-share-sync start` (smbd's `ExecStartPre=`) gives wrong owners to `brewberry`, and
  `brewberry-config import` writes files with the folder's owner.
- **Password in step:** Samba's passdb and `secrets.tdb` live in `/data/secrets/samba/`
  (`private dir`). A `pam-auth-update` profile adds `pam_exec … expose_authtok
  brewberry-share-sync pam` to `common-password`; for `brewberry` it sets the share's password and
  records the account hash it belongs to (`account-hash`). At smbd's start, a share password whose
  account hash no longer matches is removed (logins fail until the password is set again); on a
  fresh image the build's hash of `pi` (`/usr/share/brewberry/default-password.hash`) gives the
  share `pi`.
- **On and off:** `brewberry-share status|on|off` (catalogue `share.*`, Configuration screen,
  user manual), on by default. Off is a marker on `/data` (`ConditionPathExists=!` on smbd), so it
  lasts across reboots. Logs: `brewberry-system logs share`.
- **Safety:** `brewberrypi.service` runs `brewberrypi-outputs-off --record` as `ExecStartPre=`: it
  writes the outputs of the config the app starts with to `/run/brewberrypi/outputs-started`. The
  reset after a stop drives those first, then the current config's other pins (and the defaults if
  the config is invalid), and never drives a recorded pin to a different level.
- `brewberry-maint upgrade` sets `UCF_FORCE_CONFFOLD=1`, so an upgrade keeps our `smb.conf`.

## Consequences

- **Positive:**
  - Config and recipes are edited like files on a network drive, from any desktop OS.
  - One password for the web interface, the share and the account, changed in one place.
  - The outputs-off reset covers a config changed while the app runs, by import too.
  - The runtime contract and the app repository don't change.
- **Negative / risks:**
  - **No checks on save:** an invalid file stops the app at its next start (exit 2/3, no
    rollback, outputs off); there is no automatic backup of files changed in the share.
  - A power cut while a client writes can leave a truncated file.
  - Moving an output pin in the share doesn't warn about the boot-time `gpio=` pins, as imports do.
  - A third network service (SMB, port 445): attack surface and memory (smbd, about 20–40 MB on a
    Pi 3). NTLMv2 with the default password `pi` is weak against anyone on the LAN.
  - A password set without PAM (Imager's hash for a user called `brewberry`) leaves the share
    without a password until it is set again.
  - Windows' Network view lists the Pi only with WS-Discovery, which is not installed; the
    address works without it.
  - Not yet tested on hardware: Samba 4.22 and Linux-PAM 1.7.0 on Trixie arm64, `pam-auth-update`
    in the build chroot, macOS and Windows clients, `ExecStartPre=` in the Quadlet unit.
- **Follow-ups:**
  - Milestone OS10 in the [implementation plan](../implementation-plan.md), check
    `tests/hardware/os10-check.sh`.
  - Maybe: `wsdd` for Windows' Network view; `brewberry-config check` to validate the folder after
    edits in the share; a backup when a changed config is first started.
