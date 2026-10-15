#!/bin/bash
# Build the contract stub image (stub/) for linux/arm64 and save it in 'dir:'
# format (podman save --format docker-dir), ready to be preloaded into the OS
# image. The device's policy.json accepts unsigned images only from that path.
#
# Usage: scripts/build-stub.sh [output dir]  (default: work/preload/brewberrypi-stub)
#
# Environment:
#   STUB_VERSION  image version and tag (default: placeholder). The preloaded
#                 stub is not an app release, so it reports 'placeholder', not a
#                 version number; publish-test-stubs.sh gives its OS4 test images
#                 release versions because they stand in for app releases.
#   STUB_START    default start mode: ok, crash, hwfail, config, hang (default: ok)

set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

OUT=${1:-$REPO_ROOT/work/preload/brewberrypi-stub}
VERSION=${STUB_VERSION:-placeholder}
START=${STUB_START:-ok}
TAG=localhost/brewberrypi-stub:$VERSION

podman build --platform linux/arm64 \
   --build-arg "VERSION=$VERSION" --build-arg "START=$START" \
   -t "$TAG" -f "$REPO_ROOT/stub/Containerfile" "$REPO_ROOT/stub"
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
podman save --format docker-dir -o "$OUT" "$TAG"
echo "saved $TAG to $OUT"
