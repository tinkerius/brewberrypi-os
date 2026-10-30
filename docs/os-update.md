# OS update procedure (maintenance mode)

BrewberryPi OS runs **sealed**: the root is a read-only overlay with a RAM upper layer, and the
boot partition is read-only. Changes outside `/data` vanish at the next reboot, and apt refuses to
change packages. OS updates (Raspberry Pi OS / Debian packages, kernel, firmware) therefore go
through **maintenance mode** (ADR-0001, OS6). App versions are not OS updates; they use
`brewberry-update`.

> **Pulling the plug is not safe** from `brewberry-maint on` until `brewberry-maint off` has
> rebooted: root and boot are writable during that window. Keep the power connected.

## Steps

1. Pick a time with no brew running: the Pi reboots twice.
2. Switch to maintenance mode (reboots):

   ```sh
   sudo brewberry-maint on
   ```

3. After the reboot, check and update:

   ```sh
   sudo brewberry-maint status        # "NOT sealed ... maintenance mode since ..."
   sudo brewberry-maint upgrade       # apt update + apt full-upgrade (keeps changed config files)
   ```

   `apt update` and `apt full-upgrade` by hand work as well. The device web interface
   (`http://<hostname>.local:8081/`, **OS update**) has the same three steps as buttons.

   The app keeps running in maintenance mode with all its safety measures. Kernel and firmware
   updates write to the boot partition, which is writable now. The initramfs is rebuilt with
   overlayroot because the package stays installed.
4. Seal again (reboots):

   ```sh
   sudo brewberry-maint off
   ```

   `off` refuses if an upgrade dropped the BrewberryPi safety block from
   `/boot/firmware/config.txt` (`strict_gpiod`, `gpio=` boot pins). Restore it from
   `layer/brewberry-safety.yaml`, then run `off` again. Sealing also refuses if the initramfs lost
   overlayroot.
5. After the reboot, `sudo brewberry-maint status` says `sealed`.

## Other changes in maintenance mode

The same window is used for changes to the real root or the boot partition. One example is the
`gpio=` boot-pin lines in `config.txt` after `config.json` moved an output to another pin
(`brewberry-config import` warns about that).

## If something goes wrong

- **Power cut during `on`:** if the Pi comes back sealed, it simply did not get far enough; run
  `on` again. If it comes back unsealed without the maintenance flag, it seals itself and reboots.
- **Power cut during `off`:** the next boot finishes sealing by itself (`brewberry-seal.service`).
- **Power cut during `apt`:** the root filesystem may need repair (fsck runs at boot). If the Pi
  does not boot, reflash it. Reflashing overwrites the whole card, **`/data` included** (config,
  app images). Keep a copy of your config (`brewberry-config export`) to
  import afterwards; the newest app installs itself again.
