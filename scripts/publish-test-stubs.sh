#!/bin/bash
# Build and push signed contract-stub versions for the OS4 hardware test
# (tests/hardware/os4-check.sh) to a test repository, never the app's.
#
# Usage: scripts/publish-test-stubs.sh <registry/repository>
#   e.g. scripts/publish-test-stubs.sh ghcr.io/tinkerius/brewberrypi-os-test
#
# Creates a throwaway cosign key pair in work/test-signing/ (test.pub is copied
# to the device) and pushes, all linux/arm64:
#   0.2.0  healthy                      signed with test.key
#   0.3.0  crashes on start (exit 1)    signed with test.key
#   0.4.0  healthy                      unsigned
#   0.5.0  healthy                      signed with another key
# Needs podman (logged in to the registry) and cosign v2.x.
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

REPO=${1:?usage: publish-test-stubs.sh <registry/repository>}
case $REPO in
   ghcr.io/tinkerius/brewberrypi | ghcr.io/tinkerius/brewberrypi:*) echo "refusing to push test images to the app repository" >&2; exit 1 ;;
esac
cosign version 2>&1 | grep -q 'GitVersion: *v2\.' || { echo "cosign v2.x required" >&2; exit 1; }

KEYS=$REPO_ROOT/work/test-signing
mkdir -p "$KEYS"
export COSIGN_PASSWORD=""
[ -f "$KEYS/test.key" ] || (cd "$KEYS" && cosign generate-key-pair --output-key-prefix test)
[ -f "$KEYS/other.key" ] || (cd "$KEYS" && cosign generate-key-pair --output-key-prefix other)

publish() { # <version> <start mode> <key prefix or "">
   local ref=$REPO:$1 digest
   podman build --platform linux/arm64 --build-arg "VERSION=$1" --build-arg "START=$2" \
      -t "$ref" -f "$REPO_ROOT/stub/Containerfile" "$REPO_ROOT/stub"
   podman push "$ref"
   if [ -n "$3" ]; then
      digest=$(skopeo inspect "docker://$ref" | jq -r .Digest)
      cosign sign --yes --key "$KEYS/$3.key" --tlog-upload=false "$REPO@$digest"
   fi
}
publish 0.2.0 ok test
publish 0.3.0 crash test
publish 0.4.0 ok ""
publish 0.5.0 ok other
echo "copy $KEYS/test.pub to the device, then follow tests/hardware/README.md (OS4)"
