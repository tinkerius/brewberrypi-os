# Releasing BrewberryPi OS

A release is a GitHub release with both images, the Raspberry Pi Imager manifest and `SHA256SUMS`.
Pushing a version tag creates it as a **draft**. It is published by hand once the hardware checks
pass on the draft's own images. A **pre-release** tag is published at once instead, marked as
untested (see [Pre-releases](#pre-releases)).

## Versions

- Tags are `vMAJOR.MINOR.PATCH` (`v0.1.0`). The image files take the tag as their version
  (`brewberrypi-os-pi34-v0.1.0.img.xz`), and so does `BREWBERRY_OS_VERSION` in
  `/etc/brewberry-release`. A tag build takes its tag (`BREWBERRY_OS_VERSION`, set by CI), other
  builds `git describe`.
- The OS version is independent of the app version. Which app the image preloads is recorded in
  `BREWBERRY_OS_APP_PRELOAD`.
- Releases stay at `0.x` until OS8 (end-to-end with the real app) is done; the first release that
  preloads a signed app release ≥ 1.0 and passes OS8 is `v1.0.0`.
- Bump MAJOR for changes that break devices in the field: the runtime contract version, the
  partition layout, or the signing keys. Bump MINOR for features and PATCH for fixes and package
  updates.

## Pre-releases

For images to try out before the hardware checks have passed, tag a pre-release:
`vMAJOR.MINOR.PATCH-alpha.N` (or `-beta.N`, `-rc.N`), for example `v0.1.0-alpha.1`. The `release`
job publishes it immediately as a GitHub **pre-release** (never marked "Latest"), and its notes
start with a warning: not tested on hardware, never connect a mains heater, which app it preloads,
and that reflashing erases `/data`. Everything else (artifacts, manifest, `SHA256SUMS`) is the same
as for a release. Follow up with a normal version tag once the checks pass.

```sh
git tag -a v0.1.0-alpha.1 -m "BrewberryPi OS v0.1.0-alpha.1 (pre-release, untested on hardware)"
git push origin v0.1.0-alpha.1
```

## Before tagging

1. `main` is green in CI, and everything for the release is merged.
2. Decide what the image preloads:
   - **Contract stub** (default): leave the repository variable `BREWBERRY_APP_VERSION` empty.
   - **App release:** set `BREWBERRY_APP_VERSION` to the app version (`1.2.3` or `1.2.3-alpha.N`) (Settings → Secrets and variables →
     Actions → Variables), and make sure CI can read the app's package: the secret
     `BREWBERRY_GHCR_TOKEN` (classic PAT, `read:packages`), or this repository under the
     package's *Manage Actions access*. The build refuses an app image that isn't signed with the
     pinned key or whose labels don't say contract 1 and that version.
3. Decide whether to build an SSH key in (`BREWBERRY_SSH_PUBKEY`). For a public release, leave it
   empty: users add their own key in Imager's customisation.
4. Check that `keys/app-cosign.pub` still equals the app repository's `deploy/signing/cosign.pub`.

## Tag

```sh
git checkout main && git pull
git tag -a v0.1.0 -m "BrewberryPi OS v0.1.0"
git push origin v0.1.0
```

Without git at hand (or where tags can't be pushed), run the **tag release** workflow instead:
Actions → *tag release* → *Run workflow*, with the version (`v0.1.0` or `v0.1.0-alpha.1`). It
tags `main` and starts the build on the tag; the result is the same.

The tag runs `.github/workflows/build.yml`: `lint`, `signature policy` and both image builds. If
they all pass, the `release` job:

1. downloads the `brewberrypi-os-pi34` and `brewberrypi-os-pi5` artifacts;
2. writes `brewberrypi-os.rpi-imager-manifest` with download URLs for this release
   (`scripts/imager-manifest.py --url-base …`);
3. writes `SHA256SUMS` for the images and the manifest;
4. creates the draft release "BrewberryPi OS v0.1.0" with generated notes and those files (for a
   pre-release tag: the published pre-release, see above).

If a job fails, no release is created. Fix the problem on `main` and tag the next patch version.
Don't move a pushed tag.

## Check the draft

Download the images from the draft. The manifest's URLs only work once the release is published,
so write a local manifest for the downloaded files:

```sh
sha256sum -c SHA256SUMS
scripts/imager-manifest.py --local brewberrypi-os-*.img.xz > local.rpi-imager-manifest
```

Then run the hardware checks in [tests/hardware/README.md](../tests/hardware/README.md) on **both
boards** (a Pi 3 or 4, and a Pi 5), using the draft's images:

- every release: OS1 `status`, OS2, **OS3 (safety)** and OS7 (Imager customisation);
- when the release changes that area: the OS1 power-cut cycles (layout, mounts, first boot),
  OS4 (updates, rollback, safe mode), OS5 (USB) and OS6 (maintenance mode);
- with an app preloaded: OS8.

Never test OS3 with the heater connected; use LEDs or the relay board on its own.

## Publish

1. Edit the draft's notes: what changed, which app it preloads, and any action users need to take
   (for example a new key or contract version).
2. Click **Publish release**.
3. If this release completes a milestone, close its issue and set it to *Done* on the project
   board.

Users flash it by opening `brewberrypi-os.rpi-imager-manifest` from the release in Raspberry Pi
Imager 2.x (see [flashing.md](flashing.md)). While the repository is private, Imager can't download
from the release URLs; users then download the images and use a `--local` manifest instead.

## If a published release is broken

Don't delete the release or move its tag; devices and manifests refer to them. Mark the release
as broken in its notes, fix the problem on `main` and release the next patch version.

There is no over-the-air update to a new OS release. Our layers, units and keys reach a device
only through a **reflash**, which erases `/data` (config, app images, registry token); the
release notes must say what users need to back up and redo (see the
[user manual](user-manual.md)). Maintenance mode ([os-update.md](os-update.md)) only applies
Debian and Raspberry Pi OS package updates, and app versions are updated separately with
`brewberry-update`.
