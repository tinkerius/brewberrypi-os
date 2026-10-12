#!/bin/bash
# Static checks: shell scripts, YAML, and rpi-image-gen layer metadata.
#
# Usage: scripts/lint.sh
# Needs shellcheck, yamllint and python3-yaml. Also runs the unit tests (stub/, tests/unit/).

set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

cd "$REPO_ROOT"

shellcheck -x scripts/*.sh
# rpi-image-gen hooks get their IGconf_* variables from the build environment.
shellcheck -e SC2154,SC1091 image/*/*.sh image/*/bdebstrap/*
shellcheck layer/*.rootfs-overlay/usr/local/sbin/* tests/hardware/*.sh tests/unit/*.sh
yamllint -s config/ .github/
fetch_rpi_image_gen
for layer in layer/*.yaml image/*/image.yaml; do
   "$RPI_IMAGE_GEN_DIR/rpi-image-gen" metadata --lint "$layer"
done
python3 -m unittest discover -s stub
for t in tests/unit/*.sh; do "$t"; done
echo "lint ok"
