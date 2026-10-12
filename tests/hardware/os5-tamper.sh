#!/bin/bash
# For the OS5 hardware test, on your machine: copy the export of 0.2.0 on the
# stick to brewberrypi/images/9.9.9 and change one byte of a layer, so the
# device must reject it.
#
# Usage: tests/hardware/os5-tamper.sh <stick mount point>
set -euo pipefail
src=${1:?usage: os5-tamper.sh <stick mount point>}/brewberrypi/images/0.2.0
dst=$(dirname "$src")/9.9.9
[ -f "$src/manifest.json" ] || { echo "export 0.2.0 first (scripts/usb-export.sh)" >&2; exit 1; }
rm -rf "$dst"
cp -r "$src" "$dst"
# The index or manifest names the layers; take the biggest blob as a layer.
blob=$(find "$dst" -type f -name '[0-9a-f]*' -printf '%s %p\n' | sort -n | tail -n 1 | cut -d' ' -f2)
printf 'X' | dd of="$blob" bs=1 seek=100 conv=notrunc 2> /dev/null
sync
echo "tampered copy in $dst"
