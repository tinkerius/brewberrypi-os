# Developer guide

How to work on BrewberryPi OS: set up a build host, build and test images, change layers, and get
a change merged. Releasing is in [releasing.md](releasing.md); running a device is in the
[user manual](user-manual.md).

Read [ADR-0001](adr/0001-os-image-and-app-runtime.md) first. It explains why the OS is built the
way it is (read-only root, `/data`, Podman + Quadlet, signed images), and most review comments
come back to it.

## Contents

1. [Rules that are never relaxed](#1-rules-that-are-never-relaxed)
2. [Repository layout](#2-repository-layout)
3. [Build host setup](#3-build-host-setup)
4. [Building an image](#4-building-an-image)
5. [How the image is put together](#5-how-the-image-is-put-together)
6. [Changing the image](#6-changing-the-image)
7. [Tests](#7-tests)
8. [CI](#8-ci)
9. [Trying a change on a Pi](#9-trying-a-change-on-a-pi)
10. [Workflow: branches, commits, pull requests](#10-workflow-branches-commits-pull-requests)
11. [Maintenance tasks](#11-maintenance-tasks)

## 1. Rules that are never relaxed

The Pi switches a **mains-powered heater**. These hold for every change, tests included:

- **Every stop path leaves the relays off.** The outputs-off reset in `ExecStopPost=`,
  `dtparam=strict_gpiod`, the `gpio=` boot pins, the systemd watchdog and the hardware watchdog
  stay as they are. Don't weaken them to make a test pass.
- **Nothing writes to root or boot at runtime.** Persistent data goes to `/data` only, written
  atomically (temp file, `fsync`, rename).
- **No raspi-config overlay toggle.** The image uses `overlayroot=tmpfs:recurse=0` and
  `brewberry-maint`.
- **Podman:** never `podman image prune -a`; keep `localhost/brewberrypi:active` and `:previous`;
  `policy.json` stays default-reject with pinned keys.
- **Signing:** cosign **v2.x** (v3's default format is unreadable for Podman 5.4).
  `keys/app-cosign.pub` must equal the app repository's `deploy/signing/cosign.pub`.
- **GPIO:** BCM pin numbers; never hard-code a gpiochip number.
- **Runtime contract:** the app repository's `docs/deployment/runtime-contract.md` (version 1) is
  the interface this OS implements. Changing it needs a new contract version in both
  repositories.

## 2. Repository layout

| Path | Content |
|---|---|
| `config/brewberrypi-base.yaml` | Shared image config: user, partition sizes, SSH, the layer list |
| `config/brewberrypi-pi34.yaml`, `brewberrypi-pi5.yaml` | Board configs: include the base, set the device layer and image name |
| `image/brewberry-mbr/` | Image layer `image-brewberry`: MBR with p1 boot, p2 root (fixed size), p3 `DATA` |
| `layer/<name>.yaml` | Our rpi-image-gen layers (metadata header + mmdebstrap packages and hooks) |
| `layer/<name>.rootfs-overlay/` | Files the layer installs, at their path in the root filesystem |
| `stub/` | Contract stub app (`brewberrypi-stub.py`, `Containerfile`, `test_stub.py`) |
| `scripts/` | Build, lint, release and helper scripts; `common.sh` pins rpi-image-gen |
| `tests/unit/` | Host-side tests with fakes, run by `scripts/lint.sh` |
| `tests/integration/signing.sh` | Signature policy against a local registry with cosign v2 |
| `tests/hardware/` | On-device checks, the milestones' "done when" (see its README) |
| `docs/adr/` | Decisions; copy `0000-template.md` for a new one |
| `docs/implementation-plan.md` | Milestones OS0–OS8 |

The layers, in the order the base config lists them:

| Layer | What it adds |
|---|---|
| `brewberry-suite` | Base suite: trixie-minbase with NetworkManager instead of networkd/iwd, no raspi-config |
| `brewberry-base` | mDNS (avahi), `/etc/brewberry-release` |
| `brewberry-readonly` | `data.mount`, first-boot grow/layout/seal, volatile journal, `brewberry-maint`, apt guard while sealed |
| `brewberry-safety` | `config.txt` safety block, `brewberrypi-outputs-off`, `RuntimeWatchdogSec` |
| `brewberry-podman` | Podman on `/data`, the Quadlet unit `brewberrypi.container`, gpiochip udev rule, `brewberry-firstload` |
| `brewberry-update` | `policy.json`, pinned keys, `brewberry-update`, `brewberry-usb`, `brewberrypi-safemode` |
| `brewberry-imager` | cloud-init for Imager's `cloudinit-rpi` customisation; disabled after first boot |

## 3. Build host setup

rpi-image-gen builds **natively on arm64**: a Raspberry Pi 5 with an SSD, an arm64 cloud VM, or an
Apple Silicon Mac running an arm64 Debian/Ubuntu VM. An x86-64 host works with `qemu-user-static`
and binfmt, but it is much slower.

```sh
git clone https://github.com/tinkerius/brewberrypi-os.git && cd brewberrypi-os
scripts/lint.sh                                # fetches the pinned rpi-image-gen into .cache/
sudo .cache/rpi-image-gen/install_deps.sh      # once
```

`lint.sh` stops at the first failure. On a fresh host, install its tools first:

```sh
sudo apt-get install -y shellcheck yamllint jq python3-yaml python3-debian python3-jsonschema
```

Also needed:

| Tool | For |
|---|---|
| `podman` | `scripts/build-stub.sh` (builds the stub for linux/arm64) |
| `skopeo`, `jq` | `scripts/fetch-app.sh`, `scripts/usb-export.sh`, the signing test |
| cosign **v2.x** | The signing test, `scripts/publish-test-stubs.sh` (CI pins v2.5.3) |
| Raspberry Pi Imager 2.x | Flashing through the manifest |

`.cache/rpi-image-gen` must sit at the pinned commit. If `fetch_rpi_image_gen` complains, delete
the directory and run again.

## 4. Building an image

```sh
BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh                        # Pi 3/4
BREWBERRY_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" scripts/build.sh brewberrypi-pi5.yaml   # Pi 5
```

The output is `deploy/<image>-<version>.img.xz` plus a `.sha256`. The version is
`git describe --tags --always --dirty`, so an uncommitted tree gives `…-dirty`. Work files go to
`work/`; delete it for a clean build.

| Variable | Effect |
|---|---|
| `BREWBERRY_SSH_PUBKEY` | Key for the `brewberry` user built into the image. Optional when you flash through the manifest and set a key in Imager; without either, you can't log in. |
| `BREWBERRY_APP_VERSION` | Preload this app version (`1.2.3` or a pre-release `1.2.3-alpha.N`) instead of the stub. `scripts/fetch-app.sh` fetches it from `ghcr.io/tinkerius/brewberrypi` and refuses it unless it is signed with the pinned key and labelled contract 1 and that version. Log in first: `skopeo login ghcr.io`. |
| `BREWBERRY_OS_VERSION` | OS version for the image name and `/etc/brewberry-release` (default: `git describe --tags`). CI sets it to the tag of a release build. |
| `BREWBERRY_PRELOAD` | Preload this local `dir:` image instead (`podman save --format docker-dir`). Not verified; development only. |
| `STUB_VERSION`, `STUB_START` | For `build-stub.sh`: the stub's version and start mode (`ok`, `crash`, `hwfail`, `config`, `hang`) |
| `RPI_IMAGE_GEN_DIR` | Use another rpi-image-gen checkout (it must still be at the pinned commit) |

`/etc/brewberry-release` on the device records what went in: `BREWBERRY_OS_VERSION`,
`BREWBERRY_OS_IMAGE`, `BREWBERRY_OS_APP_PRELOAD` (`stub`, a version or `custom`) and the build date.

To flash a local build with Imager's customisation, write a manifest that points at the file:

```sh
scripts/imager-manifest.py --local deploy/*.img.xz > brewberrypi-os.rpi-imager-manifest
```

## 5. How the image is put together

`scripts/build.sh` runs `rpi-image-gen build -S <repo> -c <board config>`, with overrides for the
version, the preload and the SSH key. rpi-image-gen then:

1. reads the board config, which includes `brewberrypi-base.yaml`. Its `layer:` map lists our
   layers; the keys are only labels. Each layer's `X-Env-Layer-Requires` pulls in its
   dependencies (rpi-image-gen's own layers, or ours);
2. builds the root filesystem with mmdebstrap (bdebstrap), layer by layer: it installs the
   `packages`, copies `layer/<name>.rootfs-overlay/` into the root, then runs the layer's
   `customize-hooks` (`$1` is the root directory). Because the overlay is copied first, a hook can
   enable units that the overlay ships;
3. lays out the partitions with the image layer `image-brewberry` (`image/brewberry-mbr/`).

Variables come from the layer metadata: `X-Env-VarPrefix: app` plus `X-Env-Var-preload` becomes
`IGconf_app_preload` in hooks. The config's YAML sections set them the same way (`image:` →
`IGconf_image_*`, `device:` → `IGconf_device_*`), and `build.sh` overrides them on the command
line.

On the device, the first boot runs `brewberry-growdata`, `brewberry-datalayout` (creates `/data`,
seeds `config.json` with `{}`), `brewberry-firstload` (imports the preload as
`localhost/brewberrypi:active`), cloud-init (Imager's customisation) and finally `brewberry-seal`,
which makes the system read-only and reboots once.

## 6. Changing the image

### Add or change a file on the device

Put it under the layer that owns the area, at its target path:
`layer/brewberry-<area>.rootfs-overlay/<path>`. Examples:

- a systemd unit: `…rootfs-overlay/usr/lib/systemd/system/foo.service`, plus
  `$BDEBSTRAP_HOOKS/enable-units "$1" foo.service` in the layer's `customize-hooks`;
- a root-only tool: `…rootfs-overlay/usr/local/sbin/foo`, executable. `lint.sh` runs shellcheck on
  every file in `layer/*.rootfs-overlay/usr/local/sbin/`, so keep it a shell script or adjust the
  lint.

Anything the device writes at runtime goes to `/data`, never to root or boot.

### Add a package

Add it to the owning layer's `mmdebstrap.packages`. The build installs no recommends, so list
what you need explicitly.

### Add a layer

1. Create `layer/brewberry-<name>.yaml` with a `METABEGIN … METAEND` header (copy one of ours):
   `X-Env-Layer-Name`, `-Category`, `-Desc`, `-Version`, `-Requires`, and any `X-Env-Var-*`.
2. Add it to the `layer:` map in `config/brewberrypi-base.yaml`.
3. Run `scripts/lint.sh`; it runs `rpi-image-gen metadata --lint` on every layer.

### Change the partition layout

Edit `image/brewberry-mbr/` (`image.yaml`, `genimage.cfg.in`, `setup.sh`, `pre-image.sh`) and the
sizes in `config/brewberrypi-base.yaml`. The root is never grown on the device, and `/data` is
grown on first boot. Run the OS1 hardware check (power-cut cycles) afterwards.

### Change the app unit

The Quadlet unit is the template
`layer/brewberry-podman.rootfs-overlay/usr/share/brewberrypi/brewberrypi.container.in`. A hook
fills in the gpio GID and the gpiochip devices, then runs the image's own `quadlet -dryrun`. The
build fails if Quadlet rejects the unit. Keep `WatchdogSec`, the outputs-off `ExecStopPost=` and
the start limits.

### Change the contract stub

Edit `stub/brewberrypi-stub.py` and `stub/test_stub.py`; `python3 -m unittest discover -s stub`
runs as part of `lint.sh`. The stub never drives the heater unless `allowHeat` is set. Its page at
`/` (the `PAGE` template) is what people see in a browser before an app is installed: keep it
self-contained (no external files; the Pi may be offline). Bump the default `STUB_VERSION` in
`build-stub.sh` when the stub changes.

### Write a decision down

A decision that changes the architecture or a rule above gets an ADR: copy
`docs/adr/0000-template.md` to the next number.

## 7. Tests

| Test | Where it runs | Command |
|---|---|---|
| Lint + unit tests | Host, CI job `lint` | `scripts/lint.sh` |
| Signature policy | Host with podman, skopeo, jq, cosign v2; CI job `signature policy` | `tests/integration/signing.sh` |
| Hardware checks | A real Pi | `tests/hardware/README.md` |

`lint.sh` runs shellcheck, yamllint (`config/`, `.github/`), the layer metadata lint, the stub's
unit tests and every `tests/unit/*.sh`. The unit tests run the device scripts on the host against
fakes: fake `podman`, `systemctl` and `pinctrl` in `PATH`, plus environment variables such as
`BREWBERRY_UPDATE_ROOT` and `BREWBERRY_SOAK_S=0` that point the script at a temporary root. To
test a new device script, follow `tests/unit/update.sh`: make the script's paths overridable
through environment variables, put fakes in a temporary `bin/`, and check what they were called
with.

The signing test starts a local registry, signs test images with throwaway keys and checks that
the device's real `policy.json` accepts only the right ones: from the registry, from a USB `dir:`
export, and as the build-time preload. Run it after any change to `policy.json`, `registries.d`,
the keys, `fetch-app.sh` or `usb-export.sh`.

Hardware checks are per milestone (`tests/hardware/osN-check.sh`, run over SSH with
`sudo sh -s`). OS4 needs signed test images in a test repository, never the app's; see
`scripts/publish-test-stubs.sh`.

## 8. CI

`.github/workflows/build.yml` runs on every push to `main`, every pull request, every `v*` tag and
on demand:

| Job | Runner | What |
|---|---|---|
| `lint` | ubuntu-24.04 | `scripts/lint.sh` |
| `signature policy` | ubuntu-24.04 | `tests/integration/signing.sh` with cosign v2.5.3 (checksum-pinned) |
| `image (pi34)`, `image (pi5)` | ubuntu-24.04-arm | `scripts/build.sh`; uploads `brewberrypi-os-<board>` artifacts, kept 1 day (storage quota) |
| `release` | ubuntu-24.04 | Tags only: draft release, or a published pre-release for `v*-alpha.N` tags (see [releasing.md](releasing.md)) |

Repository settings the build reads (Settings → Secrets and variables → Actions):

| Name | Kind | Purpose |
|---|---|---|
| `BREWBERRY_SSH_PUBKEY` | Variable | Key built into CI images (optional; warns when unset) |
| `BREWBERRY_APP_VERSION` | Variable | Preload this app release instead of the stub |
| `BREWBERRY_GHCR_TOKEN` | Secret | Classic PAT with `read:packages` for the app's private package. Alternatively, grant this repository access in the package's *Manage Actions access*. |

To try a branch's image without building locally, open its workflow run and download the
artifact.

## 9. Trying a change on a Pi

1. Build locally or download the CI artifact.
2. Flash through a local manifest (`scripts/imager-manifest.py --local …`) and set an SSH key in
   Imager, or build with `BREWBERRY_SSH_PUBKEY` and flash with *Use custom*.
3. Wait for the first-boot reboot, then `ssh brewberry@brewberrypi.local`.
4. Run the hardware checks for the area you changed (`tests/hardware/README.md`).

The device is sealed, so edits under `/` vanish at reboot. To experiment, switch to maintenance
mode (`sudo brewberry-maint on`, see [os-update.md](os-update.md)), but fix the change in the
repository and reflash rather than keeping a hand-modified device. While testing with relays,
use LEDs or the relay board **without the heater** (see OS3 in `tests/hardware/README.md`).

## 10. Workflow: branches, commits, pull requests

- Work on a branch and open a pull request against `main`. CI must be green before merging.
- Commit messages name the milestone (`OS3: …`) and, where relevant, the app's requirement IDs
  (`NFR-003`, `Q-16`).
- Pull requests reference the milestone issue (`Refs #n`, or `Closes #n` when its "done when"
  checks pass).
- Keep the [project board](https://github.com/users/tinkerius/projects/1) in sync: one issue per
  milestone, set to *In Progress* when work starts and *Done* + closed when its checks pass.
- Update the docs in the same pull request: `README.md`, `CLAUDE.md` (layout, commands), the user
  manual for anything a user sees, and `tests/hardware/README.md` for new checks.

## 11. Maintenance tasks

### Bump rpi-image-gen

In `scripts/common.sh`, set `RPI_IMAGE_GEN_TAG` and `RPI_IMAGE_GEN_COMMIT` together (the commit
the tag points at). Delete `.cache/rpi-image-gen`, run `scripts/lint.sh`, build both boards, and
compare `image/brewberry-mbr/` with upstream `image/mbr/simple_dual`, from which it is derived.

### Bump cosign

Stay on v2.x. Update `COSIGN_VERSION` and `COSIGN_SHA256` in `.github/workflows/build.yml`.

### Rotate the app signing key

The app repository owns the key. Replace
`layer/brewberry-update.rootfs-overlay/usr/share/brewberrypi/keys/app-cosign.pub` with the app's
new `deploy/signing/cosign.pub`, run the signing test, and release a new OS image. Devices on the
old image only accept images signed with the old key until they are reflashed, so plan the
overlap with the app repository.
