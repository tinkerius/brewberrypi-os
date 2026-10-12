#!/bin/bash
# shellcheck disable=SC2317  # cleanup() runs from the EXIT trap
# Signature policy test with real tools: a local registry, cosign v2 and the
# device's policy.json and registries.d (registry host and key path rewritten
# to the test setup). A correctly signed image must be accepted; unsigned,
# wrongly signed and other-repository images must be rejected, from the
# registry, from a USB 'dir:' export (tampered exports too) and as the
# build-time preload (scripts/fetch-app.sh).
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
push tinkerius/brewberrypi:1.0.0 good
push tinkerius/brewberrypi:1.0.1
push tinkerius/brewberrypi:1.0.2 other
push tinkerius/elsewhere:1.0.0 good

# App releases for scripts/fetch-app.sh: arm64 with the app's labels. No RUN
# step, so building for arm64 needs no emulation.
push_app() { # <tag> <signing key prefix|-> <contract label> <version label>
   local ref=$REG/tinkerius/brewberrypi:$1 digest
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
push_app 2.0.0 good 1 2.0.0
push_app 2.0.1 - 1 2.0.1
push_app 2.0.2 other 1 2.0.2
push_app 2.0.3 good 2 2.0.3
push_app 2.0.4 good 1 9.9.9

# The device's files, pointed at the test registry and key.
mkdir "$T/stick"
sed -e "s|ghcr.io/tinkerius/brewberrypi|$REG/tinkerius/brewberrypi|" \
    -e "s|/usr/share/brewberrypi/keys/app-cosign.pub|$T/good.pub|" \
    -e "s|/media/brewberry-usb|$T/stick|" \
    "$OVERLAY/etc/containers/policy.json" > "$T/policy.json"
mkdir "$T/registries.d"
sed "s|ghcr.io/tinkerius/brewberrypi|$REG/tinkerius/brewberrypi|" \
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
expect "signed with the pinned key: accepted" accept tinkerius/brewberrypi:1.0.0
expect "unsigned: rejected" reject tinkerius/brewberrypi:1.0.1
expect "signed with another key: rejected" reject tinkerius/brewberrypi:1.0.2
expect "other repository, even if signed: rejected" reject tinkerius/elsewhere:1.0.0

# USB: 'dir:' exports as scripts/usb-export.sh writes them (skopeo copy --all).
export_dir() { # <repo:tag> <name>
   skopeo copy --quiet --all --registries.d "$T/registries.d" --src-tls-verify=false \
      "docker://$REG/$1" "dir:$T/stick/$2"
}
expect_dir() { # <description> <accept|reject> <dir>
   local got=reject
   if skopeo copy --quiet --policy "$T/policy.json" "dir:$3" "dir:$T/out-$RANDOM" > /dev/null 2>&1; then
      got=accept
   fi
   if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1: $got, want $2"; failures=1; fi
}
# registries.d for the elsewhere repository too, so its signature is copied.
sed "s|$REG/tinkerius/brewberrypi|$REG/tinkerius/elsewhere|" "$T/registries.d/brewberrypi.yaml" \
   > "$T/registries.d/elsewhere.yaml"
export_dir tinkerius/brewberrypi:1.0.0 good
export_dir tinkerius/brewberrypi:1.0.2 otherkey
export_dir tinkerius/elsewhere:1.0.0 elsewhere
cp -r "$T/stick/good" "$T/stick/tampered"
layer=$(jq -r '.layers[0].digest' "$T/stick/tampered/manifest.json" | cut -d: -f2)
printf 'X' | dd of="$T/stick/tampered/$layer" bs=1 seek=100 conv=notrunc 2> /dev/null
cp -r "$T/stick/good" "$T/stick/unsigned"
rm "$T/stick/unsigned"/signature-*
mkdir "$T/elsewhere-path" && cp -r "$T/stick/good" "$T/elsewhere-path/good"

# The rejections below must come from the key or identity, not a missing signature.
for d in good otherkey elsewhere; do
   if compgen -G "$T/stick/$d/signature-*" > /dev/null; then echo "ok    USB export '$d' carries its signature"
   else echo "FAIL  USB export '$d' has no signature"; failures=1; fi
done
expect_dir "USB export signed with the pinned key: accepted" accept "$T/stick/good"
expect_dir "USB export with a changed layer: rejected" reject "$T/stick/tampered"
expect_dir "USB export without its signature: rejected" reject "$T/stick/unsigned"
expect_dir "USB export signed with another key: rejected" reject "$T/stick/otherkey"
expect_dir "USB export of another repository: rejected" reject "$T/stick/elsewhere"
expect_dir "signed export outside the USB mount path: rejected" reject "$T/elsewhere-path/good"

# Build-time preload (OS8): only a signed arm64 release with the right labels.
expect_fetch() { # <description> <accept | words of the expected refusal> <x.y.z>
   local got dest=$T/preload/$3 err
   if err=$("$ROOT/scripts/fetch-app.sh" "$3" "$dest" --repo "$REG/tinkerius/brewberrypi" --key "$T/good.pub" \
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
expect_fetch "preload: other runtime contract: rejected" "runtime contract label is '2'" 2.0.3
expect_fetch "preload: version label differs from the tag: rejected" "version label is '9.9.9'" 2.0.4
expect_fetch "preload: not arm64: rejected" "not arm64" 1.0.0
exit "$failures"
