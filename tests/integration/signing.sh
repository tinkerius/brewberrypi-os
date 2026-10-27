#!/bin/bash
# shellcheck disable=SC2317  # cleanup() runs from the EXIT trap
# Signature policy test with real tools: a local registry, cosign v2 and the
# device's policy.json and registries.d (registry host and key path rewritten
# to the test setup). A correctly signed image must be accepted; unsigned,
# wrongly signed and other-repository images must be rejected, from the
# registry and as the build-time preload (scripts/fetch-app.sh). A 'dir:'
# export is accepted only from the preload folder.
#
# Usage: tests/integration/signing.sh   (needs podman, skopeo, jq and cosign v2
#        on PATH, and network access to mirror.gcr.io, Google's Docker Hub mirror, which has no
#        anonymous rate limit)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OVERLAY=$ROOT/layer/brewberry-update.rootfs-overlay
REG=127.0.0.1:5055
NAME=bb-test-registry
T=$(mktemp -d)
cleanup() { podman rm -f "$NAME" > /dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT

cosign version 2>&1 | grep -q 'GitVersion: *v2\.' || { echo "cosign v2.x required (v3's format is unreadable for Podman 5.4)" >&2; exit 1; }

podman run -d --quiet --rm --name "$NAME" -p "$REG:5000" mirror.gcr.io/library/registry:2 > /dev/null
for _ in $(seq 30); do curl -fsS "http://$REG/v2/" > /dev/null 2>&1 && break; sleep 1; done

export COSIGN_PASSWORD=""
(cd "$T" && cosign generate-key-pair --output-key-prefix good > /dev/null 2>&1 &&
   cosign generate-key-pair --output-key-prefix other > /dev/null 2>&1)

podman pull -q mirror.gcr.io/library/busybox:1.36 > /dev/null
push() { # <repo:tag> [signing key prefix]
   local ref=$REG/$1 digest
   # A distinct image per tag: a signature covers a digest, so tags sharing a
   # digest would share its signatures.
   printf 'FROM mirror.gcr.io/library/busybox:1.36\nLABEL test.ref="%s"\n' "$1" > "$T/Containerfile"
   podman build -q -t "$ref" -f "$T/Containerfile" "$T" > /dev/null
   podman push -q --tls-verify=false "$ref"
   if [ -n "${2:-}" ]; then
      digest=$(skopeo inspect --tls-verify=false "docker://$ref" | jq -r .Digest)
      cosign sign --yes --key "$T/$2.key" --tlog-upload=false --allow-insecure-registry \
         "${ref%:*}@$digest" > /dev/null 2>&1
   fi
}
push tinkerius/brewberrypi-app:1.0.0 good
push tinkerius/brewberrypi-app:1.0.1
push tinkerius/brewberrypi-app:1.0.2 other
push tinkerius/elsewhere:1.0.0 good

# App releases for scripts/fetch-app.sh: arm64 with the app's labels. No RUN
# step, so building for arm64 needs no emulation.
push_app() { # <tag> <signing key prefix|-> <contract label> <version label>
   local ref=$REG/tinkerius/brewberrypi-app:$1 digest
   printf 'FROM mirror.gcr.io/library/busybox:1.36\nLABEL org.brewberrypi.runtime-contract="%s" org.opencontainers.image.version="%s"\n' \
      "$3" "$4" > "$T/Containerfile"
   podman build -q --platform linux/arm64 -t "$ref" -f "$T/Containerfile" "$T" > /dev/null
   podman push -q --tls-verify=false "$ref"
   if [ "$2" != - ]; then
      digest=$(skopeo inspect --tls-verify=false "docker://$ref" | jq -r .Digest)
      cosign sign --yes --key "$T/$2.key" --tlog-upload=false --allow-insecure-registry \
         "${ref%:*}@$digest" > /dev/null 2>&1
   fi
}
push_app 2.0.0 good 2 2.0.0
push_app 2.0.1 - 2 2.0.1
push_app 2.0.2 other 2 2.0.2
push_app 2.0.3 good 1 2.0.3
push_app 2.0.4 good 2 9.9.9

# The device's files, pointed at the test registry and key.
sed -e "s|ghcr.io/tinkerius/brewberrypi-app|$REG/tinkerius/brewberrypi-app|" \
    -e "s|/usr/share/brewberrypi/keys/app-cosign.pub|$T/good.pub|" \
    "$OVERLAY/etc/containers/policy.json" > "$T/policy.json"
mkdir "$T/registries.d"
sed "s|ghcr.io/tinkerius/brewberrypi-app|$REG/tinkerius/brewberrypi-app|" \
    "$OVERLAY/etc/containers/registries.d/brewberrypi.yaml" > "$T/registries.d/brewberrypi.yaml"

failures=0
expect() { # <description> <accept|reject> <repo:tag>
   local got=reject
   if skopeo copy --quiet --policy "$T/policy.json" --registries.d "$T/registries.d" \
         --src-tls-verify=false "docker://$REG/$3" "dir:$T/out-${3//[:\/]/_}" > /dev/null 2>&1; then
      got=accept
   fi
   if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1: $got, want $2"; failures=1; fi
}
expect "signed with the pinned key: accepted" accept tinkerius/brewberrypi-app:1.0.0
expect "unsigned: rejected" reject tinkerius/brewberrypi-app:1.0.1
expect "signed with another key: rejected" reject tinkerius/brewberrypi-app:1.0.2
expect "other repository, even if signed: rejected" reject tinkerius/elsewhere:1.0.0

# 'dir:' exports (as podman save or skopeo write them): only the preload folder
# of the image is accepted, even with a valid signature.
skopeo copy --quiet --all --registries.d "$T/registries.d" --src-tls-verify=false \
   "docker://$REG/tinkerius/brewberrypi-app:1.0.0" "dir:$T/export"
if compgen -G "$T/export/signature-*" > /dev/null; then echo "ok    the 'dir:' export carries its signature"
else echo "FAIL  the 'dir:' export has no signature"; failures=1; fi
if skopeo copy --quiet --policy "$T/policy.json" "dir:$T/export" "dir:$T/out-export" > /dev/null 2>&1; then
   echo "FAIL  signed 'dir:' export outside the preload folder: accepted"; failures=1
else
   echo "ok    signed 'dir:' export outside the preload folder: rejected"
fi

# Build-time preload (OS8): only a signed arm64 release with the right labels.
expect_fetch() { # <description> <accept | words of the expected refusal> <x.y.z>
   local got dest=$T/preload/$3 err
   if err=$("$ROOT/scripts/fetch-app.sh" "$3" "$dest" --repo "$REG/tinkerius/brewberrypi-app" --key "$T/good.pub" \
         --insecure 2>&1 > /dev/null) && [ -f "$dest/manifest.json" ]; then
      got=accept
   elif [ -e "$dest" ]; then
      got="refused, but left $dest behind"
   elif [[ $err == *"$2"* ]]; then
      got=$2
   else
      got="refused with: ${err//$'\n'/ }"
   fi
   if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1: $got"; failures=1; fi
}
expect_fetch "preload: signed arm64 release: accepted" accept 2.0.0
expect_fetch "preload: unsigned: rejected" "signature does not verify" 2.0.1
expect_fetch "preload: signed with another key: rejected" "signature does not verify" 2.0.2
expect_fetch "preload: other runtime contract: rejected" "runtime contract label is '1'" 2.0.3
expect_fetch "preload: version label differs from the tag: rejected" "version label is '9.9.9'" 2.0.4
expect_fetch "preload: not arm64: rejected" "not arm64" 1.0.0
exit "$failures"
