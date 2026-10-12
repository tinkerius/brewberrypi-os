# Hardware checks

These checks run on a real Raspberry Pi. They are the "done when" checks of the milestones in
[docs/implementation-plan.md](../../docs/implementation-plan.md).

## OS1: partitions and read-only root

1. Flash the CI image (Imager → *Use custom*) and boot it on a Pi 3 or 4 with Ethernet.
2. **First boot** takes a little longer, then the Pi **reboots once by itself**. During that boot:
   - `brewberry-growdata` grows the DATA partition to the end of the card;
   - `brewberry-datalayout` creates the `/data` directories;
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
   `{"status": "ok", "version": "0.1.0", "engine": "NoProcess"}`.

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
3. `kill9`, `hang` and `rm`: each switches the heater on, then kills the app with `kill -9`, stops
   its watchdog pings, or removes the container. Each must end with `PASS  ...: heater off again`.
   Write down the times; `hang` takes up to `WatchdogSec` (20 s).
4. Power cut while heating: run `heat`, pull the plug, plug it back in. Watch the heater LED from
   power-on: it must be off once the firmware applies `gpio=` and stay off. Run `status` again.
5. **Power-on window (app `Q-18`)**: from plugging in until the firmware applies `gpio=`, the pins
   are pulled low, which is "on" for an active-low relay. Measure how long the heater LED or relay
   is on after power-on (a phone slow-motion video is enough). Record the result in the app's
   hardware test protocol. Check whether the relay board actually switches.
6. `disable` when done.
