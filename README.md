# BrewberryPi OS

Operating-system image for [BrewberryPi](https://github.com/tinkerius/brewberrypi), a Raspberry Pi
controller for a home-brewing mash kettle. It is built to behave like a games console:

- **Flash it, plug it in, brew.** It's a ready-made image for Raspberry Pi 3, 4 and 5, flashed with Raspberry Pi Imager.
- **Unplugging is safe.** The system partitions are read-only; only a small data partition is written, and only during config changes and updates. The relays end up off on every stop.
- **The app runs as a signed container.** Podman + Quadlet run the BrewberryPi image from a private registry.
- **Pick a version.** Available versions are listed on the device; the chosen one is installed with automatic rollback, and there is a safe mode if it won't start.

## Status

| Phase | Content | Status |
|---|---|---|
| Design | [ADR-0001](docs/adr/0001-os-image-and-app-runtime.md), research in [docs/research](docs/research/) | ✅ done (2026-10-09) |
| Implementation | Milestones OS0–OS8 in [docs/implementation-plan.md](docs/implementation-plan.md) | ⏳ next |

## Documentation

| Document | Purpose |
|---|---|
| [docs/adr/](docs/adr/) | Architecture decision records |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Milestones OS0–OS8 |
| [docs/research/](docs/research/) | Research behind the decisions (primary sources, fact-checked) |
| Runtime contract (application repository: `docs/deployment/runtime-contract.md`) | What the app image expects from this OS |

## Development

The image is built with [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen), pinned in
`scripts/common.sh`.

| Path | Content |
|---|---|
| `config/brewberrypi-pi34.yaml` | Image for Raspberry Pi 3 and 4 |
| `image/brewberry-mbr/` | Partition layout: p1 boot, p2 root (fixed), p3 `DATA` for `/data` |
| `layer/` | Our own rpi-image-gen layers; `*.rootfs-overlay/` holds the files they install |
| `stub/` | Contract stub image, preloaded until the app is released; `test_stub.py` |
| `tests/hardware/` | Checks that run on a real Pi (milestone "done when" checks) |
| `tests/unit/` | Host-side unit tests, e.g. the outputs-off reset with a fake `pinctrl` |
| `scripts/build.sh` | Builds `deploy/<image>-<version>.img.xz` plus a `.sha256` |
| `scripts/usb-export.sh` | Puts a signed app version on a USB stick and verifies it against the device policy |
| `scripts/build-stub.sh` | Builds the contract stub for arm64 (`podman save` tarball); `build.sh` calls it unless `BREWBERRY_PRELOAD` names another image |
| `scripts/lint.sh` | shellcheck, yamllint, layer metadata lint and the unit tests |
| `tests/integration/signing.sh` | Signature policy against a local registry with cosign v2 |

### Build in CI

Every push and pull request runs `.github/workflows/build.yml`. It builds the image on an
`ubuntu-24.04-arm` runner and uploads it as the `brewberrypi-os-pi34` artifact (kept 30 days).

The admin user is `brewberry`. It has no password and logs in over SSH with a key only. Set the
public key as the **repository variable** `BREWBERRY_SSH_PUBKEY` (Settings → Secrets and variables →
Actions → Variables). Without it the build still succeeds, but nobody can log in.

### Build locally

On an arm64 Debian or Ubuntu host (or x86-64 with `qemu-user-static` and binfmt enabled):

```sh
scripts/lint.sh                                  # also fetches rpi-image-gen into .cache/
sudo .cache/rpi-image-gen/install_deps.sh        # once
BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh
```

### Flash and log in

1. Flash `brewberrypi-os-pi34-*.img.xz` with Raspberry Pi Imager → *Use custom*. Skip OS
   customisation for now; it comes with the Imager manifest in OS7.
2. Boot a Pi 3 or 4 with Ethernet connected. On first boot it grows `/data` to fill the card,
   seals itself (read-only boot, RAM overlay over the root) and **reboots once by itself**.
3. `ssh brewberry@brewberrypi.local` (or use the IP address from your router).
4. `cat /etc/brewberry-release` shows the build version.

From then on root and boot are read-only and only `/data` is written; changes anywhere else
are lost at reboot. OS updates will go through maintenance mode (OS6).

### App versions on the device

The app comes from the private registry `ghcr.io/tinkerius/brewberrypi`. Only images signed with
the app's pinned cosign key are accepted.

```sh
sudo brewberry-update login           # once: a GitHub classic PAT with read:packages only
sudo brewberry-update list            # available versions
sudo brewberry-update install 1.2.3   # pull, switch, watch 60 s, roll back if it fails
sudo brewberry-update rollback        # back to the previous version
sudo brewberry-update status
```

If the app keeps crashing (4 failed starts within 10 minutes), safe mode switches back to the
previous version once; if that fails too, the app stays down with all outputs off.

### Offline: USB stick

On a machine with registry access, put a version and/or config files on a stick:

```sh
scripts/usb-export.sh 1.2.3 /media/stick              # brewberrypi/images/1.2.3, signature included
mkdir -p /media/stick/brewberrypi/config && cp config.json /media/stick/brewberrypi/config/
```

Plug it into the Pi, then:

```sh
sudo brewberry-usb list
sudo brewberry-usb install 1.2.3       # checked against the pinned key like a registry pull
sudo brewberry-usb import-config       # validates, backs up /data/config, then copies
```

The stick is mounted read-only and only while the command runs.
