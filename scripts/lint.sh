#!/bin/bash
# Static checks: shell scripts, YAML, and rpi-image-gen layer metadata.
#
# Usage: scripts/lint.sh
# Needs shellcheck, yamllint and python3-yaml.

set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

cd "$REPO_ROOT"

shellcheck -x scripts/*.sh
yamllint -s config/ .github/
fetch_rpi_image_gen
for layer in layer/*.yaml; do
   "$RPI_IMAGE_GEN_DIR/rpi-image-gen" metadata --lint "$layer"
done
echo "lint ok"
