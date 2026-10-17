# ADR-0004: Wi-Fi setup through a fallback hotspot

- **Status:** Proposed (milestone OS11, not yet implemented)
- **Date:** 2026-10-17
- **Deciders:** Benedikt Hauptmann (product owner); proposal by Claude Code

## Context

The product owner wants flashing to need no information at all: the card is written with Raspberry
Pi Imager without customisation, and the Wi-Fi is set up on the device afterwards (2026-10-17).

Product-owner decisions (2026-10-17):

- Without a working Wi-Fi connection the Pi opens its own hotspot `brewberrypi`, without a
  password. The device web interface and the file share are reachable over it.
- In the device web interface the user enters the SSID and password of another network; the Pi
  tries it and falls back to the hotspot if it can't connect.
- Joining the hotspot opens the device web interface by itself, like a captive portal.
- The networks are stored in a file in the configuration folder.
- The app is reachable over the hotspot only once the user has given the hotspot a password.
- The hotspot starts 10 s without a home connection; while it is up, the home network is tried
  every 60 s.
- Imager's Wi-Fi setting stays in the flashing guide; on the first boot it moves into the file.

Facts this ADR relies on:

- The image runs NetworkManager with `wpasupplicant` (`layer/brewberry-suite.yaml`). A profile
  with `802-11-wireless.mode ap` and `ipv4.method shared` makes a hotspot; NetworkManager then
  runs its own dnsmasq for DHCP and DNS (package `dnsmasq-base`, not on the image yet) and reads
  extra options from `/etc/NetworkManager/dnsmasq-shared.d/`.
- NetworkManager has no "fallback hotspot": once the hotspot profile is active it doesn't scan for
  or switch back to other networks by itself. Something else has to drive the switch.
- The Pi has one Wi-Fi radio (Pi 3 B: 2.4 GHz only). Concurrent hotspot and client mode is
  unreliable on its `brcmfmac` driver, so trying a network takes the hotspot down. Whether the
  driver can scan while it is a hotspot is not verified.
- Profiles in `/run/NetworkManager/system-connections/` are read like those in `/etc` and need no
  write to the root.
- Imager's Wi-Fi arrives as netplan v2 (`network-config` on the boot partition); cloud-init writes
  it to `/etc/netplan/` on the first boot, while the root is still writable, and netplan renders
  it for NetworkManager (OS7). Today changing it means reflashing.
- Without a Wi-Fi country the kernel uses the world regulatory domain: a home network on 5 GHz or
  on channels 12–13 may not be found.
- The app's web UI (port 8080, `Network=host`, all interfaces) has no login (app `IF-060`) and
  controls a mains-powered heater. The device web interface (8081) and the share (445) need the
  `brewberry` password, by default `pi`.
- The device web interface accepts IP addresses in its `Host` check (`server.py`,
  `host_allowed`), and its root helper can already pass a secret on stdin (`update.login`).
- `brewberry-config import` and `export` take every top-level `*.json` in `/data/config`;
  `show` prints only `config.json` and lists the other names. The app reads only `config.json`
  and its recipes from `/config`.
- Phones and laptops detect captive portals over plain HTTP (Apple `captive.apple.com`, Android
  `connectivitycheck.gstatic.com/generate_204`, Windows `www.msftconnecttest.com`), and newer
  ones also read the portal address from DHCP option 114 (RFC 8910).

## Options considered

1. **Ask for Wi-Fi in Imager only (today).** Needs information at flashing; a wrong password or a
   new router means reflashing. Rejected by the product owner.
2. **A `wifi.json` on the boot partition**, like Raspberry Pi OS's old `wpa_supplicant.conf`.
   Needs a computer and a card reader for every change, and the boot partition must stay
   read-only. Rejected.
3. **An existing captive-portal project** (`comitup`, `wifi-connect`, `RaspAP`). Each brings its
   own web server, login and storage, outside the CLI ⇄ web parity of ADR-0002, and writes its
   state to `/etc`. Rejected.
4. **A fallback hotspot managed by a small `brewberry-wifi` service on top of NetworkManager**, its
   settings in `/data/config/wifi.json`, set up in the device web interface. Uses what the image
   has, keeps one implementation (the CLI) and one login.
5. **Hotspot access:** fully open including the app (anyone in Wi-Fi range can start the heater),
   a fixed documented hotspot password (no better: the password is public), or **open for setup
   only, the app after the user sets a hotspot password**.

## Decision

We choose **option 4** with option 5's last variant, in a new layer `brewberry-wifi`:

- **Settings:** `/data/config/wifi.json`, owned by `brewberry` like the other files in the share,
  written atomically by the CLI, and also editable in the share or imported with
  `brewberry-config import` / `brewberry-usb import-config`:

  ```json
  {
    "country": "DE",
    "networks": [ { "ssid": "Home", "password": "…", "hidden": false } ],
    "hotspot": { "password": "" }
  }
  ```

  A missing file means no networks and an open hotspot. A file that can't be read is treated the
  same (logged, shown in the status), so the user can always reach the Pi to fix it. A path unit
  applies changes at once.
