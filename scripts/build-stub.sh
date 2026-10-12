#!/bin/bash
# Build the contract stub image (stub/) for linux/arm64 and save it as a
# 'podman save' tarball, ready to be preloaded into the OS image.
#
# Usage: scripts/build-stub.sh [output]  (default: work/preload/brewberrypi-stub.tar)
#
# Environment:
#   STUB_VERSION  image version and tag (default: 0.1.0)
#   STUB_START    default start mode: ok, crash, hwfail, config, hang (default: ok)

set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

OUT=${1:-$REPO_ROOT/work/preload/brewberrypi-stub.tar}
VERSION=${STUB_VERSION:-0.1.0}
START=${STUB_START:-ok}
TAG=localhost/brewberrypi-stub:$VERSION

podman build --platform linux/arm64 \
   --build-arg "VERSION=$VERSION" --build-arg "START=$START" \
   -t "$TAG" -f "$REPO_ROOT/stub/Containerfile" "$REPO_ROOT/stub"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
podman save -o "$OUT" "$TAG"
echo "saved $TAG to $OUT"
