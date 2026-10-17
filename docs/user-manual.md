# BrewberryPi OS user manual

How to install, configure and run BrewberryPi OS on a Raspberry Pi. It's for the person who sets
up and looks after the brewing controller. You need a computer with Raspberry Pi Imager and a
browser. Everything after flashing can be done in the **device web interface**
(`http://<hostname>.local:8081/`) or with the same commands over SSH; this manual shows both.

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
- **Two web pages:** the app's own UI for brewing on port 8080, and the **device web interface**
  on port 8081 for everything around it: app versions, configuration, USB stick, OS updates,
  logs. The device web interface runs exactly the commands described here, with the same checks
  and warnings ([Logging in](#4-logging-in)).
- **A file share** of the app's configuration folder, `\\<hostname>.local\config`: open,
  download and change `config.json` and the recipes from Windows, macOS or Linux
  ([In the file share](#in-the-file-share)).

What is kept where:

| Kept across reboots (`/data`) | Lost at every reboot |
|---|---|
| App configuration and recipes (`/data/config`) | Logs (`journalctl`) |
| The installed app versions (active and previous) | Files in home directories |
| The registry token and changed passwords (`/data/secrets`) | Changes to system files or packages |
| Update state and the version list (`/data/update`) | |

Reflashing the SD card erases everything, `/data` included.

## 2. What you need

- A Raspberry Pi 3, 4 or 5 (also 400, 500, CM4, CM5). Only 64-bit images exist.
- A microSD card, 8 GB or more.
- The BrewberryPi hardware, wired as the app's documentation describes.
- A network: Wi-Fi or Ethernet.
- On your computer: [Raspberry Pi Imager](https://www.raspberrypi.com/software/) **2.x** (1.8 works
  too), and for key logins an SSH key pair. To make one: `ssh-keygen -t ed25519`.
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
   | User | A name of your own, with a password for logging in at the Pi's screen and keyboard. Not `brewberry`: that is the image's built-in account (password `pi`, for the device web interface), and Imager can't set its password. |
   | SSH | Turn it on. **Allow public-key authentication only** with your public key (**ADD SSH KEY**, or paste `~/.ssh/id_ed25519.pub`) is the safer choice; **Use password authentication** lets you log in with the user's password. |
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

### In a browser: the device web interface

Open `http://<hostname>.local:8081/`, for example `http://brewberrypi.local:8081/`. Log in as the
user **`brewberry`** (shown on the page) with the password; the default is **`pi`**.

**Change the default password** right away under **Account**: everyone on your network knows `pi`.
Until you do, every page reminds you. The password is also the Linux password of the user
`brewberry` and the password of the [file share](#in-the-file-share). It survives reboots,
wherever you change it: under *Account*, or with `passwd`.

The pages: **Overview** (app, device, system state), **App versions**, **Configuration**,
**USB stick**, **OS update**, **Logs** and **Account**. Each button runs the command of the same
name from this manual ([Command reference](#10-command-reference)) on the Pi, with the same checks.
Actions that restart the app or reboot the Pi ask first, and warn when a brew is loaded or running.
Long actions (an install, an OS update) keep running when you close the page; open it again to see
how they ended.

The page uses plain HTTP, like the app: passwords and the registry token cross your network
unencrypted. Use it only on your own network. If `.local` names don't work, use the Pi's IP address
from your router: `http://192.168.1.23:8081/`.

### Over SSH

```sh
ssh <user>@brewberrypi.local           # your Imager user and hostname
```

If `.local` names don't work on your network, use the Pi's IP address from your router. SSH logins
use your Imager user and key; `brewberry` can log in over SSH only if you chose password
authentication in Imager.

Check what's running:

```sh
sudo brewberry-system info             # OS version, board, addresses, /data usage
sudo brewberry-update status           # app version and state
systemctl status brewberrypi           # the app service
```

Every command in this manual that changes something needs `sudo`. The admin user doesn't need a
password for it.

Commands that restart the app or reboot the Pi (`install`, `rollback`, `demo`, `restart`,
`brewberry-maint on|upgrade|off`) ask you to type `yes`, and warn first when a brew is loaded or
running, because they end it. Add `--yes` to skip the question in scripts. Without a terminal and
without `--yes`, they print what they would do and exit with code 10, changing nothing. Queries
take `--json` for machine-readable output.

To change a password: `passwd` (your own) or `sudo passwd brewberry`. The change is saved to
`/data` and survives reboots; for `brewberry`, the file share uses the new password at once.

## 5. Configuration

The app reads its configuration from `/data/config`: `config.json` plus the folder `recipes/`, with
one file `<id>.json` per recipe (for example `recipes/ZORA.json`). Without a `recipes/` folder the
app uses its built-in recipes. The app's documentation describes both formats. The OS itself reads only the output pins from it, to switch
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
Change it in the device web interface, from a USB stick, or over SSH. All three check every file
first, back up what they replace in `/data/config/backup/<date>/`, and write atomically, so a
power cut leaves the old or the new file. Or change the files directly in the
[file share](#in-the-file-share), like on a network drive: quicker, but without these checks.

Whichever way you choose, the app reads its configuration only at start: restart it afterwards
(**Restart the app**, or `sudo brewberry-update restart`; this ends a running brew).

### In the device web interface

**Configuration** shows `config.json` and the recipes. To change them, upload `config.json`, recipe
files (tick *These .json files are recipes*), or a `.tar.gz` downloaded with **Download**. Then
**Restart the app**: it reads its configuration only at start.

### In the file share

The Pi shares `/data/config` on your network as **`config`**. Log in as **`brewberry`** with the
password of the device web interface (`pi` until you change it):

| On | Open |
|---|---|
| Windows | Explorer, address bar: `\\brewberrypi.local\config` |
| macOS | Finder, *Go → Connect to Server*: `smb://brewberrypi.local/config` (the Pi also shows under *Network*) |
| Linux | the file manager: `smb://brewberrypi.local/config`, or `smbclient //brewberrypi.local/config -U brewberry` |

Use your hostname instead of `brewberrypi`, or the Pi's IP address. The **Configuration** page
and `sudo brewberry-share status` show the address and whether the share is on.

In the share you see `config.json`, `recipes/` (if there is one) and `backup/` with the files that
imports replaced. Open, copy, change and delete files as on any network drive, then restart the
app. Keep in mind:

- **Nothing is checked** when you save. If a file isn't valid, the app refuses to start (exit code
  2 or 3, [The app is down](#the-app-is-down-or-in-safe-mode)): fix the file and restart it. `sudo
  brewberry-config show` shows what the app will read. The imports above check first and keep a
  backup; for bigger changes, take a [backup](#backing-up-the-configuration) first.
- **Creating `recipes/`** replaces the app's built-in recipes with the ones in it, as an import
  does.
- **Changing an output pin** (`hardware.*.pin`) while the app runs is safe: when it stops, the OS
  switches off the pins it was started with as well as the new ones. Nothing warns you about the
  boot-time pins, as the imports do: see [Output pins](#output-pins).
- Wait a few seconds after saving before you pull the plug; a file being written at that moment
  may be lost.
- macOS keeps no `._` or `.DS_Store` files on the Pi; they don't disturb the app.

The share speaks SMB 3 only, signs every request, and encrypts when the computer offers it (all
current Windows, macOS and Linux versions do). There is no guest access. Turn it off, also across
reboots, with **Share off** on the **Configuration** page or `sudo brewberry-share off`; turn it on
again with `sudo brewberry-share on`.

### From a USB stick

This is the safest way: every file is checked first, and the old configuration is backed up.

1. On your computer, copy the files to the folder `brewberrypi/config/` on a USB stick:
   `brewberrypi/config/config.json`, and the recipes as `brewberrypi/config/recipes/<id>.json`.
   Both are optional. A `recipes/` folder on the stick replaces **all** recipes on the Pi, so it
   must hold every recipe you want to keep; without one, the recipes on the Pi stay as they are.
2. Plug the stick into the Pi and run:

   ```sh
   sudo brewberry-usb list               # shows what's on the stick
   sudo brewberry-usb import-config
   ```

   If any file isn't valid JSON, or a recipe file name isn't a recipe id (letters, digits, `_`
   and `-`), nothing is imported. The previous files and recipes are saved in
   `/data/config/backup/<date>/`.
3. The app reads its configuration only at start. Restart it (this ends a running brew):

   ```sh
   sudo brewberry-update restart
   ```

### Over SSH

Copy the file to the Pi and import it. `brewberry-config import` takes a folder (`*.json` plus an
optional `recipes/`, like the stick's `brewberrypi/config/`), one `.json` file, or a `.tar.gz`
from `brewberry-config export`:

```sh
scp config.json <user>@brewberrypi.local:                # on your computer

sudo brewberry-config import config.json                 # on the Pi
sudo brewberry-config show                               # what the app will read
sudo brewberry-update restart
```

### Backing up the configuration

Download it under **Configuration → Download**, or over SSH:

```sh
ssh <user>@brewberrypi.local sudo brewberry-config export > brewberrypi-config.tar.gz
```

The archive holds `config.json`, other top-level `.json` files and `recipes/`, without the
backups. To restore it on a reflashed Pi, upload it under **Configuration**, or copy it over and
run `sudo brewberry-config import brewberrypi-config.tar.gz`.

### Output pins

The OS switches the outputs off at two moments:

- **After every stop of the app** (exit, crash, hang, update): the pins the app was started with,
  then the pins in `config.json` now (they differ if it changed while the app ran), or the
  defaults.
- **At power-on**, before Linux starts: the firmware switches the **default** pins off (BCM 23
  and 22 driven high, BCM 10 driven low). These are set in `/boot/firmware/config.txt`.

If `config.json` moves an output to another pin, `brewberry-usb import-config` and `brewberry-config
import` warn about it (a change in the file share doesn't).
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

Pick versions in the device web interface under **App versions**, or with the commands below over
SSH. Both do exactly the same.

Until an app version is installed, the Pi runs a placeholder (the *contract stub*) that comes with
the image. `http://<hostname>.local:8080/` then shows a page saying that the app isn't installed
yet, with these steps. The placeholder never switches the outputs. Its `/healthz` reports the version `placeholder`, and
`brewberry-update status` (and the web interface) show *placeholder (no app installed)*.

### Give the Pi access to the registry (once)

1. On GitHub, open **Settings → Developer settings → Personal access tokens → Tokens (classic) →
   Generate new token (classic)**.
2. Tick only the **`read:packages`** scope. Choose an expiry date and note it down.
3. In the device web interface: **App versions → Registry access**, your GitHub user name and the
   token. Or over SSH:

   ```sh
   sudo brewberry-update login
   ```

   Enter your GitHub user name, and the token as the password.

The token is stored in `/data/secrets/auth.json`, readable by root only. The app container never
sees it. When the token expires, create a new one and run `login` again.

### List, install, roll back

```sh
sudo brewberry-update list             # available versions, newest first
sudo brewberry-update install 1.2.3    # install and switch to 1.2.3
sudo brewberry-update status           # active and previous version, result of the last action
sudo brewberry-update rollback         # switch back to the previous version
sudo brewberry-update restart          # restart the app, for example after a config change
```

In the device web interface: **App versions → Check the registry**, then **Install** next to a
version; **Roll back** and **Restart the app** are on the same page.

Versions are releases like `1.2.3` or pre-releases like `1.2.3-alpha.1` (also `-beta.N`, `-rc.N`).
A pre-release has not been tested on hardware yet. It is listed before its release: `1.2.3-alpha.2`,
`1.2.3-beta.1` and `1.2.3-rc.1` are all older than `1.2.3`.

Installing, rolling back and restarting restart the app, which **ends a running brew**. They ask
first, and say so when a brew is loaded or running. What `install` does:

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

### Demo mode

Demo mode runs the app with a **simulated kettle**: the app's `--dummymode`. The web UI works as
usual, and a recipe heats a simulated kettle, which `simulation.timeScale` in `config.json` speeds
up. The app doesn't touch GPIO in demo mode, so the heater, pump and buzzer stay off. Use it to
try the app before the hardware is wired.

```sh
sudo brewberry-update demo on          # restart the app in demo mode
sudo brewberry-update demo off         # back to the real hardware
sudo brewberry-update status           # last line: demo mode: on|off
```

In the device web interface: **App versions → Demo mode on / off**.

Both restart the app, which ends a running brew. The setting is kept in `/data` across reboots and
app updates, until you switch it off. While the placeholder runs (no app installed yet), its page
shows the setting.

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
cp -r recipes /media/stick/brewberrypi/config/           # optional: recipes, one <id>.json each
```

The script checks the export against the Pi's signature rules, so a stick the Pi would refuse is
noticed now. The stick then looks like this:

```
brewberrypi/
├── images/
│   └── 1.2.3/            one folder per version
└── config/
    ├── config.json       optional
    └── recipes/          optional, replaces all recipes on the Pi
        └── ZORA.json     one file per recipe
```

### Use it on the Pi

Plug the stick in, then in the device web interface open **USB stick → Look at the stick**: it lists
the versions with an **Install** button each, and **Import the stick's configuration**. Or over SSH:

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

In the device web interface, **OS update** has the three steps as buttons: **Maintenance mode on**
(reboots; the page reconnects), **Update the OS packages**, **Maintenance mode off** (reboots).
Over SSH:

```sh
sudo brewberry-maint on                # asks to confirm, then reboots
# log in again
sudo brewberry-maint status            # "NOT sealed ... maintenance mode since ..."
sudo brewberry-maint upgrade           # apt update + apt full-upgrade, keeps changed config files
sudo brewberry-maint off               # asks to confirm, then reboots
# log in again
sudo brewberry-maint status            # "sealed"
```

`apt update` and `apt full-upgrade` by hand work as well while in maintenance mode.

The app keeps running in maintenance mode, with all its safety measures. If `off` refuses
because an update removed the BrewberryPi block from `/boot/firmware/config.txt`, see
[docs/os-update.md](os-update.md#steps). That page also covers power cuts during an update.

Alternatively, flash a newer BrewberryPi OS release. That erases `/data`, so back up the
configuration first, and run `brewberry-update login` again afterwards.

## 9. Troubleshooting

Logs are kept in memory and **lost at reboot**, so read them before you restart the Pi: in the
device web interface under **Logs**, or over SSH:

```sh
sudo brewberry-system logs app                  # the app
sudo brewberry-system logs safemode             # safe mode
sudo brewberry-system logs firstload            # loading the app on first boot
sudo brewberry-system logs web                  # the device web interface and its actions
sudo brewberry-system logs share                # the file share
sudo brewberry-update status
```

`journalctl -u brewberrypi -b` and the like show the same.

### The first boot report

Before the Pi seals itself at the end of the first boot, it writes
`brewberry-firstboot.txt` to the boot partition: failed services, the cloud-init (Imager
customisation) status and log, the network state, the SSH settings (password logins on or off,
authorized keys per user), and the logs of the first-boot services. Put
the SD card in any computer and open the file on the small FAT partition (`bootfs`). Look at it
first when the hostname, user, password or Wi-Fi from Imager weren't applied, or nothing answers
on the network.

### I can't find the Pi on the network

- Wait a few minutes after the first power-on: the Pi reboots once by itself.
- Use the IP address from your router instead of `<hostname>.local`.
- Wi-Fi settings are only applied on the first boot. If they were wrong, reflash.
- Check [the first boot report](#the-first-boot-report): if cloud-init found no Imager settings,
  the card was flashed with *Use custom* instead of the manifest, or customisation was skipped.
- `Permission denied (publickey)`: Imager's SSH setting was *public-key authentication only* (or
  SSH had no setting) and the key you use isn't the one you gave Imager. The first boot report's
  `== ssh` section shows whether passwords are on and how many keys each user has. To switch to
  password logins, reflash with *Use password authentication*.

### The app is down or in safe mode

1. Look at `sudo brewberry-update status` and `sudo brewberry-system logs app` (or the
   **Overview** and **Logs** pages).
2. If the app exited with code 2 or 3, it refused its configuration. Fix `/data/config`
   ([Configuration](#5-configuration)), then restart it (**App versions → Restart the app**):

   ```sh
   sudo brewberry-update restart
   ```

3. Otherwise the version itself is broken. Install a working version, or roll back:

   ```sh
   sudo brewberry-update install 1.2.2
   ```

`brewberry-update restart` also resets systemd's start counter: manual restarts count towards the
limit of 4 starts in 10 minutes too.

### I can't log in to the device web interface

- The user is always `brewberry`; the default password is `pi`, unless you changed it.
- Forgot the password: log in over SSH with your Imager user and run `sudo passwd brewberry`.
- *Too many attempts*: after 5 wrong passwords each further try waits longer, up to a minute.
- Nothing answers on port 8081: `sudo brewberry-system logs web`, and
  `systemctl status brewberry-web`. Use the Pi's name or IP address in the address bar; the page
  refuses other host names.
- You are logged out after 30 minutes without activity, and when the Pi or the web interface
  restarts.

### The file share doesn't open, or refuses the password

- The user is `brewberry` and the password is the one of the device web interface. `sudo
  brewberry-share status` says whether the share is on and has a password.
- *Password: none yet*: the password of `brewberry` was set without the share, for example by
  Imager when your Imager user is called `brewberry`. Set it again under **Account** (the same
  password is fine) or with `sudo passwd brewberry`; the share then takes it.
- Windows asks again and again: Windows offers its own account first. Enter `brewberry` as the
  user name; if Windows keeps a wrong saved password, remove it under *Credential Manager*.
- The address isn't found: use the Pi's IP address (`\\192.168.1.23\config`). A firewall or VPN
  on your computer can block SMB (port 445).
- Very old systems (Windows 7, SMB 1 or 2 only) can't connect: the share speaks SMB 3 only.
- More: `sudo brewberry-system logs share`.

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
sudo brewberry-system logs outputs-off
```

## 10. Command reference

All commands run as root (`sudo`). The device web interface offers each of them
(`tests/unit/parity.sh` keeps this table, the commands and the web interface in step). Queries take
`--json`; commands that restart the app or reboot ask first and take `--yes`.

| Command | What it does |
|---|---|
| `brewberry-update login` | Store the registry token (`--username <user> --password-stdin` without a prompt) |
| `brewberry-update list` | Available app versions (releases and pre-releases), newest first |
| `brewberry-update install <version>` | Install and switch to a version; rolls back if it fails |
| `brewberry-update rollback` | Switch back to the previous version |
| `brewberry-update status` | Active and previous version, last result, safe mode, demo mode |
| `brewberry-update demo on\|off` | Run the app with a simulated kettle (no GPIO), or normally |
| `brewberry-update restart` | Restart the app (ends a running brew), also after a configuration error |
| `brewberry-usb list` | Versions and config files on a USB stick |
| `brewberry-usb install <version>` | Install a version from a USB stick |
| `brewberry-usb import-config` | Copy `brewberrypi/config/*.json` and `recipes/` from a stick to `/data/config` |
| `brewberry-config show` | The configuration the app reads, and its recipes |
| `brewberry-config import <source>` | Check, back up and replace config files from a folder, a `.json` file or an export |
| `brewberry-config export` | `/data/config` as `.tar.gz` on stdout (a backup) |
| `brewberry-share status` | Whether the file share of `/data/config` is on, its address, whether it has a password |
| `brewberry-share on` | Share `/data/config` on the network (the default) |
| `brewberry-share off` | Stop sharing it, also after reboots |
| `brewberry-maint status` | Sealed (normal) or in maintenance mode |
| `brewberry-maint on` | Make the system writable for OS updates (reboots) |
| `brewberry-maint upgrade` | In maintenance mode: `apt update` and `apt full-upgrade` |
| `brewberry-maint off` | Seal the system again (reboots) |
| `brewberry-system info` | OS version, board, hostname, addresses, uptime, `/data` usage |
| `brewberry-system logs <name>` | This boot's log: `app`, `safemode`, `firstload`, `outputs-off`, `web` or `share` |
| `passwd` | Change a password (`sudo passwd brewberry` for the web interface's and the file share's user); kept across reboots |