- **Profiles:** `brewberry-wifi` renders one NetworkManager profile per network, and the hotspot
  profile, into `/run/NetworkManager/system-connections/` (`0600`, root), and sets the country
  with `iw reg set`.
- **Hotspot:** SSID = the host name (`brewberrypi` by default), 2.4 GHz, address `10.42.0.1/24`,
  IPv6 off. Open while `hotspot.password` is empty, WPA2-PSK when it is set (8–63 characters).
- **Switching** (`brewberry-wifi.service`, a loop over `nmcli`, `Restart=always`):
  - With Ethernet connected there is no hotspot.
  - Without networks in the file, the hotspot starts at once.
  - With networks, NetworkManager tries them. When there has been no home connection, and no
    attempt in progress, for **10 s** (after boot, after a failed attempt or after a drop), the
    hotspot starts. A single attempt (association and DHCP) may take up to 30 s.
  - While the hotspot is up and networks are configured, every **60 s** the hotspot is taken
    down and the networks are tried; if none connects, the hotspot is back within 10 s. If the
    driver can scan while it is a hotspot, a network is only tried when it is visible, so the
    hotspot stays up while the home network is out of range.
  - A network that fails with a wrong password is not retried until its entry changes: the user is
    then on the hotspot to fix it, and a retry every 60 s would cut them off for nothing.
  - The app and the GPIOs are never touched: a brew continues through every switch.
- **Captive portal:** in hotspot mode NetworkManager's dnsmasq answers every name with
  `10.42.0.1` and sends DHCP option 114. A small redirector on port 80 (part of `brewberry-web`,
  socket-activated, unprivileged) answers every request with a redirect to the device web
  interface's Wi-Fi screen: `http://10.42.0.1:8081/` when it arrives on the hotspot, otherwise
  the request's own host name with port 8081 (so `http://brewberrypi.local/` works too). The
  login stays as it is (ADR-0002).
- **Access over the hotspot:** while the hotspot is active and has no password, an nftables rule
  (loaded and removed by a NetworkManager dispatcher script) drops connections to port 8080 that
  arrive on the Wi-Fi interface. Ports 80, 8081 and 445 stay open. With a hotspot password the
  rule isn't loaded, and the app can be used without a home network.
- **Operator command** (CLI ⇄ web parity, ADR-0002): `brewberry-wifi status|scan|add <ssid>|
  forget <ssid>|country <code>|hotspot-password`, with `--json` on queries; passwords on stdin,
  never as arguments. `add` and `forget` explain that the browser loses its connection when the
  Pi changes network, and where to find it afterwards; that text comes from the CLI. The web
  interface gets a Wi-Fi screen, and the overview shows the network status. Catalogue, page and
  the user manual's command reference change in the same commit (`tests/unit/parity.sh`).
- **Imager's Wi-Fi:** stays in the flashing guide, optional. On the first boot, before the seal,
  `brewberry-wifi migrate` copies the networks and the regulatory domain from cloud-init's
  netplan file into `wifi.json` (keeping entries already there) and removes the Wi-Fi part of the
  netplan file, so `wifi.json` is the only place Wi-Fi is configured.

## Consequences

- **Positive:**
  - A card flashed without any customisation can be set up from a phone: join `brewberrypi`,
    log in, pick the network.
  - A new router or a changed password no longer means reflashing.
  - With a hotspot password, brewing works without any home network.
  - Wi-Fi settings survive a reflash through `brewberry-config export` and a USB import.
  - The runtime contract and the app repository don't change.
- **Negative / risks:**
  - **Open hotspot:** anyone in range can join it, reach the login pages and try the default
    password `pi` against the web interface and the share. The app is blocked, but this also
    happens whenever the home Wi-Fi drops.
  - **Wi-Fi passwords in plain text** in `wifi.json`: readable in the share, in exports and backups,
    and by the app container (it reads `/config`).
  - **Single radio:** after "connect", the hotspot and the page disappear; the user sees success
    only by finding the Pi on the home network. A failure shows only when the hotspot comes back.
  - **60 s retries:** a phone on the hotspot loses it for up to about 40 s every minute while a
    configured home network is in range but unreachable (or always, if the driver can't scan as a
    hotspot); a slow router after a power cut gets 10 s before the hotspot starts.
  - With several BrewberryPis on the default host name, their hotspots and `.local` names clash.
  - Without internet on the hotspot the clock isn't synchronised (no RTC on Pi 3/4).
  - Phones may send other traffic over mobile data while on a hotspot without internet; the Pi's
    own address still works.
  - New packages: `dnsmasq-base`, `nftables`. A fourth listening service (port 80).
  - Not yet tested on hardware: `brcmfmac` hotspot mode and scanning on Pi 3/4/5, `iw reg set` with
    its firmware, captive-portal pop-ups on iOS, Android, Windows and macOS, the netplan
    migration with Imager's file.
- **Follow-ups:**
  - Milestone OS11 in the [implementation plan](../implementation-plan.md), check
    `tests/hardware/os11-check.sh`; the design goes into [device-web-ui.md](../device-web-ui.md).
  - User manual and flashing guide: Wi-Fi optional, first setup over the hotspot.
  - Maybe: set the clock from the browser in hotspot mode; TLS (ADR-0002) matters more now that the
    login can travel over an open network.
