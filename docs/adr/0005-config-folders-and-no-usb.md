# ADR-0005: Configuration folders `app` and `os`, no USB stick

- **Status:** Accepted (implemented in OS12, not yet tested on hardware)
- **Date:** 2026-10-23
- **Deciders:** Benedikt Hauptmann (product owner); proposal by Claude Code
- **Supersedes:** the read-only `/config` mount of [ADR-0001](0001-os-image-and-app-runtime.md) and its USB
  stick (offline updates and config import, OS5); the folder layout of
  [ADR-0003](0003-config-file-share.md)

## Context

A recipe copied into the file share did not show up in the app: the app read its recipes only at start,
and used its built-in recipes while `/data/config/recipes/` was missing, which the OS deliberately did not
create (2026-10-23). The product owner asked for:

- two folders in the share's `config`: `app` and `os`, both created by the OS, which the user can't rename or
  delete;
- the app gets access to `app` only, read-write, and creates what it needs in it: `config.json` with every
  default, and `recipes/` with its shipped recipes, which are not written again once deleted;
- the app reads recipes only from disk, and sees changes without a restart (app `Q-29`, `RCP-006`);
- no migration of existing installations;
- no USB stick at all: the device is in a closed case. The only ways in are the device web interface, the file
  share and SSH.

## Options considered

1. **Keep `/data/config` read-only in the container, OS seeds the recipes** — the OS would need a copy of the
   app's recipes, and two parties would own one folder. Rejected.
2. **Mount `/data/config` read-write** — the app could change `wifi.json` (Wi-Fi passwords) and the backups.
   Rejected.
3. **Two folders, the app's mounted read-write through a shared group** — each side owns one folder.

## Decision

We choose **option 3**, as **runtime contract version 2** (both repositories).

- `/data/config` belongs to root (`0755`): the share's user can't rename or delete `app` and `os`, and can't
  create anything next to them. `brewberry-datalayout` creates both at every boot if missing, `2775`
  (set-group-ID), owner `brewberry`, group **`brewberry-config`**. It seeds nothing.
- `brewberry-config` is a system group (created by `brewberry-podman`). The Quadlet unit adds its GID to the
  container (`GroupAdd=`, rendered at build time like the gpio GID) and mounts only
  `/data/config/app:/config` read-write. `brewberry` is a member, for SSH. Samba's `force group` is
  `brewberry-config`, files `0660`, folders `2770`; the app writes `0664` / `0775` (app `NFR-032`).
- `os` holds `wifi.json` and `backup/<date>/` (Wi-Fi and `brewberry-config import` backups). It is never
  mounted into the container.
- The OS only reads `app/config.json` (outputs-off reset, the app's port, the boot-pin warning). Before the
  app's first start there is none, and the defaults apply.
- `brewberry-config import` replaces recipe files one by one inside `recipes/` instead of swapping the folder,
  because the app watches it and creates it when it is missing.
- **No USB:** `brewberry-usb`, `scripts/usb-export.sh`, the `/media/brewberry-usb` rule in `policy.json`,
  `brewberry-update install --from-dir`, the web page *USB stick* and OS5's checks are removed. `dir:` images
  are accepted only from the build-time preload. `scripts/fetch-app.sh` derives its `dir:` rule from the
  registry rule.
- `brewberry-update` and `scripts/fetch-app.sh` accept only images labelled contract 2; app versions before
  0.1.0-alpha.6 no longer install.

## Consequences

- Positive: a recipe saved in the share shows up in every browser within seconds, without a restart; a fresh
  device already shows the full `config.json` to edit; each side owns its folder; fewer ways in, less to test.
- Negative / risks: no offline install any more: a new app version needs the registry. Existing devices keep
  their old `/data/config/config.json`, `recipes/` and `wifi.json` at the top level, which the new layout
  ignores: reflash, or move the files by hand (no migration, as decided).
- Follow-ups: hardware check of OS12 (share, SSH and app all write in `app`; `app` and `os` can't be
  renamed over SMB).
