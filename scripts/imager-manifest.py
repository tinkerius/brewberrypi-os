#!/usr/bin/env python3
"""Write a Raspberry Pi Imager manifest (os_list JSON) for BrewberryPi OS images.

Usage:
  scripts/imager-manifest.py --url-base URL IMAGE.img.xz... > brewberrypi-os.rpi-imager-manifest
  scripts/imager-manifest.py --local IMAGE.img.xz...       > brewberrypi-os.rpi-imager-manifest

--url-base: the images are downloaded from URL/<file name> (a release).
--local:    the images are the local files (file:// URLs), for images
            downloaded by hand, e.g. from a private repository's release.

Imager 2.x offers its OS customisation (hostname, user, SSH key, Wi-Fi) only
for images opened through a manifest that sets init_format (OS7). Open the
manifest by double-clicking it, through App Options > Content Repository, or
with 'rpi-imager --repo <manifest>'.

The board comes from the file name (brewberrypi-os-pi34-*, brewberrypi-os-pi5-*).
The manifest lists no interface capabilities (SPI, I2C, 1-Wire, serial, USB
gadget), so Imager offers none: SPI would take the buzzer pin (BCM 10), and
the image's config.txt safety block decides the interfaces.
"""

import argparse
import datetime
import hashlib
import json
import lzma
import os
import pathlib
import re
import sys

# Imager device tags (as in Raspberry Pi's own os_list) per image board.
BOARDS = {
    "pi34": {
        "name": "BrewberryPi OS (Raspberry Pi 3 and 4)",
        "devices": ["pi3-64bit", "pi4-64bit"],
    },
    "pi5": {
        "name": "BrewberryPi OS (Raspberry Pi 5)",
        "devices": ["pi5-64bit"],
    },
}

DEVICES = [
    {"name": "Raspberry Pi 5", "tags": ["pi5-64bit"], "description": "Raspberry Pi 5, 500 and CM5"},
    {"name": "Raspberry Pi 4", "tags": ["pi4-64bit"], "description": "Raspberry Pi 4, 400 and CM4"},
    {"name": "Raspberry Pi 3", "tags": ["pi3-64bit"], "description": "Raspberry Pi 3 (64-bit)"},
]

DESCRIPTION = ("Read-only system for the BrewberryPi mash kettle controller. "
               "The app runs as a signed container.")

# Built into Imager: a path relative to its own icons.
ICON = "icons/cat_home_automation.png"

# The OS capabilities Imager may offer. Never an interface (see above).
CAPABILITIES = ["passwordless_sudo"]
INTERFACES = {"i2c", "spi", "onewire", "serial", "usb_otg"}

NAME_RE = re.compile(r"^brewberrypi-os-(pi34|pi5)-(.+)\.img\.xz$")
CHUNK = 1 << 20


def sha256(f):
    h = hashlib.sha256()
    size = 0
    while chunk := f.read(CHUNK):
        h.update(chunk)
        size += len(chunk)
    return size, h.hexdigest()


def digest(path):
    """Download size and SHA-256, extracted size and SHA-256 of an .img.xz."""
    with open(path, "rb") as f:
        download_size, download_sha256 = sha256(f)
    with lzma.open(path, "rb") as f:
        extract_size, extract_sha256 = sha256(f)
    return download_size, download_sha256, extract_size, extract_sha256


def entry(path, url_base, release_date):
    m = NAME_RE.match(path.name)
    if not m:
        raise ValueError(f"{path.name}: expected brewberrypi-os-<pi34|pi5>-<version>.img.xz")
    board, version = m.groups()
    url = f"{url_base.rstrip('/')}/{path.name}" if url_base else path.resolve().as_uri()
    download_size, download_sha256, extract_size, extract_sha256 = digest(path)
    return {
        "name": f"{BOARDS[board]['name']} {version}",
        "description": DESCRIPTION,
        "icon": ICON,
        "url": url,
        "extract_size": extract_size,
        "extract_sha256": extract_sha256,
        "image_download_size": download_size,
        "image_download_sha256": download_sha256,
        "release_date": release_date,
        "init_format": "cloudinit-rpi",
        "devices": BOARDS[board]["devices"],
        "capabilities": CAPABILITIES,
    }


def manifest(images, url_base, release_date):
    assert not INTERFACES & set(CAPABILITIES)
    return {
        "imager": {
            "devices": [dict(d, matching_type="exclusive") for d in DEVICES],
        },
        "os_list": [entry(p, url_base, release_date) for p in images],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--url-base", help="download URL of the directory holding the images")
    where.add_argument("--local", action="store_true", help="use file:// URLs of the local images")
    parser.add_argument("--release-date", default=datetime.date.today().isoformat(),
                        help="YYYY-MM-DD (default: today)")
    parser.add_argument("images", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    if args.url_base and not re.match(r"^https?://[^/]+", args.url_base):
        parser.error("--url-base must be an absolute http(s) URL")
    try:
        datetime.date.fromisoformat(args.release_date)
        data = manifest(args.images, args.url_base, args.release_date)
    except (OSError, ValueError, lzma.LZMAError) as e:
        print(f"imager-manifest: {e}", file=sys.stderr)
        return 1
    json.dump(data, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
