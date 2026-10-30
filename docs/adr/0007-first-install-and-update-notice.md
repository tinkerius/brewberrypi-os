# ADR-0007: The app installs itself, and updates are announced

- **Status:** Proposed (implemented in OS14, not yet tested on hardware; the app side in §"In the app" is a proposal)
- **Date:** 2026-10-30
- **Deciders:** Benedikt Hauptmann (product owner); proposal and research by Claude Code
- **Changes:** [ADR-0001](0001-os-image-and-app-runtime.md) "Updating and selecting versions": a
  timer now runs `brewberry-update list` and, only while no app is installed, `download` and
  `install`; the registry is used without a token when there is none

## Context

Product-owner wish (2026-10-30): move from "I pick an app version on the device and install it by
hand" to "the system works from the start, and tells me about updates, which I can download
easily":

- the OS downloads the newest app version by itself and installs it; until then the placeholder
  (the contract stub) keeps running, as now;
- the OS checks the registry regularly and shows a notice when a newer version exists;
- optional: the notice in the app too.

Until now a fresh Pi ran the placeholder until someone stored a registry token and picked a version
(`brewberry-update login`, `download`, `install`), and nothing said when a new version came out.

Constraints:
- **Installing restarts the app and ends a running brew** (ADR-0002). Nothing may restart a real app
  version unasked.
