# BrewberryPi OS user manual

How to install, configure and run BrewberryPi OS on a Raspberry Pi. It's for the person who sets
up and looks after the brewing controller. You need a computer with Raspberry Pi Imager and an
SSH client, and you should be comfortable typing commands in a terminal.

The hardware (wiring, relay board, sensors) and the app itself (recipes, mashing, the web UI, the
format of `config.json`) are documented in the
[BrewberryPi app repository](https://github.com/tinkerius/brewberrypi). This manual covers only
the operating system around the app.

## Contents

1. [How it works](#1-how-it-works)
2. [What you need](#2-what-you-need)
3. [Installing](#3-installing)
4. [Logging in](#4-logging-in)
5. [Configuration](#5-configuration)
6. [App versions](#6-app-versions)
7. [Offline updates and config from a USB stick](#7-offline-updates-and-config-from-a-usb-stick)
8. [OS updates](#8-os-updates)
9. [Troubleshooting](#9-troubleshooting)
10. [Command reference](#10-command-reference)

## 1. How it works

BrewberryPi OS is built to behave like a games console:

- **Pulling the plug is safe** at any time, except during the [first boot](#first-boot) and
  [maintenance mode](#8-os-updates). After a restart the app starts idle, and a brew starts over.
- **The system is read-only.** Only the data partition, `/data`, keeps changes. Anything you
  change anywhere else is gone after the next reboot.
- **The app runs as a container.** It is signed, and the Pi only runs versions signed with the
  app's key. You choose the version on the device. A version that fails to start is rolled back
  automatically.
- **The relays end up off** every time the app stops, whether it exits, crashes, hangs or the
  power is cut.

What is kept where:

| Kept across reboots (`/data`) | Lost at every reboot |
|---|---|
| App configuration and recipes (`/data/config`) | Logs (`journalctl`) |
| The installed app versions (active and previous) | Files in home directories |
| The registry token (`/data/secrets`) | Changes to system files or packages |
| Update state and the version list (`/data/update`) | |

Reflashing the SD card erases everything, `/data` included.

## 2. What you need

- A Raspberry Pi 3, 4 or 5 (also 400, 500, CM4, CM5). Only 64-bit images exist.
- A microSD card, 8 GB or more.
- The BrewberryPi hardware, wired as the app's documentation describes.
- A network: Wi-Fi or Ethernet.
- On your computer: [Raspberry Pi Imager](https://www.raspberrypi.com/software/) **2.x** and an
  SSH key pair. To make one: `ssh-keygen -t ed25519`.
- For online app updates: a GitHub account with access to `ghcr.io/tinkerius/brewberrypi`.

## 3. Installing

### Get the image

Each release on the [Releases page](https://github.com/tinkerius/brewberrypi-os/releases) holds:

| File | For |
|---|---|
| `brewberrypi-os-pi34-<version>.img.xz` | Raspberry Pi 3, 4, 400, CM4 |
| `brewberrypi-os-pi5-<version>.img.xz` | Raspberry Pi 5, 500, CM5 |
| `brewberrypi-os.rpi-imager-manifest` | Raspberry Pi Imager's list of these images |
| `SHA256SUMS` | Checksums |

### Flash with Raspberry Pi Imager

Open the image **through the manifest**. Imager only offers its settings (Wi-Fi, SSH key and so on)
for images it opens that way. With *Use custom*, the Pi gets no Wi-Fi settings and none of your
SSH keys.

1. Open the manifest:
   - **Public release:** download `brewberrypi-os.rpi-imager-manifest` and double-click it.
   - **Private repository:** Imager can't download from it. Download the `.img.xz` for your board
     instead, and make a manifest for the local file with a checkout of this repository:

     ```sh
     scripts/imager-manifest.py --local ~/Downloads/brewberrypi-os-*.img.xz > brewberrypi-os.rpi-imager-manifest
     ```

     Then double-click the manifest, or in Imager pick **App Options → Content Repository → Use
     custom file**.
2. Pick your Raspberry Pi model, the **BrewberryPi OS** entry and the SD card.
3. Choose **Customise** and set:

   | Setting | What to enter |
   |---|---|
   | Hostname | For example `brewberrypi` (the default). The Pi is then `brewberrypi.local` on your network. |
   | User | A name of your own, with a password for logging in at the Pi's screen and keyboard. Not `brewberry`: that is the image's built-in account, and Imager can't set its password. |
   | SSH | Turn it on with **public-key authentication** and paste your public key (`~/.ssh/id_ed25519.pub`). Passwords are never accepted over SSH. |
   | Wi-Fi | Network name, password and Wi-Fi country. Leave it empty if you use Ethernet. |
   | Time zone, keyboard | Your own. |

   Imager shows no settings for SPI, I2C or 1-Wire: the image sets those itself.
4. Write the card.

### First boot

Put the card in the Pi, connect the network and power it on. On the first boot the Pi:

1. applies the Imager settings;
2. grows the data partition to fill the card and loads the app;
3. locks the system down to read-only and **reboots once by itself**.

This takes a few minutes. **Don't pull the plug during the first boot.**

To change the hostname or Wi-Fi later, reflash the card. Save your configuration first
([Backing up the configuration](#backing-up-the-configuration)).

## 4. Logging in

```sh
ssh <user>@brewberrypi.local           # your Imager user and hostname
```

If `.local` names don't work on your network, use the Pi's IP address from your router.

Check what's running:

```sh
cat /etc/brewberry-release             # OS version
sudo brewberry-update status           # app version and state
systemctl status brewberrypi           # the app service
```

Every command in this manual that changes something needs `sudo`. The admin user doesn't need a
password for it.

## 5. Configuration

The app reads its configuration from `/data/config`: `config.json` plus recipe files. The app's
documentation describes the format. The OS itself reads only the output pins from it, to switch
them off after the app stops ([Output pins](#output-pins)):

```json
{
  "hardware": {
    "heating": { "pin": 23, "activeLow": true },
    "pump":    { "pin": 22, "activeLow": true },
    "buzzer":  { "pin": 10, "activeLow": false }
  }
}
```

If the file or a key is missing, the defaults above apply. Pin numbers are BCM (GPIO) numbers.

The app can't write its own configuration: inside the container `/data/config` is read-only.
Change it from a USB stick (recommended) or over SSH.

### From a USB stick

This is the safest way: every file is checked first, and the old configuration is backed up.

1. On your computer, copy the files to the folder `brewberrypi/config/` on a USB stick, for
   example `brewberrypi/config/config.json`.
2. Plug the stick into the Pi and run:

   ```sh
   sudo brewberry-usb list               # shows what's on the stick
   sudo brewberry-usb import-config
   ```

   If any file isn't valid JSON, nothing is imported. The previous files are saved in
   `/data/config/backup/<date>/`.
3. The app reads its configuration only at start. Restart it (this ends a running brew):

   ```sh
   sudo systemctl restart brewberrypi
   ```

### Over SSH

Copy the file to the Pi, check it, and swap it in with a rename, so that a power cut can't leave
a half-written file:

```sh
scp config.json brewberry@brewberrypi.local:            # on your computer

jq empty config.json && echo valid                       # on the Pi
sudo cp config.json /data/config/config.json.tmp
sudo sync /data/config/config.json.tmp
sudo mv /data/config/config.json.tmp /data/config/config.json
sudo systemctl restart brewberrypi
```

### Backing up the configuration

Copy `/data/config` somewhere safe, for example to your computer:

```sh
scp -r brewberry@brewberrypi.local:/data/config ./brewberrypi-config
```

To restore it on a reflashed Pi, put the `.json` files into `brewberrypi/config/` on a stick and
run `brewberry-usb import-config`.

### Output pins

The OS switches the outputs off at two moments:

- **After every stop of the app** (exit, crash, hang, update): the pins from `config.json`, or the
  defaults.
- **At power-on**, before Linux starts: the firmware switches the **default** pins off (BCM 23
  and 22 driven high, BCM 10 driven low). These are set in `/boot/firmware/config.txt`.

If `config.json` moves an output to another pin, `brewberry-usb import-config` warns about it.
Then change the `gpio=` lines in `config.txt` to match; otherwise the new pin is only switched off
after the app stops, not at power-on. The boot partition is read-only, so do this in maintenance
mode:

1. `sudo brewberry-maint on` (reboots).
2. Edit the `gpio=` lines in the BrewberryPi block of `/boot/firmware/config.txt`. Active-low
   pins use `=op,pu,dh`, active-high pins use `=op,pd,dl`:

   ```
   gpio=22,23=op,pu,dh
   gpio=10=op,pd,dl
   ```

   Leave the rest of the block as it is.
3. `sudo brewberry-maint off` (reboots).

## 6. App versions

The Pi runs one app version, the *active* one, and keeps the one before it, the *previous* one,
to roll back to. App versions come from the private registry `ghcr.io/tinkerius/brewberrypi` and
must be signed with the app's key. Unsigned or wrongly signed images are refused.

Picking the version from the app's web UI is planned but not available yet. For now, use these
commands over SSH.

### Give the Pi access to the registry (once)

1. On GitHub, open **Settings → Developer settings → Personal access tokens → Tokens (classic) →
   Generate new token (classic)**.
2. Tick only the **`read:packages`** scope. Choose an expiry date and note it down.
3. On the Pi:

   ```sh
   sudo brewberry-update login
   ```

   Enter your GitHub user name, and the token as the password.

The token is stored in `/data/secrets/auth.json`, readable by root only. The app container never
sees it. When the token expires, create a new one and run `login` again.

### List, install, roll back

```sh
sudo brewberry-update list             # released versions, newest first
sudo brewberry-update install 1.2.3    # install and switch to 1.2.3
sudo brewberry-update status           # active and previous version, result of the last action
sudo brewberry-update rollback         # switch back to the previous version
```

Installing or rolling back restarts the app, which **ends a running brew**. What `install` does:

1. It downloads the version and checks its signature. If the signature check fails, nothing
   changes.
2. It checks that the version is made for this OS (the runtime contract) and really is the
   version you asked for.
3. It switches to it. The version that was active becomes the previous one.
4. It waits until the app reports ready, then watches it for **60 seconds**.
5. If the app fails to start or crashes in that time, it switches back automatically and reports
   `rolled-back`.
6. If the app refuses its configuration, the new version stays installed and the status reports
   `config-error`. Fix the configuration and restart the app.

Keep the power connected while an install runs. If it was cut, run `status` and install again.

### Safe mode

If the app fails to start 4 times within 10 minutes, the Pi switches back to the previous version
**once** and starts it. If that fails too, or there is no previous version, the app stays down
with all outputs off. `brewberry-update status` shows `safe mode:` when this happened. See
[Troubleshooting](#the-app-is-down-or-in-safe-mode).

A configuration error never makes the Pi switch versions, because the version isn't to blame.

## 7. Offline updates and config from a USB stick

For a Pi without internet access, prepare a stick on a computer that has access.

### Prepare the stick

You need a checkout of this repository, `skopeo` and `jq`, and a registry login
(`skopeo login ghcr.io`, with the same kind of token as above):

```sh
scripts/usb-export.sh 1.2.3 /media/stick                 # writes brewberrypi/images/1.2.3, signature included
mkdir -p /media/stick/brewberrypi/config                 # optional: configuration
cp config.json /media/stick/brewberrypi/config/
```

The script checks the export against the Pi's signature rules, so a stick the Pi would refuse is
noticed now. The stick then looks like this:

```
brewberrypi/
├── images/
│   └── 1.2.3/            one folder per version
└── config/
    └── config.json       optional
```

### Use it on the Pi

```sh
sudo brewberry-usb list                # versions and config files on the stick
sudo brewberry-usb install 1.2.3       # same checks, switch and rollback as an online install
sudo brewberry-usb import-config       # see Configuration
```

The Pi uses the first USB stick that has a `brewberrypi/` folder. It mounts the stick read-only
only while the command runs, so you can pull it out afterwards.

## 8. OS updates

App versions and the operating system are updated separately. OS updates (Raspberry Pi OS
packages, kernel, firmware) need **maintenance mode**, because the system is read-only otherwise.
Plan for two reboots and no brew running.

> **Keep the power connected** from `brewberry-maint on` until `brewberry-maint off` has rebooted.
> In that window the system is writable, and pulling the plug can damage it.

```sh
sudo brewberry-maint on                # asks to confirm, then reboots
# log in again
sudo brewberry-maint status            # "NOT sealed ... maintenance mode since ..."
sudo apt update
sudo apt full-upgrade
sudo brewberry-maint off               # asks to confirm, then reboots
# log in again
sudo brewberry-maint status            # "sealed"
```

The app keeps running in maintenance mode, with all its safety measures. If `off` refuses
because an update removed the BrewberryPi block from `/boot/firmware/config.txt`, see
[docs/os-update.md](os-update.md#steps). That page also covers power cuts during an update.

Alternatively, flash a newer BrewberryPi OS release. That erases `/data`, so back up the
configuration first, and run `brewberry-update login` again afterwards.

## 9. Troubleshooting

Logs are kept in memory and **lost at reboot**, so read them before you restart the Pi:

```sh
journalctl -u brewberrypi -b                    # the app
journalctl -u brewberrypi-safemode -b           # safe mode
journalctl -u brewberry-firstload -b            # loading the app on first boot
sudo brewberry-update status
```

### The first boot report

Before the Pi seals itself at the end of the first boot, it writes
`brewberry-firstboot.txt` to the boot partition: failed services, the cloud-init (Imager
customisation) status and log, the network state, and the logs of the first-boot services. Put
the SD card in any computer and open the file on the small FAT partition (`bootfs`). Look at it
first when the hostname, user, password or Wi-Fi from Imager weren't applied, or nothing answers
on the network.

### I can't find the Pi on the network

- Wait a few minutes after the first power-on: the Pi reboots once by itself.
- Use the IP address from your router instead of `<hostname>.local`.
- Wi-Fi settings are only applied on the first boot. If they were wrong, reflash.
- Check [the first boot report](#the-first-boot-report): if cloud-init found no Imager settings,
  the card was flashed with *Use custom* instead of the manifest, or customisation was skipped.
- `Permission denied (publickey)`: the key you use isn't the one you gave Imager. Passwords
  don't work over SSH.

### The app is down or in safe mode

1. Look at `sudo brewberry-update status` and `journalctl -u brewberrypi -b`.
2. If the app exited with code 2 or 3, it refused its configuration. Fix `/data/config`
   ([Configuration](#5-configuration)), then:

   ```sh
   sudo systemctl reset-failed brewberrypi
   sudo systemctl restart brewberrypi
   ```

3. Otherwise the version itself is broken. Install a working version, or roll back:

   ```sh
   sudo brewberry-update install 1.2.2
   ```

`reset-failed` is needed because manual restarts also count towards the limit of 4 starts in
10 minutes.

### `brewberry-update` says "no registry token" or the login fails

Run `sudo brewberry-update login` with a token that has the `read:packages` scope and hasn't
expired. After a reflash the token is gone, so log in again.

### An install says the signature was rejected

The image isn't signed with the app's key, or the download was changed on the way. Nothing was
changed on the Pi. Use a released version from `brewberry-update list`.

### A change I made is gone after a reboot

Everything outside `/data` is reset at every boot. Configuration belongs in `/data/config`, and
changes to the system need [maintenance mode](#8-os-updates).

### `apt` refuses to install anything

That's intended while the system is sealed. Use [maintenance mode](#8-os-updates).

### An output stays on after the app stopped

Power the system off at the mains. Check that the pins in `config.json` match your hardware
([Output pins](#output-pins); the wiring is in the app's documentation). After every stop, the Pi
logs which outputs it switched off and whether that failed:

```sh
journalctl -b | grep brewberrypi-outputs-off
```

## 10. Command reference

All commands run as root (`sudo`).

| Command | What it does |
|---|---|
| `brewberry-update login` | Store the registry token |
| `brewberry-update list` | Released app versions, newest first |
| `brewberry-update install <x.y.z>` | Install and switch to a version; rolls back if it fails |
| `brewberry-update rollback` | Switch back to the previous version |
| `brewberry-update status` | Active and previous version, last result, safe mode |
| `brewberry-usb list` | Versions and config files on a USB stick |
| `brewberry-usb install <x.y.z>` | Install a version from a USB stick |
| `brewberry-usb import-config` | Copy `brewberrypi/config/*.json` from a stick to `/data/config` |
| `brewberry-maint status` | Sealed (normal) or in maintenance mode |
| `brewberry-maint on` | Make the system writable for OS updates (reboots) |
| `brewberry-maint off` | Seal the system again (reboots) |
| `systemctl restart brewberrypi` | Restart the app (ends a running brew) |
| `cat /etc/brewberry-release` | OS version |
