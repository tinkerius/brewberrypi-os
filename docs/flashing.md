# Flashing BrewberryPi OS

Flash with **Raspberry Pi Imager 2.x** through the release's manifest
`brewberrypi-os.rpi-imager-manifest`. Imager then offers its customisation: hostname, user with
SSH key, Wi-Fi and time zone. A plain *Use custom* image gets no customisation; Imager 2.x only
customises images whose manifest names the format (`cloudinit-rpi`). Imager 1.x can't customise
this image.

## Images

| File | Boards |
|---|---|
| `brewberrypi-os-pi34-<version>.img.xz` | Raspberry Pi 3, 4, 400, CM4 |
| `brewberrypi-os-pi5-<version>.img.xz` | Raspberry Pi 5, 500, CM5 |

A release (draft until the hardware checks pass; pre-releases such as `v0.1.0-alpha.1` are published untested) holds both images, the manifest and
`SHA256SUMS`. It is built by the `release` job in `.github/workflows/build.yml` when a version
tag (`v1.2.3`) is pushed.

## Open the manifest

- **Public release:** download `brewberrypi-os.rpi-imager-manifest` and double-click it. Imager
  downloads the image itself.
- **Private repository, or images built yourself:** Imager can't download from a private
  repository. Download the `.img.xz` files, then write a manifest that points at the local files:

  ```sh
  scripts/imager-manifest.py --local ~/Downloads/brewberrypi-os-*.img.xz > brewberrypi-os.rpi-imager-manifest
  ```

  Double-click it, or in Imager: **App Options → Content Repository → Use custom file**, or run
  `rpi-imager --repo brewberrypi-os.rpi-imager-manifest`.

Pick the device, the BrewberryPi OS entry and the SD card, then **Customise**.

## Customisation

| Setting | Notes |
|---|---|
| Hostname | The device is then `<hostname>.local` (mDNS). Default: `brewberrypi`. |
| User | Use `brewberry` (the image's admin account) or a new name. Either way the account gets the SSH key. |
| SSH | **Public-key authentication only.** The image refuses password logins over SSH, even if Imager is set to allow them. |
| Wi-Fi | SSID, password and country. Without Wi-Fi, connect Ethernet. |
| Time zone, keyboard | Applied as usual. |

Imager shows no interface options (SPI, I2C, 1-Wire, serial): the image's safety block in
`config.txt` decides them, and SPI would take the buzzer pin (BCM 10).

## First boot

1. cloud-init applies the customisation (Imager wrote it to the boot partition).
2. `/data` grows to fill the card, and the preloaded app is imported.
3. The system disables cloud-init, seals itself (read-only boot, RAM overlay over the root) and
   **reboots once by itself**.

Don't pull the plug during the first boot. After the reboot, `ssh <user>@<hostname>.local`.

To change the customisation later (Wi-Fi, hostname), reflash the card. Reflashing also erases
`/data`: copy `/data/config` to a stick's `brewberrypi/config/` first, and bring it back with
`brewberry-usb import-config`.

## How it works

- `layer/brewberry-suite.yaml`: NetworkManager instead of systemd-networkd and iwd, as on
  Raspberry Pi OS; no `raspi-config`.
- `layer/brewberry-imager.yaml`: `cloud-init` and Raspberry Pi OS's `rpi-cloud-init-mods`. The
  NoCloud seed is in `/boot/firmware`, and netplan renders the network config through
  NetworkManager. `90-brewberry.cfg` makes `brewberry` the default user.
- `brewberry-seal` creates `/etc/cloud/cloud-init.disabled` before sealing, so cloud-init never
  runs again: not on sealed boots, and not in maintenance mode.
- `scripts/imager-manifest.py` writes the manifest: `init_format: cloudinit-rpi`, device tags
  `pi3-64bit`/`pi4-64bit` or `pi5-64bit`, sizes and SHA-256 of the download and of the extracted
  image, and only the `passwordless_sudo` capability.