- **The registry is private** (ADR-0001): every request needs a token, so a fresh Pi can't see or
  download anything until a token is stored. GHCR lets anyone list and pull a *public* package
  without a token ([GitHub Docs: package visibility](https://docs.github.com/en/enterprise-server@3.13/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility));
  making a package public can't be undone. The signature policy (`policy.json`, pinned cosign key)
  protects the Pi either way: a public package changes who can *read* the image, not what the Pi runs.
- Local only, no vendor cloud (ADR-0001): the only server asked is the registry the Pi already uses.
- Releases so far are all pre-releases (`0.1.0-alpha.N`).

### What similar devices do (research 2026-10-30)

- **Home Assistant:** updates are entities; a new version shows in *Settings → System → Updates* and
  as a badge on *Settings* in the sidebar, and can be put on a dashboard card. It never installs Home
  Assistant itself without being asked; an older version showed a badge in the frontend
  ([community](https://community.home-assistant.io/t/update-notifications-for-home-assistant/1014021)).
- **OctoPrint** (a printer controller on a Pi, the closest relative: a long-running physical
  process): the Software Update plugin checks the version sources with a cache of 6 hours by
  default, shows a notification with *Update now* to admins (without the button to other users),
  and offers a forced check
  ([docs](https://docs.octoprint.org/en/devel/bundledplugins/softwareupdate.html)). It refuses to
  update while printing.
- Routers and NAS (FRITZ!Box, Synology DSM) and Pi-hole: a badge or a line in the header or footer
  that links to the update page, plus a banner on the overview; automatic installs are a setting,
  and off for anything that interrupts work.

Common to all: a **quiet, persistent mark in the global header or navigation** that links to the
update page, details and the action on that page, **no pop-up that blocks a screen**, checks a few
times a day, and **no automatic install while the device is doing its job**.

## Options considered

1. **Install every new version automatically.** The most hands-off, but it restarts the app and ends
   a brew, and a release that is fine on the bench may not be on hardware (pre-releases are
   untested). Rejected.
2. **Install automatically only while no app is installed; announce every other update** (chosen).
   The placeholder never switches outputs and has no brew to end, so replacing it is safe at any
   time; an installed app is replaced only when the brewer chooses.
3. **Preload a released app in the OS image** (`scripts/fetch-app.sh`, already possible). Works
   offline from the first boot, but the image is as old as its build, and it needs a new OS release
   for every app release. Kept as an option for OS releases; on such a Pi option 2 only announces
   updates.
4. **Download updates automatically, install by hand.** One click less, but about 250 MB on `/data`
   for every release, also for versions the brewer skips. Rejected: the download is one click and
   the app keeps running meanwhile.

Where the notice shows in the device web interface:
- a pop-up or modal: rejected (blocks the screen, the commonest complaint about update prompts);
- **a pill in the top bar on every screen and a dot on the *App versions* tab** (chosen), linking to
  a card at the top of *App versions* with the action;
- a row in the overview's *App* card (also chosen, as the plain-text form).

## Decision

### Registry access

`brewberry-update` uses the registry **without a token when none is stored** (Podman and skopeo
refuse an auth file that doesn't exist, so `REGISTRY_AUTH_FILE` is only set when there is one). A
registry that refuses says so: "the registry needs a token; run: brewberry-update login". So the Pi
works with a private registry after `login`, as before, and with a **public** one without any setup.

**Recommendation to the product owner:** make the package `ghcr.io/tinkerius/brewberrypi-app`
public. Only then does a fresh Pi install the app with no step at all. The cosign signature check
stays the gate for what runs on the Pi.

### Update check: `brewberry-update-check` (timer)

`brewberry-update-check.timer` runs `brewberry-update-check` 2 minutes after boot and then 15
minutes after each run ends. It is not an operator command: it only runs `brewberry-update`.

- It asks the registry (`brewberry-update list`, which writes `/data/update/tags.json`) **every
  6 hours** (OctoPrint's default); a manual *Check the registry* counts too. `tags.json` records the
  last answer (`time`, `tags`), the last try (`tried`) and why it failed (`error`), keeping the last
  answer when the registry can't be reached. A last try in the future (the Pi has no clock and
  the time was set back) counts as never.
- `brewberry-update status` reports the update (`--json`: `update: {latest, available, onPi,
  firstInstall, checked, tried, error}`). **Which version is offered**, without a setting:
  - on a release: the newest release (pre-releases are never offered);
  - on a pre-release: the newest version, pre-releases included (installing one opted in);
  - with no app installed: the newest release, or the newest pre-release while there is no release.
  `available` means newer than the active version in SemVer order. The decision is in the CLI; the
  web page only shows it (ADR-0002).

### First install

Until **the first app version is installed** (`firstInstall`: the active and the previous image are
the placeholder or nothing; not after a rollback or safe mode back to the placeholder, which someone
or something chose), the check
asks the registry at every run (every 15 minutes) and, when it gets an answer, runs
`brewberry-update download <latest>` and `brewberry-update --yes install <latest>`: the same
signature, contract and version checks, the 60-second watch and the rollback as by hand. The
placeholder runs until the install switches. A version that fails is tried **3 times**
(`/data/update/first-install.json`), then left alone until a newer one is released; the placeholder
keeps running and the notice says the last try failed. `brewberry-update login` starts a check at
once, so with a private registry the install follows the login within seconds.

It **never installs over an app version**; demo mode and the configuration are untouched.

### The notice in the device web interface

- top bar, on every screen: a pill *Update: 1.2.0* (with no app installed: *Installing the app
  1.2.0*), linking to *App versions*;
- a dot on the *App versions* tab;
- on *App versions*: a card at the top with the versions, *Download 1.2.0*, then *Install 1.2.0*
  (the catalogue's `update.download` and `update.install`, with their confirmation and brew
  warning); while the first install runs, its progress instead of buttons;
- the overview's *App* card: a row *Update*.

The page reads `update.status` when a screen loads and every 5 minutes. No new operator command:
the check is the existing `list` (*Check the registry*); the log is `brewberry-system logs update`.

### In the app (proposal, needs runtime contract 3)

The brewer spends most time in the app, not in the device web interface, so a notice there is
useful. It is possible without the app ever talking to the registry or installing anything
(app spec `Q-16` stays "versions are changed with the OS tooling only"):

1. **The OS hands the app a small, read-only notice.** `brewberry-update-check` writes
   `/data/update/notice/update.json` atomically:
   `{"version": "1.2.0", "current": "1.1.0", "checked": "<time>", "url": "http://{host}:8081/#versions"}`
   (no file: no update). The Quadlet unit mounts the folder read-only:
   `Volume=/data/update/notice:/host:ro`, so the app reads `/host/update.json`. A folder, not the
   file, because a bind-mounted file keeps the old inode after an atomic rename.
2. **The app** watches the file (as it watches `recipes/`, `RCP-006`), adds
   `updateAvailable: {version}` to its state snapshot and push stream, and the UI shows:
   - in the top bar, on the existing *Device settings* link (`Q-30`, `ui.deviceLink`): a dot and
     *Update 1.2.0*, opening the device web interface's *App versions* in a new tab;
   - only while no process is loaded (`NoProcess`): a dismissible line above the recipe list,
     *BrewberryPi 1.2.0 is available. Install it in the device settings.* Dismissed per version
     (browser storage). **Never during a brew**: it would distract, and installing ends the brew.
   No install button in the app: installing needs the device web interface's login.
3. **Contract:** a new optional item in §3, `/host` (read-only, optional: without it no notice),
   as contract version 3. Because BrewberryPi OS refuses images with another contract label
   (ADR-0001), the OS would first accept both 2 and 3 (the change is additive), then the app
   releases with label 3.

Alternative without a contract change: the app's page fetches a public
`http://{host}:8081/api/update-hint` from the browser (CORS from the app's origin). Rejected for
the proposal: it ties the app's UI to the device web interface's address and port, fails when
`ui.deviceLink` points elsewhere, and only the browser, not the app's server, knows about it.

## Consequences

- **Positive:**
  - A Pi flashed without any setting ends up with the newest app by itself (with a public package),
    and a brewer sees new versions without looking for them.
  - Nothing restarts a real app unasked; every install still goes through the signature policy,
    the contract check, the watch and the rollback.
- **Negative / risks:**
  - With the package private, the first install still needs `login` once.
  - The Pi asks `ghcr.io` every 6 hours (every 15 minutes until the app is installed); behind a
    metered or no connection that is a request that fails quietly.
  - A first install over a slow connection takes minutes, during which the placeholder's page
    says so; the brewer may install by hand in parallel (the lock refuses one of the two).
  - Pre-release users keep being offered pre-releases until they install a release.
- **Follow-ups:**
  - Product owner: make the package public, or keep it private and log in once per Pi.
  - App repository: decide the proposal above (runtime contract 3), and with it `Q-16`'s scope.
  - Release notes in the notice (an image label or the GitHub release) once the app repository is
    public.
