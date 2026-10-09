# BrewberryPi OS

Operating-system image for [BrewberryPi](https://github.com/tinkerius/brewberrypi), a Raspberry Pi
controller for a home-brewing mash kettle. It is built to behave like a games console:

- **Flash it, plug it in, brew.** It's a ready-made image for Raspberry Pi 3, 4 and 5, flashed with Raspberry Pi Imager.
- **Unplugging is safe.** The system partitions are read-only; only a small data partition is written, and only during config changes and updates. The relays end up off on every stop.
- **The app runs as a signed container.** Podman + Quadlet run the BrewberryPi image from a private registry.
- **Pick a version.** Available versions are listed on the device; the chosen one is installed with automatic rollback, and there is a safe mode if it won't start.

## Status

| Phase | Content | Status |
|---|---|---|
| Design | [ADR-0001](docs/adr/0001-os-image-and-app-runtime.md), research in [docs/research](docs/research/) | ✅ done (2026-10-09) |
| Implementation | Milestones OS0–OS8 in [docs/implementation-plan.md](docs/implementation-plan.md) | ⏳ next |

## Documentation

| Document | Purpose |
|---|---|
| [docs/adr/](docs/adr/) | Architecture decision records |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Milestones OS0–OS8 |
| [docs/research/](docs/research/) | Research behind the decisions (primary sources, fact-checked) |
| Runtime contract (application repository: `docs/deployment/runtime-contract.md`) | What the app image expects from this OS |

## Development

Build commands are added in milestone OS0.
