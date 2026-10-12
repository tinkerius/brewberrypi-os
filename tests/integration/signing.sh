#!/bin/bash
# shellcheck disable=SC2317  # cleanup() runs from the EXIT trap
# Signature policy test with real tools: a local registry, cosign v2 and the
# device's policy.json and registries.d (registry host and key path rewritten
# to the test setup). A correctly signed image must be accepted; unsigned,
# wrongly signed and other-repository images must be rejected.
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

# The device's files, pointed at the test registry and key.
sed -e "s|ghcr.io/tinkerius/brewberrypi|$REG/tinkerius/brewberrypi|" \
    -e "s|/usr/share/brewberrypi/keys/app-cosign.pub|$T/good.pub|" \
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
exit "$failures"
