#!/bin/bash
# Fetch a released app version as the image's preload (OS8): the arm64 image
# from the registry in 'dir:' format, with its cosign signature, verified
# against the key the device pins and checked for the runtime contract and
# version labels. scripts/build.sh calls this when BREWBERRY_APP_VERSION is set.
#
# Usage: scripts/fetch-app.sh <version> <dest dir> [--repo <registry/repo>] [--key <cosign.pub>] [--insecure]
#   default repo: ghcr.io/tinkerius/brewberrypi-app; default key: the app key the
#   device pins; --insecure: plain-HTTP registry (tests only).
#
# The device accepts the preload unsigned (policy.json, path-scoped), so this
# build-time check is what keeps an unsigned or foreign image out of the OS
# image. The app's release CI signs recursively (cosign sign --recursive), so
# the arm64 manifest carries its own signature. Needs skopeo and jq; for the
# private registry, log in first (skopeo login ghcr.io).
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

CONTRACT=2

usage() { echo "usage: fetch-app.sh <version> <dest dir> [--repo <registry/repo>] [--key <cosign.pub>] [--insecure]" >&2; exit 2; }
[ $# -ge 2 ] || usage
VERSION=$1 DEST=$2
shift 2
REPO=ghcr.io/tinkerius/brewberrypi-app
OVERLAY=$REPO_ROOT/layer/brewberry-update.rootfs-overlay
KEY=$OVERLAY/usr/share/brewberrypi/keys/app-cosign.pub
TLS=()
while [ $# -gt 0 ]; do
   case $1 in
      --repo) REPO=$2; shift 2 ;;
      --key) KEY=$2; shift 2 ;;
      --insecure) TLS=(--src-tls-verify=false); shift ;;
      *) usage ;;
   esac
done
# App versions (runtime contract §1): 1.2.3, or a pre-release 1.2.3-alpha.N, -beta.N, -rc.N.
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "not an app version: $VERSION" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$(dirname "$DEST")"
DEST=$(realpath -m "$DEST")
rm -rf "$DEST"

mkdir -p "$T/registries.d"
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$REPO" > "$T/registries.d/fetch.yaml"
skopeo copy --quiet --override-os linux --override-arch arm64 --registries.d "$T/registries.d" "${TLS[@]}" \
   "docker://$REPO:$VERSION" "dir:$DEST"

fail() { echo "fetch-app: $*; not using $REPO:$VERSION" >&2; rm -rf "$DEST"; exit 1; }

# The device's signature rule for registry images, as a 'dir:' rule for this
# path, repository and key.
jq --arg path "$(dirname "$DEST")" --arg repo "$REPO" --arg key "$(realpath "$KEY")" '
   {default: [{type: "reject"}],
    transports: {dir: {($path): [.transports.docker["ghcr.io/tinkerius/brewberrypi-app"][0]
       | .keyPath = $key | .signedIdentity = {type: "exactRepository", dockerRepository: $repo}]}}}
' "$OVERLAY/etc/containers/policy.json" > "$T/policy.json"
skopeo copy --quiet --policy "$T/policy.json" "dir:$DEST" "dir:$T/verify" > /dev/null 2>&1 ||
   fail "the signature does not verify against the pinned key"

skopeo inspect --config "dir:$DEST" > "$T/config.json" || fail "cannot read the image configuration"
arch=$(jq -r '.architecture' "$T/config.json")
contract=$(jq -r '.config.Labels["org.brewberrypi.runtime-contract"] // empty' "$T/config.json")
version=$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' "$T/config.json")
[ "$arch" = arm64 ] || fail "architecture is '$arch', not arm64"
[ "$contract" = "$CONTRACT" ] || fail "runtime contract label is '$contract', not $CONTRACT"
[ "$version" = "$VERSION" ] || fail "version label is '$version', not $VERSION"
echo "fetched $REPO:$VERSION (arm64, contract $CONTRACT, signature verified) to $DEST"
