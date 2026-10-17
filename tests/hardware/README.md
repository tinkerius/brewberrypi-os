# Hardware checks

These checks run on a real Raspberry Pi. They are the "done when" checks of the milestones in
[docs/implementation-plan.md](../../docs/implementation-plan.md).

## OS1: partitions and read-only root

1. Flash the CI image (Imager → *Use custom*) and boot it on a Pi 3 or 4 with Ethernet.
2. **First boot** takes a little longer, then the Pi **reboots once by itself**. During that boot:
   - `brewberry-growdata` grows the DATA partition to the end of the card;
   - `brewberry-datalayout` creates the `/data` directories and seeds `/data/config/config.json`
     with `{}` (the app's built-in defaults);
   - SSH host keys and the machine-id are created;
   - `brewberry-seal` sets `/boot/firmware` read-only in `/etc/fstab`, adds
     `overlayroot=tmpfs:recurse=0` to `cmdline.txt`, and reboots.

   Don't pull the plug during this first boot; it is not covered (ADR-0001).
3. After the reboot, check the mount layout:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- status' < tests/hardware/os1-check.sh
   ```

   Every line must say `PASS`.
4. Record the checksum baseline of the boot and root partitions (it takes a minute or two):

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- checksum' < tests/hardware/os1-check.sh
   ```

5. Pull the plug **20 times** while the system is running. Vary the timing: during boot, right
   after SSH comes up, and idle for a while. After each power cut, let it boot and run both
   `status` and `checksum`. Each `checksum` run must report `PASS  boot and root match the
   baseline`, and `status` must show `/data` mounted.

OS1 is done when all 20 cycles pass. `/data/os1-checksums.log` keeps the history; delete it
afterwards.

## OS2: Podman and the app unit

The image preloads the **contract stub** (`stub/`), not the real app. It never touches GPIO.
Until OS3 adds the outputs-off reset, don't connect a relay board to a mains heater.

1. Flash and boot as for OS1 (first boot also imports the stub as `localhost/brewberrypi:active`).
2. Run the checks; every line must say `PASS`:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s' < tests/hardware/os2-check.sh
   ```

3. From another machine: `curl http://brewberrypi.local:8080/healthz` answers
   `{"status": "ok", "version": "placeholder", "engine": "NoProcess"}`, and
   `http://brewberrypi.local:8080/` in a browser shows the stub's page ("The brewing app isn't
   installed yet").

## OS3: safety

Use **LEDs or the relay board without the heater** on the default pins: heater BCM 23 and pump
BCM 22 active-low (LED from 3V3 through a resistor to the pin: lit = on), buzzer BCM 10
active-high. Run every mode with:

```sh
ssh brewberry@brewberrypi.local 'sudo sh -s -- <mode>' < tests/hardware/os3-check.sh
```

1. `status`: strict_gpiod, SPI off, 1-Wire, both watchdogs, the outputs-off hook and all outputs
   off. Every line must say `PASS`.
2. `enable`: lets the stub switch the heater on (`/data/config/stub.json`, `"allowHeat": true`).
   The stub refuses this by default because it listens on the network without authentication.
3. `kill9`, `hang`, `pause` and `rm`: each switches the heater on, then kills the app with
   `kill -9`, stops its watchdog pings, freezes the whole container (`podman pause`, as in the
   app's hardware test H-10) or removes the container. Each must end with
   `PASS  ...: heater off again`. Write down the times; `hang` and `pause` take up to
   `WatchdogSec` (20 s).
4. Power cut while heating: run `heat`, pull the plug, plug it back in. Watch the heater LED from
   power-on: it must be off once the firmware applies `gpio=` and stay off. Run `status` again.
5. **Power-on window (app `Q-18`)**: from plugging in until the firmware applies `gpio=`, the pins
   are pulled low, which is "on" for an active-low relay. Measure how long the heater LED or relay
   is on after power-on (a phone slow-motion video is enough). Record the result in the app's
   hardware test protocol. Check whether the relay board actually switches.
6. `disable` when done.

## OS4: signed updates, rollback and safe mode

The real app's images are signed in its own CI. For this test, `scripts/publish-test-stubs.sh`
pushes stub versions to a **test repository** (never `ghcr.io/tinkerius/brewberrypi`), signed
with a throwaway key: 0.2.0 healthy, 0.3.0 crashes on start, 0.4.0 unsigned, 0.5.0 signed with
another key.

1. On your machine (podman logged in to the registry, cosign v2.x):

   ```sh
   scripts/publish-test-stubs.sh ghcr.io/tinkerius/brewberrypi-os-test
   scp work/test-signing/test.pub brewberry@brewberrypi.local:/tmp/
   ```

2. On the device, a registry token for that repository (a classic PAT with `read:packages`):

   ```sh
   ssh -t brewberry@brewberrypi.local 'sudo BREWBERRY_UPDATE_REPO=ghcr.io/tinkerius/brewberrypi-os-test brewberry-update login'
   ```

3. Install the test key and policy entry. They live in the RAM overlay only, so a reboot removes
   them:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- setup ghcr.io/tinkerius/brewberrypi-os-test /tmp/test.pub' < tests/hardware/os4-check.sh
   ```

4. Run the checks (about five minutes). Every line must say `PASS`:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os4-check.sh
   ```

   This covers the OS4 "done when" list: wrongly signed and unsigned images rejected, a version
   that crashes on start rolled back, `previous` kept through garbage collection, and repeated
   crashes switching to `previous` exactly once, then staying down with the outputs off.
5. Reboot to remove the test key.
6. Demo mode, with any app or the stub active:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo brewberry-update demo on && sudo podman inspect brewberrypi --format "{{.Args}}"'
   ```

   The arguments end in `--dummymode`, and the stub's page shows "Demo mode: on". After a
   reboot it is still on; `sudo brewberry-update demo off` removes `--dummymode` again.

## OS5: USB offline update and config import

Uses the test repository, key and versions from OS4. The stick needs any filesystem the Pi can
read (FAT32, exFAT or ext4).

1. On your machine, with the stick mounted (here at `/media/stick`):

   ```sh
   scripts/usb-export.sh 0.2.0 /media/stick --repo ghcr.io/tinkerius/brewberrypi-os-test --key work/test-signing/test.pub
   tests/hardware/os5-tamper.sh /media/stick          # adds a tampered copy as 9.9.9
   mkdir -p /media/stick/brewberrypi/config
   cp <your config.json> /media/stick/brewberrypi/config/
   ```

   `usb-export.sh` verifies the export against the device policy before it finishes.
2. Unmount the stick and plug it into the Pi.
3. Install the USB test rule (RAM only, a reboot removes it) and run the checks; every line must
   say `PASS`:

   ```sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- setup ghcr.io/tinkerius/brewberrypi-os-test /tmp/test.pub' < tests/hardware/os5-check.sh
   ssh brewberry@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os5-check.sh
   ```

   This covers the OS5 "done when": the signed export installs offline, the tampered one is
   rejected. It also checks the config import and that the stick is unmounted afterwards.
4. Reboot to remove the test rule.

## OS6: maintenance mode

Follows the procedure in [docs/os-update.md](../../docs/os-update.md), mode by mode. `on` and
`off` reboot, so reconnect after each:

```sh
run() { ssh brewberry@brewberrypi.local "sudo sh -s -- $1" < tests/hardware/os6-check.sh; }
run sealed     # all PASS
run on         # reboots into maintenance mode
run maint      # all PASS
run upgrade    # apt full-upgrade must succeed
run off        # seals and reboots
run sealed     # all PASS: overlay and read-only boot are back
```

This covers the OS6 "done when". Afterwards, re-run the OS1 checks (`os1-check.sh status`).

## OS8: end-to-end with the real app

Needs an app release (≥ 1.0 for the milestone) from `tinkerius/brewberrypi`, and the app's
[hardware test protocol](https://github.com/tinkerius/brewberrypi/blob/main/docs/deployment/hardware-test-protocol.md).

1. **Through the update flow** (the OS8 "done when"): flash the current image (stub or an older app
   preloaded), then on the device:

   ```sh
   sudo brewberry-update login             # classic PAT with read:packages
   sudo brewberry-update install <version> # must end with the new version active
   sudo brewberry-update status
   ```

2. **As the preload** (for the release image): set the repository variable
   `BREWBERRY_APP_VERSION=<version>` and give CI read access to the app's package (the secret
   `BREWBERRY_GHCR_TOKEN`, or this repository under the package's *Manage Actions access*). The
   image build fetches the arm64 image with `scripts/fetch-app.sh` and refuses it unless it is
   signed with the pinned key and its labels say contract 1 and that version.
   `/etc/brewberry-release` shows `BREWBERRY_OS_APP_PRELOAD`.
3. Re-run the OS3 scenarios with the real app instead of the stub. `os3-check.sh` drives the stub's
   heater endpoint, so here use the app's protocol (H-08 stop, H-09 `kill`, H-10 `pause`); the
   relays must be off at the end of each.
4. Run the app's protocol to the end (water-only brew, M12) and sign it off.

## OS7: Raspberry Pi 5 and Imager customisation

### Imager customisation

On both a Pi 3/4 and a Pi 5, following [docs/flashing.md](../../docs/flashing.md):

1. Write a local manifest for the CI images (`scripts/imager-manifest.py --local ...`) and open it
   in Raspberry Pi Imager 2.x.
2. Check that Imager offers customisation but no interface options (SPI, I2C, 1-Wire, serial).
3. Customise a **non-default hostname**, a user of your own (not `brewberry`) with a password,
   your SSH public key, Wi-Fi (SSID, password, country), the time zone and the keyboard. Flash,
   then boot **without Ethernet**. Also log in at the console with the password. Flash once with
   SSH set to **public-key authentication only** and once to **password authentication**; the check
   reads which one Imager wrote.
4. After the self-reboot, log in over Wi-Fi and run the checks; every line must say `PASS`:

   ```sh
   ssh <user>@<hostname>.local 'sudo sh -s -- <hostname> <user> "<ssid>"' < tests/hardware/os7-check.sh
   ```

5. Reboot once more and run the checks again (cloud-init must stay off, Wi-Fi must come back).
6. Flash once without customisation and boot with Ethernet: `ssh brewberry@brewberrypi.local`
   works with the key built in from `BREWBERRY_SSH_PUBKEY`.

### Raspberry Pi 5

Flash `brewberrypi-os-pi5-*.img.xz` on a Pi 5 and run the OS1–OS4 checks above unchanged. Watch
these Pi 5 differences:

- the header GPIO chip is `pinctrl-rp1`, and its number varies by kernel (the app and the stub
  find it by label; `os2-check.sh` lists what the container sees);
- `strict_gpiod` sets `pinctrl_rp1.persist_gpio_outputs=n`;
- the firmware's `gpio=` boot pins must work on RP1: in `os3-check.sh status`, all outputs must be
  off before the app ever drives them, and the power-on window (Q-18) must be measured again;
- ext4 uses 16K blocks to match the 16K-page kernel.

## OS9: device web interface

On any board, after OS2 (the stub runs). Over SSH with your Imager user:

```sh
ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os9-check.sh
ssh <user>@brewberrypi.local 'sudo sh -s -- password pi brewing-2026' < tests/hardware/os9-check.sh
ssh <user>@brewberrypi.local 'sudo reboot'
ssh <user>@brewberrypi.local 'sudo sh -s -- after-reboot brewing-2026' < tests/hardware/os9-check.sh
```

`run` checks the services, that the API needs a login and refuses cross-site requests, that the
web interface reports the same app version and the same confirmation text as the CLI, and that a
job (an app restart) finishes even when `brewberry-web` restarts in the middle. `password` and
`after-reboot` check that a password changed in the browser is saved to `/data` and survives the
reboot.

By hand, in a browser on another machine (`http://brewberrypi.local:8081/`):

1. The login page shows the user `brewberry`; `pi` logs in and the default-password reminder
   shows until the password is changed.
2. Every page loads; every button of the user manual's command reference works: **Check the
   registry** and **Install** (with a registry token), **Roll back**, **Demo mode on/off**,
   **Restart the app**, the USB stick page with a prepared stick (OS5), **Download** and **Import**
   of the configuration, **Logs**, and the three **OS update** steps (OS6; the page reconnects after
   each reboot).
3. `sudo passwd brewberry` over SSH, then a reboot: the new password logs in to the web interface.

The brew warning ("A brew is loaded or running…") needs the real app with a loaded recipe (OS8);
the unit tests cover it with a fake `/healthz`.

## OS10: file share

On any board, after OS9 (the web interface and the account). Over SSH with your Imager user:

```sh
ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os10-check.sh
ssh <user>@brewberrypi.local 'sudo sh -s -- onoff' < tests/hardware/os10-check.sh
ssh <user>@brewberrypi.local 'sudo reboot'
ssh <user>@brewberrypi.local 'sudo sh -s -- after-reboot' < tests/hardware/os10-check.sh
```

`run` checks that only smbd runs (port 445, no NetBIOS), the share's settings (SMB 3, signing, no
guests, one share), that its password belongs to the `brewberry` account, the PAM hook, the file
owners in `/data/config`, and the outputs recorded when the app started. `onoff` and
`after-reboot` check that `brewberry-share off` stops the share and keeps it off across a reboot.

By hand, from another machine on the LAN:

1. **Windows:** Explorer, `\\brewberrypi.local\config`, user `brewberry`, password `pi` on a fresh
   image. **macOS:** Finder, Go, Connect to Server, `smb://brewberrypi.local/config`; the Pi also
   shows under Network. **Linux:** `smbclient //brewberrypi.local/config -U brewberry -c ls`.
2. Copy a recipe into `recipes/`, edit `config.json` (change `server.port`, say), delete a recipe:
   `sudo brewberry-config show` shows each change; `brewberry-update restart` makes the app use it.
   From macOS, check that no `._*` or `.DS_Store` files appear on the Pi.
3. Change the password in the web interface (Account): the old one no longer opens the share, the
   new one does, also after a reboot. The same with `sudo passwd brewberry` over SSH.
4. A wrong password, a guest login and an SMB 1 or 2 client (`smbclient -m SMB2`) are refused.
5. **Safety, with the relay board or LEDs (OS3):** start a "heating" stub, change
   `hardware.heating.pin` in `config.json` through the share, then `sudo systemctl kill -s KILL
   brewberrypi`. The heater relay goes off, and `brewberry-system logs outputs-off` shows the
   running app's pins first, then the new config's.
