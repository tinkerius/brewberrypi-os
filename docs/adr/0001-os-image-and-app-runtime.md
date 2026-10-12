# ADR-0001: BrewberryPi OS — Image, Read-only Root, App Runtime and Updates

- **Status:** Accepted
- **Date:** 2026-10-09
- **Deciders:** Benedikt Hauptmann (product owner); proposal and research by Claude Code

## Context

The BrewberryPi application (repository `tinkerius/brewberrypi`, its ADR-0001) ships as a signed OCI
container image. This repository provides the operating system that runs it on a Raspberry Pi
3, 4 or 5 and controls a **mains-powered heater**. The interface between the two is the
**runtime contract**, `docs/deployment/runtime-contract.md` in the application repository,
contract version 1.

Product-owner wishes (2026-10-09):
- It behaves like a **games console**: pulling the plug is always safe, and after a restart the app is idle and the brew starts over.
- It is self-contained and practically indestructible.
- Deploying means pushing an image version to a registry and **selecting the version on the device**.
- **Local only**: no vendor cloud.
- **No hardware change** to the relay board.
- The registry is private: `ghcr.io/tinkerius/brewberrypi`.

Facts this ADR relies on (research 2026-10-08/09, primary sources, see `docs/research/`):

- **GPIO outputs persist after the owning process dies** (`persist_gpio_outputs` defaults to true on Pi 3/4/5). The host must actively reset the relay pins after every stop.
- **Pi 5 header GPIO chip numbers vary by kernel** (`gpiochip4`, `gpiochip0`, and `gpiochip15` on Bookworm 6.12.96).
- **raspi-config's overlay mode (`overlayroot=tmpfs`) also puts a RAM layer over every other ext4 mount.** Only `overlayroot=tmpfs:recurse=0` on the kernel command line, plus mounting `/data` with a systemd mount unit, keeps `/data` persistent.
- **First-boot customisation must write to root and boot.** That covers Imager settings, cloud-init or firstrun, machine-id and the disk ID. So the overlay can only be switched on after the first boot.
- **rpi-image-gen** (Raspberry Pi's image builder) supports custom MBR partition layouts, **arm64 only**, and builds natively on `ubuntu-24.04-arm` GitHub runners.
- **Podman 5.4.2 on Debian Trixie:**
  - its overlay storage driver refuses to run on an overlay root, so the image store must be on `/data`;
  - pulls stage in `/var/tmp` (RAM) unless `image_copy_tmp_dir="storage"` is set;
  - it reads cosign signatures only in the legacy `sha256-<digest>.sig` tag format;
  - `podman tag` moves a name atomically;
  - plain `podman image prune` keeps tagged images.
- **systemd 257:**
  - without `RestartMode=direct`, `OnFailure=` fires on every crash;
  - start limits also count manual starts;
  - `ExecStopPost=` runs on every exit path, including SIGKILL and watchdog kills.

## Options considered

1. **Stock Raspberry Pi OS Lite + install script.** Least build work. But the root partition expands over the whole card on first boot, which makes a data partition awkward. It feels like a Linux project, not a console.
2. **Own image with pi-gen.** Still builds 32-bit, but its two-partition layout is hard-coded.
3. **Own image with rpi-image-gen.** Custom layout and CI-native builds, arm64 only.
4. **balenaOS.** The closest to the console idea, but it needs a vendor cloud. Rejected: local only.
5. **A/B root partitions (tryboot) for OS updates.** The cleanest for OS updates, but upstream tooling targets Pi 4/5 with GPT, and four MBR partitions are tight on a Pi 3. Deferred.
6. **Data storage:** a third SD partition, or a USB stick. Cheap sticks fail more often and can be removed or lost. The stick is used only for imports and offline updates.

## Decision

### Image and partitions

- Built with **rpi-image-gen** on **Raspberry Pi OS Trixie (Debian 13), arm64 only**, in GitHub Actions (`ubuntu-24.04-arm`).
- One image for Pi 3/4 (`rpi-generic64`) and one for Pi 5 (`2712`), unless one image can carry both kernels (open question).
- Released as `.img.xz` plus a Raspberry Pi Imager manifest with `init_format`, so Imager offers hostname, Wi-Fi, SSH and user customisation.
- **MBR layout:**

| Partition | Size | Mount | At runtime |
|---|---|---|---|
| p1 vfat | about 512 MB | `/boot/firmware` | `ro` in fstab |
| p2 ext4 | about 3–4 GB, fixed | `/` | read-only through `overlayroot=tmpfs:recurse=0` (RAM upper layer) |
| p3 ext4, label `DATA` | small in the image, grown on first boot | `/data` via `data.mount` (`noatime,errors=remount-ro`), not in fstab | read-write |

- `/data` layout:
  - `config/`: `config.json` and recipes, mounted read-only into the container;
  - `containers/storage/`: Podman graphroot;
  - `tmp/`: pull staging;
  - `update/`: requests, state and `tags.json`;
  - `secrets/auth.json`: registry token;
  - optionally `log/`.
- `cmdline.txt` has no `resize` token. No overlay is active in the built image.

### First boot (once, stamp-guarded)

1. Imager or cloud-init customisation applies while root and boot are writable.
2. `brewberry-growdata.service` grows p3: `growpart` + `resize2fs`.
3. A layout service creates the `/data` directories and the seed config.
4. `brewberry-firstload` imports the app image preloaded in the OS image and tags it `localhost/brewberrypi:active`.
5. `brewberry-seal.service` adds `overlayroot=tmpfs:recurse=0` to `cmdline.txt` and reboots.

From then on, root and boot are read-only and only `/data` is written.

### OS updates

`brewberry-maint on|off` is our own script, replacing raspi-config's toggle:
- **on:** boot read-write, overlay parameter removed, reboot.
- Then `apt full-upgrade`.
- **off:** parameter restored, boot read-only, reboot.

Pulling the plug is **not** covered during this window or during the first boot. This is documented.

### App runtime: rootful Podman 5.4.2 + Quadlet

Podman configuration, baked into the image:
- `storage.conf`: `graphroot = "/data/containers/storage"`;
- `containers.conf`: `image_copy_tmp_dir = "storage"`;
- `policy.json`: default **reject**; `sigstoreSigned` with **pinned keys**, the current key plus a pre-provisioned next key for rotation; applies to the `docker` and `dir` transports;
- `registries.d`: `use-sigstore-attachments: true`.

Unit `/etc/containers/systemd/brewberrypi.container`:
- **Image:** `Image=localhost/brewberrypi:active`, `Pull=never`.
- **Container settings:**
  - `Notify=true`;
  - non-root `User=`;
  - `GroupAdd=` with the host's `gpio` GID;
  - `ReadOnly=true`, `NoNewPrivileges=true`, `DropCapability=ALL`.
- **Devices:** all GPIO chip nodes, each as an optional entry (`AddDevice=-/dev/gpiochipN`), because chip numbers vary by kernel.
- **Mounts:** `/data/config` → `/config` read-only; the update request directory → `/update`.
- **Service:**
  - `Restart=on-failure`, `RestartMode=direct`;
  - `StartLimitBurst=4` within `StartLimitIntervalSec=10min`;
  - `TimeoutStartSec=60`;
  - `WatchdogSec=20`, with the interval also passed in the `BREWBERRYPI_WATCHDOG_MS` environment variable;
  - `OnFailure=brewberrypi-safemode.service`.
- **`ExecStopPost=+/usr/local/sbin/brewberrypi-outputs-off`:**
  1. It force-removes the container, which releases the lines.
  2. It drives every output configured in `/data/config/config.json` to its off level with `pinctrl`.

### Host-side safety

- `config.txt`:
  - `dtparam=strict_gpiod`;
  - `gpio=<relay pins>=op,dh`, so relays are off as early as the firmware allows;
  - `dtoverlay=w1-gpio`;
  - SPI off, because BCM 10 is the buzzer.
- The hardware watchdog through systemd: `RuntimeWatchdogSec=`.

### Updating and selecting versions

1. **Request:** the app's web UI writes a request file. *Pending* app spec question `Q-16`.
2. **Trigger:** `brewberrypi-update.path` starts `brewberrypi-update.service`, a root oneshot under a lock.
3. **The update itself:**
   1. Validate the tag.
   2. `podman pull` with the registry token from `/data/secrets/auth.json`. A classic PAT with `read:packages`; it never enters the container. The signature policy is enforced here.
   3. Write a state file atomically.
   4. Re-tag: the old `active` becomes `previous`, the new image becomes `active`.
   5. `reset-failed` + `restart`, which waits for `READY=1`.
   6. Soak for 60 s.
   7. On failure, re-tag back, mark the new image `rejected` and restart.
   8. Delete images that are neither `active` nor `previous`. Never `prune -a`.
4. **Available versions:** the root side runs `skopeo list-tags` and writes `/data/update/tags.json` for the UI. Signature tags (`sha256-…`) are filtered out and the rest sorted by semantic version.
5. **Safe mode:** `brewberrypi-safemode.service` runs only when systemd gives up (start limit hit). Once, it swaps to `previous` and starts again. Otherwise the app stays down, with outputs already off.
6. **Offline:** a USB stick carrying the `dir:` format (`skopeo copy --all … dir:`) keeps the signatures, so `podman pull dir:/media/usb/…` is verified like a registry pull.

### CI (this repo and the app repo)

- The app repo signs with **cosign v2.x**, not v3, and gates every release by verifying it with `skopeo` against this repository's `policy.json`.
- This repo builds and releases the OS images and the Imager manifest.

## Consequences

- **Positive:**
  - Pulling the plug at runtime cannot damage root or boot, and `/data` is written only during config changes and updates.
  - App versions are picked on the device, signed, with automatic rollback and a safe mode.
  - Relays are reset after every stop, and hangs are killed by the watchdog.
  - Offline updates work.
- **Negative / risks:**
  - **64-bit only**: app spec question `Q-20`.
  - OS updates need maintenance mode with two reboots, and are not plug-safe during that window.
  - **Private registry:** each device stores a read-only token.
  - **Not yet tested on hardware:**
    - whether rpi-image-gen's build produces and boots an initramfs, which overlayroot needs;
    - whether `WatchdogSec` works through conmon;
    - whether `RestartMode=direct` fires `OnFailure` exactly once;
    - the `dir:` offline flow;
    - `pinctrl` reset behaviour on Pi 5;
    - the relay state during the power-on window (app `Q-18`);
    - whether the internal pull-up stays effective after a line is released.
- **Open questions:**
  - ~~One image for Pi 3/4/5, or two?~~ Two (OS7): the Pi 5 needs the 2712 kernel layer.
  - ~~Imager format: `cloudinit-rpi` or `systemd`?~~ `cloudinit-rpi` (OS7), as on current Raspberry Pi OS: cloud-init with `rpi-cloud-init-mods`, NetworkManager through netplan, disabled by `brewberry-seal` after the first boot. See `docs/flashing.md`.
  - Cost of arm64 runners for a private repo.
  - Allow downgrades from the unauthenticated UI?
  - Cost of `podman system check` on a Pi 3, at every boot or only after failures?
  - A recovery path for a power loss during first boot.
