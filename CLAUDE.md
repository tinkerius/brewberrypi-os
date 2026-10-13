# BrewberryPi OS

Operating-system image for BrewberryPi (Raspberry Pi 3/4/5 controlling a **mains-powered heater**).
It is built with rpi-image-gen on Raspberry Pi OS Trixie, arm64. The root is read-only (overlay),
a `/data` partition is writable, and the app runs as a signed container under Podman + Quadlet,
with version selection, rollback and safe mode.

## Related repository

- `tinkerius/brewberrypi`: the application, delivered as the image `ghcr.io/tinkerius/brewberrypi`.
- Its `docs/deployment/runtime-contract.md` is the **interface** this OS must implement (contract version 1). Do not change the contract unilaterally: a change needs a new contract version in both repositories.

## Layout

- `docs/adr/`: decisions (copy `0000-template.md`). Start with `0001-os-image-and-app-runtime.md`.
- `docs/implementation-plan.md`: milestones OS0–OS8.
- `docs/research/`: research summary and raw JSON (claims with sources).
- `docs/user-manual.md`: user manual for the OS (flashing, configuration, app versions, USB, OS updates, troubleshooting). Hardware, wiring and the app's config format belong in the app repo. Keep it in sync when commands or behaviour change.
- `docs/development.md`: developer guide (build host, building, how layers work, tests, CI settings, workflow, maintenance tasks). `docs/releasing.md`: release procedure (versions, tag → draft release, hardware checks, publish). Keep both in sync when scripts, CI or layers change.
- `docs/os-update.md`: OS update procedure (maintenance mode).
- `docs/flashing.md`: flashing with Raspberry Pi Imager through the manifest (customisation).
- `config/`: rpi-image-gen image configs: `brewberrypi-base.yaml` (shared), `brewberrypi-pi34.yaml` (Pi 3/4), `brewberrypi-pi5.yaml` (Pi 5).
- `image/brewberry-mbr/`: our rpi-image-gen image layer (MBR p1 boot, p2 root, p3 `DATA`).
- `layer/`: our own rpi-image-gen layers; files they install live in `<layer>.rootfs-overlay/`.
  - `brewberry-suite`: the base suite (trixie-minbase with NetworkManager instead of networkd/iwd, no raspi-config).
  - `brewberry-base`: mDNS, `/etc/brewberry-release`.
  - `brewberry-readonly`: `data.mount`, first-boot grow/layout (seeds `config.json` = `{}`)/seal services, volatile journal, `brewberry-maint` (maintenance mode), apt guard while sealed.
  - `brewberry-safety`: `config.txt` safety block (strict_gpiod, `gpio=` boot pins, w1-gpio, SPI off, watchdog), `brewberrypi-outputs-off`, `RuntimeWatchdogSec`.
  - `brewberry-podman`: Podman config (storage on `/data`), the Quadlet unit `brewberrypi.container` (rendered at build time with the gpio GID; `WatchdogSec`, outputs-off `ExecStopPost`, start limits, safe mode), gpiochip udev rule, `brewberry-firstload` (imports the `dir:` preload).
  - `brewberry-imager`: cloud-init + `rpi-cloud-init-mods` for Imager's `cloudinit-rpi` customisation; `brewberry-seal` disables cloud-init after first boot.
  - `brewberry-update`: `policy.json` (default reject; app's pinned cosign key in `keys/app-cosign.pub` for the registry and for USB `dir:` exports under `/media/brewberry-usb`; unsigned only from the preload dir), registries.d, the `brewberry-update` (incl. demo mode: `--dummymode` via `/data/update/app-args.env`) and `brewberry-usb` CLIs, `brewberrypi-safemode`.
- `stub/`: contract stub image (READY, WATCHDOG, `/healthz`, crash/hang/refuse on request, heater test behind `allowHeat`), preloaded until the app is released.
- `tests/hardware/`: on-device checks for the milestones' "done when" (`os1-check.sh` … `os7-check.sh`).
- `tests/unit/`: host-side unit tests with fakes (`outputs-off.sh`, `update.sh`, `usb.sh`, `maint.sh`, `datalayout.sh`, `imager-manifest.sh`), run by `scripts/lint.sh`.
- `tests/integration/signing.sh`: policy test with a local registry and cosign v2 (CI job `signature policy`).
- `scripts/`: `build.sh`, `build-stub.sh`, `lint.sh`, `imager-manifest.py` (Imager manifest), `fetch-app.sh` (verified app release as the preload, `BREWBERRY_APP_VERSION`), `publish-test-stubs.sh` (OS4 test images), `usb-export.sh`; `common.sh` pins the rpi-image-gen version.

## Commands

- Build image: `BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh [brewberrypi-pi5.yaml]` (arm64 Debian/Ubuntu host, or QEMU binfmt; first run `sudo .cache/rpi-image-gen/install_deps.sh`). Output: `deploy/*.img.xz`.
- Lint: `scripts/lint.sh` (shellcheck, yamllint, rpi-image-gen layer metadata lint, unit tests in `stub/` and `tests/unit/`).
- CI: `.github/workflows/build.yml`: lint, the signature policy test, and the image builds for `pi34` and `pi5` on `ubuntu-24.04-arm` (uploaded as artifacts). A `v*` tag also creates a draft release (images, Imager manifest, `SHA256SUMS`); a pre-release tag (`v0.1.0-alpha.1`) is published at once as a GitHub pre-release with an untested-on-hardware warning. `.github/workflows/tag-release.yml` (manual) creates such a tag on `main` and starts that build, for when tags can't be pushed.
- Imager manifest for local images: `scripts/imager-manifest.py --local deploy/*.img.xz > brewberrypi-os.rpi-imager-manifest`.
- On the device (root): `brewberry-update login|list|status|install <version>|rollback|demo on|off`, `brewberry-usb list|install <version>|import-config`, `brewberry-maint status|on|off`.

## Rules

- **Safety first.** Every stop path must leave the relays off: the outputs-off reset in `ExecStopPost=`, `dtparam=strict_gpiod`, `gpio=` boot pins, the systemd watchdog and the hardware watchdog. Never weaken these, not even in tests.
- **Never write to root or boot at runtime.** Persistent data goes to `/data` only, written atomically (temp file, fsync, rename).
- **Don't use raspi-config's overlay toggle.** Use `overlayroot=tmpfs:recurse=0` and `brewberry-maint` (see ADR-0001).
- **Podman:**
  - never run `podman image prune -a`;
  - keep `localhost/brewberrypi:active` and `:previous`;
  - keep `policy.json` at default reject with pinned keys.
- **Signing:** images are signed with cosign v2.x; v3's default format is not readable by Podman 5.4. `keys/app-cosign.pub` must equal the app repo's `deploy/signing/cosign.pub`.
- **GPIO:** pin numbers are BCM numbers. Never hard-code a gpiochip number.
- Commit messages reference the milestone (`OS3`) and, where relevant, application requirement IDs (`NFR-003`).
- Keep the GitHub Project board [BrewberryPi OS](https://github.com/users/tinkerius/projects/1) in sync with the work. There is one issue per milestone (OS0–OS8); set it to *In Progress* when work starts and *Done* + closed when its "done when" checks pass (`gh project item-edit` on project 1). Pull requests reference the milestone issue (`Refs #n` / `Closes #n`).
