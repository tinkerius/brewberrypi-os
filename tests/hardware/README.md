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
