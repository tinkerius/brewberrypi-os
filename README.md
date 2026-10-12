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
| [docs/flashing.md](docs/flashing.md) | Flashing with Raspberry Pi Imager and its customisation |
| [docs/os-update.md](docs/os-update.md) | OS update procedure (maintenance mode) |
| [docs/research/](docs/research/) | Research behind the decisions (primary sources, fact-checked) |
| Runtime contract (application repository: `docs/deployment/runtime-contract.md`) | What the app image expects from this OS |

## Development

The image is built with [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen), pinned in
`scripts/common.sh`.

| Path | Content |
|---|---|
| `config/brewberrypi-base.yaml` | Everything except the board, included by the board configs |
| `config/brewberrypi-pi34.yaml` | Image for Raspberry Pi 3 and 4 (v8 kernel) |
| `config/brewberrypi-pi5.yaml` | Image for Raspberry Pi 5 (2712 kernel, 16K pages) |
| `image/brewberry-mbr/` | Partition layout: p1 boot, p2 root (fixed), p3 `DATA` for `/data` |
| `layer/` | Our own rpi-image-gen layers; `*.rootfs-overlay/` holds the files they install |
| `stub/` | Contract stub image, preloaded until the app is released; `test_stub.py` |
| `tests/hardware/` | Checks that run on a real Pi (milestone "done when" checks) |
| `tests/unit/` | Host-side unit tests, e.g. the outputs-off reset with a fake `pinctrl` |
| `scripts/build.sh` | Builds `deploy/<image>-<version>.img.xz` plus a `.sha256` |
| `scripts/usb-export.sh` | Puts a signed app version on a USB stick and verifies it against the device policy |
| `scripts/build-stub.sh` | Builds the contract stub for arm64 (`podman save` tarball); `build.sh` calls it unless `BREWBERRY_PRELOAD` names another image |
| `scripts/fetch-app.sh` | Fetches a signed app release (arm64) as the image's preload and verifies it; `build.sh` uses it when `BREWBERRY_APP_VERSION` is set |
| `scripts/imager-manifest.py` | Raspberry Pi Imager manifest for the images (release URLs or local files) |
| `scripts/lint.sh` | shellcheck, yamllint, layer metadata lint and the unit tests |
| `tests/integration/signing.sh` | Signature policy against a local registry with cosign v2 |

### Build in CI

Every push and pull request runs `.github/workflows/build.yml`. It builds both images on
`ubuntu-24.04-arm` runners and uploads them as the `brewberrypi-os-pi34` and `brewberrypi-os-pi5`
artifacts (kept 30 days). A version tag (`v1.2.3`) also creates a **draft release** with both
images, the Imager manifest and `SHA256SUMS`; publish it once the hardware checks pass.

The image preloads the contract stub. To preload a released app version instead, set the
repository variable `BREWBERRY_APP_VERSION` (`x.y.z`) and give CI read access to the app's package:
the secret `BREWBERRY_GHCR_TOKEN` (classic PAT, `read:packages`), or add this repository under the
package's *Manage Actions access*. The build refuses an image that isn't signed with the pinned key.

The admin user is `brewberry`. It has no password and logs in over SSH with a key only. The key
usually comes from Imager's customisation; to build it into the image too, set the **repository
variable** `BREWBERRY_SSH_PUBKEY` (Settings → Secrets and variables → Actions → Variables).

### Build locally

On an arm64 Debian or Ubuntu host (or x86-64 with `qemu-user-static` and binfmt enabled):

```sh
scripts/lint.sh                                  # also fetches rpi-image-gen into .cache/
sudo .cache/rpi-image-gen/install_deps.sh        # once
BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh
```

### Flash and log in

1. Flash `brewberrypi-os-pi34-*.img.xz` (Pi 3/4) or `brewberrypi-os-pi5-*.img.xz` (Pi 5) with
   Raspberry Pi Imager 2.x **through the manifest**, and set hostname, user, SSH key and Wi-Fi in
   its customisation: see [docs/flashing.md](docs/flashing.md).
2. Boot it. On first boot it applies the customisation, grows `/data` to fill the card, seals
   itself (read-only boot, RAM overlay over the root) and **reboots once by itself**.
3. `ssh <user>@<hostname>.local` (default `brewberry@brewberrypi.local`, or the IP address from
   your router).
4. `cat /etc/brewberry-release` shows the build version.

From then on root and boot are read-only and only `/data` is written; changes anywhere else
are lost at reboot. OS updates go through maintenance mode: see
[docs/os-update.md](docs/os-update.md) (`brewberry-maint on`, `apt full-upgrade`,
`brewberry-maint off`).

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
