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
- `config/`: rpi-image-gen image configs (`brewberrypi-pi34.yaml`).
- `image/brewberry-mbr/`: our rpi-image-gen image layer (MBR p1 boot, p2 root, p3 `DATA`).
- `layer/`: our own rpi-image-gen layers; files they install live in `<layer>.rootfs-overlay/`.
  - `brewberry-base`: mDNS, `/etc/brewberry-release`.
  - `brewberry-readonly`: `data.mount`, first-boot grow/layout/seal services, volatile journal.
- `tests/hardware/`: on-device checks for the milestones' "done when" (`os1-check.sh`).
- `scripts/`: `build.sh`, `lint.sh`; `common.sh` pins the rpi-image-gen version.
- Podman config, the app unit and the contract stub: created in milestone OS2.

## Commands

- Build image: `BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh` (arm64 Debian/Ubuntu host, or QEMU binfmt; first run `sudo .cache/rpi-image-gen/install_deps.sh`). Output: `deploy/*.img.xz`.
- Lint: `scripts/lint.sh` (shellcheck, yamllint, rpi-image-gen layer metadata lint).
- CI: `.github/workflows/build.yml` builds the image on `ubuntu-24.04-arm` and uploads it as an artifact.

## Rules

- **Safety first.** Every stop path must leave the relays off: the outputs-off reset in `ExecStopPost=`, `dtparam=strict_gpiod`, `gpio=` boot pins, the systemd watchdog and the hardware watchdog. Never weaken these, not even in tests.
- **Never write to root or boot at runtime.** Persistent data goes to `/data` only, written atomically (temp file, fsync, rename).
- **Don't use raspi-config's overlay toggle.** Use `overlayroot=tmpfs:recurse=0` and `brewberry-maint` (see ADR-0001).
- **Podman:**
  - never run `podman image prune -a`;
  - keep `localhost/brewberrypi:active` and `:previous`;
  - keep `policy.json` at default reject with pinned keys.
- **Signing:** images are signed with cosign v2.x; v3's default format is not readable by Podman 5.4.
- **GPIO:** pin numbers are BCM numbers. Never hard-code a gpiochip number.
- Commit messages reference the milestone (`OS3`) and, where relevant, application requirement IDs (`NFR-003`).
- Keep the GitHub Project board [BrewberryPi OS](https://github.com/users/tinkerius/projects/1) in sync with the work. There is one issue per milestone (OS0–OS8); set it to *In Progress* when work starts and *Done* + closed when its "done when" checks pass (`gh project item-edit` on project 1). Pull requests reference the milestone issue (`Refs #n` / `Closes #n`).
