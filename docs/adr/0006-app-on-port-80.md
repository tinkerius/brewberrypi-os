# ADR-0006: The app on port 80

- **Status:** Accepted (implemented in OS13, not yet tested on hardware)
- **Date:** 2026-10-23
- **Deciders:** Benedikt Hauptmann (product owner); proposal by Claude Code
- **Changes:** [ADR-0004](0004-wifi-setup-hotspot.md): port 80 redirected to the device web interface
  everywhere; now only on the setup hotspot

## Context

The product owner wants the brewing UI at `http://<hostname>.local/`, without a port (2026-10-23). The app
listens on `server.port` (default 8080). It runs as an unprivileged user with every capability dropped, and
port 80 is taken by `brewberry-portal`, which redirects to the device web interface on port 8081 (on the
setup hotspot, as the captive portal).

## Options considered

1. **The app listens on port 80 itself** — needs `CAP_NET_BIND_SERVICE` in the container or
   `net.ipv4.ip_unprivileged_port_start` lowered for the whole Pi, moves the portal off port 80, and changes
   the runtime contract (version 3, new releases of both sides). Rejected.
2. **A redirect from port 80 to `:8080`** (`brewberry-portal`) — the address bar still shows the port.
   Rejected.
3. **The kernel forwards port 80 to the app's port** (nftables `redirect`) — the app and the runtime contract
   stay as they are, the address has no port, and `:8080` keeps working.

## Decision

We choose **option 3**.

- `brewberrypi-port80` (layer `brewberry-podman`) runs as `ExecStartPre=-+` of `brewberrypi.service` and
  loads the table `inet brewberry-app`: in `prerouting` (`dstnat`), connections to the Pi's own addresses
  (`fib daddr type local`) on TCP port 80 are redirected to `server.port` of the app's `config.json`
  (8080 while there is none). It never fails the app's start; when the app itself uses port 80, the table is
  removed.
- Connections to the setup hotspot's address `10.42.0.1` are left alone: there port 80 stays the captive
  portal (ADR-0004), and the hotspot has no IPv6. The open hotspot's firewall rule (ADR-0004) is unchanged.
- Traffic the Pi forwards for others (the hotspot's clients) is never redirected.
- `nftables.service` stays disabled; nothing else on the Pi loads a ruleset that could flush the table.
- The device web interface is only at `:8081` now; the app links to it in its top bar (app `UI-002`,
  `Q-30`), and the device web interface's *App* link goes to port 80.

## Consequences

- Positive: `http://brewberrypi.local/` opens the brewing UI; bookmarks with `:8080` keep working; no app or
  contract change.
- Negative / risks: `http://brewberrypi.local/` no longer opens the device web interface. Locally on the Pi
  (`curl http://localhost/`) port 80 is still the portal's redirect: output traffic does not pass
  `prerouting`.
- Follow-ups: hardware check OS13 (`tests/hardware/os13-check.sh`).
