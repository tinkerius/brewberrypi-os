# Flashing BrewberryPi OS

Flash with **Raspberry Pi Imager 2.x** through the release's manifest
`brewberrypi-os.rpi-imager-manifest`. Imager then offers its customisation: hostname, user with
SSH key, Wi-Fi and time zone. All of it is optional: without Wi-Fi the Pi opens its setup hotspot
`<hostname>`, and the Wi-Fi is chosen in the device web interface (ADR-0004,
[user manual](user-manual.md#wi-fi)). A plain *Use custom* image gets no customisation; Imager 2.x only
customises images whose manifest names the format (`cloudinit-rpi`). Imager 1.8 customises it too
(its *OS Customisation* dialog; tested on a Pi 3 with v0.1.0-alpha.6): it writes `user-data` and
`network-config` but no `meta-data`, so the image ships a default one.

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
| User | A new name (with the SSH key, and a password for the console). Not `brewberry`: the image's built-in account exists already, and cloud-init doesn't set an existing account's password from Imager. The account gets the image's default groups (`sudo`, `gpio`, …). |
| SSH | **Allow public-key authentication only** with your key (**ADD SSH KEY**, or paste `~/.ssh/id_ed25519.pub`), or **Use password authentication** to log in with the user's password. The image follows the choice; without one, password logins are off. Root can't log in over SSH. |
| Wi-Fi | Optional: SSID, password and country. On the first boot they move into `/data/config/os/wifi.json`. Without them, connect Ethernet or use the setup hotspot. |
| Time zone, keyboard | Applied as usual. |

Imager shows no interface options (SPI, I2C, 1-Wire, serial): the image's safety block in
`config.txt` decides them, and SPI would take the buzzer pin (BCM 10).

## First boot

1. cloud-init applies the customisation (Imager wrote it to the boot partition).
2. `/data` grows to fill the card, and the preloaded app is imported.
3. The system disables cloud-init, seals itself (read-only boot, RAM overlay over the root) and
   **reboots once by itself**.

Don't pull the plug during the first boot. After the reboot, `ssh <user>@<hostname>.local`.
If that doesn't work, put the card in a computer and read `brewberry-firstboot.txt` on the boot
partition: the seal step writes what cloud-init and the first-boot services did.

Wi-Fi is changed later in the device web interface or with `brewberry-wifi`. To change the
hostname or the user, reflash the card. Reflashing also erases
`/data`: download the configuration first (device web interface, **Configuration → Download**,
and `os/wifi.json` from the file share), and import it again afterwards.

## How it works

- `layer/brewberry-suite.yaml`: NetworkManager instead of systemd-networkd and iwd, as on
  Raspberry Pi OS; no `raspi-config`.
- `layer/brewberry-imager.yaml`: `cloud-init` and Raspberry Pi OS's `rpi-cloud-init-mods`. The
  NoCloud seed is in `/boot/firmware`, and netplan renders the network config through
  NetworkManager. `90-brewberry.cfg` makes `brewberry` the default user (keeping its password `pi`
  for the device web interface) and selects cloud-init's
  Debian distro class instead of Raspberry Pi OS's: that one creates Imager's user with
  `userconf-pi` and sets the keyboard with `raspi-config`, and the image has neither. Debian's
  class uses `useradd`, `chpasswd` and `console-setup`. The layer's build hook checks the merged
  configuration.
- SSH: cloud-init writes Imager's choice (`ssh_pwauth`) to `/etc/ssh/sshd_config.d/50-cloud-init.conf`,
  which sshd reads before the image's `90-brewberry.conf` (passwords off, root off).
- `brewberry-wifi-migrate.service` (layer `brewberry-wifi`) runs after cloud-init's network stage
  on the first boot only: it moves the Wi-Fi networks and the country from cloud-init's netplan
  files into `/data/config/os/wifi.json` and removes them from netplan, so `wifi.json` is the only
  place Wi-Fi is configured (ADR-0004).
- `brewberry-seal` creates `/etc/cloud/cloud-init.disabled` before sealing, so cloud-init never
  runs again: not on sealed boots, and not in maintenance mode.
- `scripts/imager-manifest.py` writes the manifest: `init_format: cloudinit-rpi`, device tags
  `pi3-64bit`/`pi4-64bit` or `pi5-64bit`, sizes and SHA-256 of the download and of the extracted
  image, and only the `passwordless_sudo` capability.
