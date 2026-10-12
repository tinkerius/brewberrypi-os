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
| `tests/hardware/` | Checks that run on a real Pi (milestone "done when" checks) |
| `scripts/build.sh` | Builds `deploy/<image>-<version>.img.xz` plus a `.sha256` |
| `scripts/lint.sh` | shellcheck, yamllint and layer metadata lint |

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
