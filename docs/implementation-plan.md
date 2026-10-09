# Implementation Plan

Milestones for BrewberryPi OS. Each milestone ends with its "done when" checks green. Hardware checks
need a real Pi 3 or 4 first; Pi 5 follows in OS7. The application side of the runtime contract is
implemented in `tinkerius/brewberrypi`. Until its first release, OS2–OS5 use a small **contract stub
image** from `stub/`. The stub implements READY, WATCHDOG and `/healthz`, and can crash, hang or
refuse to start on request.

| # | Milestone | Done when | Status |
|---|---|---|---|
| OS0 | **Skeleton and first image:** rpi-image-gen config, GitHub Actions build on `ubuntu-24.04-arm`, Pi 3/4 image with SSH | The CI artifact flashes with Imager and boots; SSH login works | ☐ |
| OS1 | **Partitions and read-only root:** MBR p1/p2/p3, `data.mount`, first-boot grow, layout and seal services, `overlayroot=tmpfs:recurse=0`, boot read-only, volatile journal with a cap | `findmnt` shows the overlay root, read-only boot and read-write `/data`; pulling the plug 20× at runtime leaves root and boot untouched (checksums) and `/data` mountable | ☐ |
| OS2 | **Podman and app unit:** storage and tmp on `/data`, Quadlet unit, the preloaded image tagged `active`, GPIO devices, the gpio group, config mount, contract stub image | The stub runs as `brewberrypi.service` and is reachable on port 8080; `systemctl restart` waits for READY | ☐ |
| OS3 | **Safety:** outputs-off script (pins from the config), `strict_gpiod`, `gpio=` boot pins, `w1-gpio`, SPI off, `WatchdogSec`, `RuntimeWatchdogSec` | On hardware (relay board or LEDs): `kill -9`, a stub hang, a container removal and a power cut while "heating" all end with the relays off; the power-on window is measured (app `Q-18`) | ☐ |
| OS4 | **Signed updates and version selection:** `policy.json` with pinned keys, `registries.d`, auth file, `tags.json`, path unit, updater with re-tag, soak and rollback, safe mode with `RestartMode=direct` | An unsigned or wrongly signed image is rejected; a stub version that crashes on start is rolled back; 4 crashes trigger safe mode exactly once; `previous` survives garbage collection | ☐ |
| OS5 | **USB:** offline update in `dir:` format, config import from a stick | A signed `dir:` export installs offline; a tampered export is rejected | ☐ |
| OS6 | **Maintenance mode:** `brewberry-maint on\|off`, documented OS update procedure | `apt full-upgrade` works in maintenance mode; overlay and read-only boot are restored afterwards | ☐ |
| OS7 | **Pi 5 and releases:** Pi 5 image (or a combined image), Imager manifest with `init_format`, release workflow (`.img.xz`, manifest, checksums) | Pi 5 boots and passes the OS1–OS4 checks; Imager customisation (hostname, Wi-Fi, SSH) works with the manifest | ☐ |
| OS8 | **End-to-end with the real app:** app release ≥ 1.0 through the update flow, water-only brew | App M12 hardware test passes on BrewberryPi OS | ☐ |

## Working rules

- Safety first: on every path that is not actively controlling temperature, the relays must end up off. Never weaken the outputs-off reset, the watchdog or the signature policy, not even for tests.
- Every change that affects the runtime contract needs a new contract version agreed with the application repository.
- Commit messages reference the milestone and, where relevant, the application requirement IDs (`NFR-003`, `Q-16`).
