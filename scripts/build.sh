#!/bin/bash
# Build a BrewberryPi OS image.
#
# Usage: scripts/build.sh [config]     (default: brewberrypi-pi34.yaml)
#
# Environment:
#   BREWBERRY_SSH_PUBKEY  SSH public key for the 'brewberry' user. Without it
#                         the image has no way to log in.
#   BREWBERRY_PRELOAD     app image to preload ('podman save' tarball). Default:
#                         build the contract stub with scripts/build-stub.sh.
#   RPI_IMAGE_GEN_DIR     rpi-image-gen checkout (default: .cache/rpi-image-gen)
#
# Needs an arm64 Debian/Ubuntu host (or qemu-user-static with binfmt) with
# rpi-image-gen's dependencies installed: sudo .cache/rpi-image-gen/install_deps.sh
#
# Output: deploy/<image>-<version>.img.xz and its .sha256.

set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

CONFIG=${1:-brewberrypi-pi34.yaml}
WORK_DIR=$REPO_ROOT/work
DEPLOY_DIR=$REPO_ROOT/deploy

VERSION=$(git -C "$REPO_ROOT" describe --tags --always --dirty)
IMAGE_NAME=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["image"]["name"])' \
   "$REPO_ROOT/config/$CONFIG")

fetch_rpi_image_gen
mkdir -p "$WORK_DIR"

PRELOAD=${BREWBERRY_PRELOAD:-}
if [ -z "$PRELOAD" ]; then
   PRELOAD=$WORK_DIR/preload/brewberrypi-stub.tar
   "$REPO_ROOT/scripts/build-stub.sh" "$PRELOAD"
fi
PRELOAD=$(realpath "$PRELOAD")

overrides=("IGconf_brewberry_version=$VERSION" "IGconf_app_preload=$PRELOAD")
if [ -n "${BREWBERRY_SSH_PUBKEY:-}" ]; then
   overrides+=("IGconf_ssh_pubkey_user1=$BREWBERRY_SSH_PUBKEY")
else
   echo "warning: BREWBERRY_SSH_PUBKEY is not set; the image will have no SSH login" >&2
fi

"$RPI_IMAGE_GEN_DIR/rpi-image-gen" build \
   -S "$REPO_ROOT" -c "$CONFIG" -B "$WORK_DIR" -- "${overrides[@]}"

img=$WORK_DIR/image-$IMAGE_NAME/$IMAGE_NAME.img
out=$IMAGE_NAME-$VERSION.img.xz
mkdir -p "$DEPLOY_DIR"
xz -T0 -6 -c "$img" > "$DEPLOY_DIR/$out"
(cd "$DEPLOY_DIR" && sha256sum "$out" > "$out.sha256")
echo "built $DEPLOY_DIR/$out"
