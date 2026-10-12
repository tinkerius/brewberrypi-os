#!/bin/bash
# Tests for scripts/imager-manifest.py with small fake images: sizes and
# SHA-256 of the download and the extracted image (multi-block and
# concatenated xz streams), release and local URLs, Imager's cloudinit-rpi
# format, the board's device tags, and no interface capabilities (SPI would
# take the buzzer pin). Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
GEN=$ROOT_DIR/scripts/imager-manifest.py
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

failures=0
check() { # <description> <command...>
   local what=$1
   shift
   if "$@" > /dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; failures=1; fi
}

PI34=$T/brewberrypi-os-pi34-v1.2.3.img.xz
PI5=$T/brewberrypi-os-pi5-v1.2.3.img.xz
head -c 3000000 /dev/urandom > "$T/a.img"
head -c 1000000 /dev/urandom > "$T/b.img"
xz -T2 --block-size=500000 -c "$T/a.img" > "$PI34"   # several blocks
{ xz -c "$T/a.img"; xz -c "$T/b.img"; } > "$PI5"      # two streams
cat "$T/a.img" "$T/b.img" > "$T/ab.img"

"$GEN" --url-base https://example.org/releases/v1.2.3/ --release-date 2026-10-12 "$PI34" "$PI5" > "$T/release.json"
"$GEN" --local "$PI34" > "$T/local.json"

field() { # <manifest> <jq filter>
   jq -r "$2" "$1"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

check "pi34: download size and SHA-256" \
   test "$(field "$T/release.json" '.os_list[0] | "\(.image_download_size) \(.image_download_sha256)"')" = \
        "$(stat -c %s "$PI34") $(sha "$PI34")"
check "pi34: extracted size and SHA-256" \
   test "$(field "$T/release.json" '.os_list[0] | "\(.extract_size) \(.extract_sha256)"')" = \
        "$(stat -c %s "$T/a.img") $(sha "$T/a.img")"
check "pi5: concatenated xz streams are all extracted" \
   test "$(field "$T/release.json" '.os_list[1] | "\(.extract_size) \(.extract_sha256)"')" = \
        "$(stat -c %s "$T/ab.img") $(sha "$T/ab.img")"
check "release URL is the base plus the file name" \
   test "$(field "$T/release.json" '.os_list[0].url')" = \
        "https://example.org/releases/v1.2.3/brewberrypi-os-pi34-v1.2.3.img.xz"
check "local URL is an absolute file:// URL" \
   test "$(field "$T/local.json" '.os_list[0].url')" = "file://$PI34"
check "Imager customisation format is cloudinit-rpi" \
   test "$(field "$T/release.json" '[.os_list[].init_format] | unique | join(",")')" = cloudinit-rpi
check "pi34 image lists the Pi 3 and Pi 4 tags" \
   test "$(field "$T/release.json" '.os_list[0].devices | join(",")')" = pi3-64bit,pi4-64bit
check "pi5 image lists the Pi 5 tag" \
   test "$(field "$T/release.json" '.os_list[1].devices | join(",")')" = pi5-64bit
check "release date and version in the name" \
   test "$(field "$T/release.json" '.os_list[0] | "\(.release_date) \(.name)"')" = \
        "2026-10-12 BrewberryPi OS (Raspberry Pi 3 and 4) v1.2.3"
check "no interface capability (SPI, I2C, 1-Wire, serial, USB gadget) for images or devices" \
   test "$(field "$T/release.json" '[(.os_list[], .imager.devices[]) | (.capabilities // [])[]
      | select(IN("spi", "i2c", "onewire", "serial", "usb_otg"))] | length')" = 0
check "every image tag has a device to choose" \
   test "$(field "$T/release.json" '([.os_list[].devices[]] - [.imager.devices[].tags[]]) | length')" = 0
check "every entry has Imager's required fields" \
   test "$(field "$T/release.json" '[.os_list[] | select(has("name") and has("description") and has("icon")
      and has("url") and has("extract_size") and has("extract_sha256") and has("image_download_size")
      and has("release_date") and has("devices"))] | length')" = 2

# shellcheck disable=SC2317  # called through check()
refuses() { ! "$GEN" "$@"; }
cp "$PI34" "$T/something-else.img.xz"
check "unknown file name: refused" refuses --local "$T/something-else.img.xz"
check "relative --url-base: refused" refuses --url-base releases/ "$PI34"
head -c 100000 "$PI34" > "$T/brewberrypi-os-pi34-cut.img.xz"
check "truncated image: refused" refuses --local "$T/brewberrypi-os-pi34-cut.img.xz"

exit "$failures"
