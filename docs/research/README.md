# Research (2026-10-08/09)

The research behind [ADR-0001](../adr/0001-os-image-and-app-runtime.md) and the application's
ADR-0001. It was done by AI research agents against primary sources: kernel, systemd, Podman and
containers/image source code, official docs, package archives and issue trackers. The claims were
then checked by separate fact-checking agents. **Nothing was tested on hardware.** The hardware
checks are part of milestones OS1–OS4 and OS7.

| File (`raw/`) | Content | Checked by |
|---|---|---|
| `runtime.research.json` | Docker/Podman on Raspberry Pi OS, 32-bit status, footprint, wheels, logging, OS releases | `runtime.verify.docker.json`, `runtime.verify.podman.json`, `runtime.verify.images.json` (critical claims) |
| `hardware.research.json` | GPIO and 1-Wire access from containers, gpiochip numbering, `persist_gpio_outputs`, `strict_gpiod` | `hardware.verify.gpio.json`, `hardware.verify.persistence.json` (critical claims) |
| `gaps.research.json` | systemd `ExecStopPost`/watchdog/start-limit semantics, self-update precedents, update security | self-checked only |
| `os.research.json` | rpi-image-gen, overlayroot on Trixie, first boot, partitions, mount options, tryboot | self-checked only |
| `podman-update.research.json` | Podman storage, signatures, tag listing, Quadlet details, re-tagging, offline updates | self-checked only |

Each research file holds claims with `id`, `claim`, `evidence` (URLs and quotes), `confidence` and
`decision_critical`. Each verify file holds a verdict per claim id: `confirmed`, `corrected`
(with `corrected_claim`), `refuted` or `unverifiable`, plus facts the researcher missed.

## Key findings

1. **GPIO outputs keep their level after the owning process dies** (`persist_gpio_outputs`, default true on Pi 3/4/5), so the host must reset the relays after every stop.
2. **The Pi 5 header GPIO chip number varies by kernel** (`gpiochip4`, `gpiochip0`, `gpiochip15`). Never hard-code it.
3. **Docker restart policies have no post-stop hook and ignore health status.** Podman + Quadlet is systemd-native.
4. **raspi-config's overlay also covers `/data`.** Use `overlayroot=tmpfs:recurse=0` plus `data.mount`.
5. **Podman 5.4 needs its storage off the overlay root**, needs pull staging off `/var/tmp`, and reads only legacy cosign signatures (sign with cosign v2.x).
6. **rpi-image-gen is arm64 only.** It supports custom MBR layouts and builds on `ubuntu-24.04-arm` runners.
