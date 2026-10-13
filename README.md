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
| Implementation | Milestones OS0–OS7 in [docs/implementation-plan.md](docs/implementation-plan.md) | ✅ merged; on-device checks pending |
| End-to-end with the real app | OS8 | ⏳ waits for the app's first release |

## Documentation

**Setting up and running a BrewberryPi?** Read the [user manual](docs/user-manual.md):
flashing, configuration, app versions, USB, OS updates and troubleshooting.

| Document | Purpose |
|---|---|
| [docs/user-manual.md](docs/user-manual.md) | Installing, configuring and running BrewberryPi OS |
| [docs/development.md](docs/development.md) | Developer guide: build host, building, layers, tests, CI, workflow |
| [docs/releasing.md](docs/releasing.md) | Release procedure: versions, tag, draft, hardware checks, publish |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Milestones OS0–OS8 |
| [docs/flashing.md](docs/flashing.md) | Flashing with Raspberry Pi Imager and its customisation |
| [docs/os-update.md](docs/os-update.md) | OS update procedure (maintenance mode) |
| [docs/research/](docs/research/) | Research behind the decisions (primary sources, fact-checked) |
| Runtime contract (application repository: `docs/deployment/runtime-contract.md`) | What the app image expects from this OS |

## Development

The full developer guide is [docs/development.md](docs/development.md); releases follow
[docs/releasing.md](docs/releasing.md).

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
| `scripts/build-stub.sh` | Builds the contract stub for arm64 (`podman save` in `dir:` format); `build.sh` calls it unless `BREWBERRY_PRELOAD` names another image |
| `scripts/fetch-app.sh` | Fetches a signed app release (arm64) as the image's preload and verifies it; `build.sh` uses it when `BREWBERRY_APP_VERSION` is set |
| `scripts/imager-manifest.py` | Raspberry Pi Imager manifest for the images (release URLs or local files) |
| `scripts/lint.sh` | shellcheck, yamllint, layer metadata lint and the unit tests |
| `tests/integration/signing.sh` | Signature policy against a local registry with cosign v2 |

### Build in CI

Every push and pull request runs `.github/workflows/build.yml`. It builds both images on
`ubuntu-24.04-arm` runners and uploads them as the `brewberrypi-os-pi34` and `brewberrypi-os-pi5`
artifacts (kept 30 days). A version tag (`v1.2.3`) also creates a **draft release** with both
images, the Imager manifest and `SHA256SUMS`; publish it once the hardware checks pass
([docs/releasing.md](docs/releasing.md)). A pre-release tag (`v0.1.0-alpha.1`) is published at once
as a GitHub pre-release, marked as untested on hardware.

The image preloads the contract stub. To preload a released app version instead, set the
repository variable `BREWBERRY_APP_VERSION` (`x.y.z`) and give CI read access to the app's package:
the secret `BREWBERRY_GHCR_TOKEN` (classic PAT, `read:packages`), or add this repository under the
package's *Manage Actions access*. The build refuses an image that isn't signed with the pinned key.

The image's built-in admin user is `brewberry`. It has no password and logs in over SSH with a key
only, from the **repository variable** `BREWBERRY_SSH_PUBKEY` (Settings → Secrets and variables →
Actions → Variables). Usually you flash through Imager instead and create your own user there, with
a password, and either your SSH key or password logins over SSH (Imager's SSH setting).

### Build locally

On an arm64 Debian or Ubuntu host (or x86-64 with `qemu-user-static` and binfmt enabled):

```sh
scripts/lint.sh                                  # also fetches rpi-image-gen into .cache/
sudo .cache/rpi-image-gen/install_deps.sh        # once
BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh
```

### Flash, configure and run

Flashing, first boot, configuration, app versions (`brewberry-update`), USB (`brewberry-usb`),
OS updates (`brewberry-maint`) and troubleshooting are in the
[user manual](docs/user-manual.md). For a quick test of a local build:

1. Write an Imager manifest for it, then flash through it with Raspberry Pi Imager 2.x and set
   user, SSH key and Wi-Fi in its customisation ([docs/flashing.md](docs/flashing.md)):

   ```sh
   scripts/imager-manifest.py --local deploy/*.img.xz > brewberrypi-os.rpi-imager-manifest
   ```

2. Boot it. It reboots once by itself after the first boot.
3. `ssh brewberry@brewberrypi.local`, then `cat /etc/brewberry-release` shows the build version.
