#!/bin/bash
# Put an app version on a USB stick for an offline install (brewberry-usb, OS5).
#
# Usage: scripts/usb-export.sh <version> <stick mount point> [--repo <registry/repo>] [--key <cosign.pub>]
#   default repo: ghcr.io/tinkerius/brewberrypi; default key: the app key the
#   device pins (layer/brewberry-update.rootfs-overlay/usr/share/brewberrypi/keys).
#
# Writes <stick>/brewberrypi/images/<version> in 'dir:' format with the cosign
# signature (skopeo copy --all: the signature covers the multi-arch index), then
# verifies the export against the device's policy for USB images, so a stick
# that the device would reject is noticed here. Needs skopeo and jq; for the
# private registry, log in first (skopeo login ghcr.io).
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

usage() { echo "usage: usb-export.sh <version> <stick mount point> [--repo <registry/repo>] [--key <cosign.pub>]" >&2; exit 2; }
[ $# -ge 2 ] || usage
VERSION=$1 STICK=$2
shift 2
REPO=ghcr.io/tinkerius/brewberrypi
OVERLAY=$REPO_ROOT/layer/brewberry-update.rootfs-overlay
KEY=$OVERLAY/usr/share/brewberrypi/keys/app-cosign.pub
while [ $# -gt 0 ]; do
   case $1 in
      --repo) REPO=$2; shift 2 ;;
      --key) KEY=$2; shift 2 ;;
      *) usage ;;
   esac
done
# App versions (runtime contract §1): 1.2.3, or a pre-release 1.2.3-alpha.N, -beta.N, -rc.N.
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "not an app version: $VERSION" >&2; exit 1; }
[ -d "$STICK" ] || { echo "no such directory: $STICK" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STICK=$(realpath "$STICK")
DEST=$STICK/brewberrypi/images/$VERSION

mkdir -p "$T/registries.d"
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$REPO" > "$T/registries.d/export.yaml"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
skopeo copy --all --registries.d "$T/registries.d" "docker://$REPO:$VERSION" "dir:$DEST"

# The device's USB rule, for this stick path, repository and key.
jq --arg path "$STICK" --arg repo "$REPO" --arg key "$(realpath "$KEY")" '
   {default: [{type: "reject"}],
    transports: {dir: {($path): [.transports.dir["/media/brewberry-usb"][0]
       | .keyPath = $key | .signedIdentity.dockerRepository = $repo]}}}
' "$OVERLAY/etc/containers/policy.json" > "$T/policy.json"
if skopeo copy --quiet --policy "$T/policy.json" "dir:$DEST" "dir:$T/verify"; then
   echo "exported $REPO:$VERSION to $DEST (signature verified)"
else
   echo "the export does not verify against the device policy; the device would reject it" >&2
   exit 1
fi
