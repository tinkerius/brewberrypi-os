#!/bin/bash
# Tests for brewberry-datalayout with a fake /data (BREWBERRY_DATA_ROOT) and a
# fake mountpoint: the directories, among them the share's root config with its
# folders app and os (set-group-ID, BREWBERRY_CONFIG_OWNER), are created once,
# nothing is seeded into app (the app writes its own files), existing files
# are never touched, and a healthy /data is not written to. Run by
# scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
LAYOUT=$ROOT_DIR/layer/brewberry-readonly.rootfs-overlay/usr/local/sbin/brewberry-datalayout
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_DATA_ROOT=$T/data
BREWBERRY_CONFIG_OWNER=$(id -un):$(id -gn)
export BREWBERRY_CONFIG_OWNER

mkdir -p "$T/bin"
# shellcheck disable=SC2016  # $MOUNTED belongs to the fake script
printf '#!/bin/sh\nexec test -n "$MOUNTED"\n' > "$T/bin/mountpoint"
chmod +x "$T/bin/mountpoint"
export PATH=$T/bin:$PATH

failures=0
check() { # <description> <command...>
   local what=$1
   shift
   if "$@" > /dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; failures=1; fi
}
mode() { stat -c %a "$1"; }

mkdir -p "$BREWBERRY_DATA_ROOT"
# shellcheck disable=SC2317  # called through check()
unmounted() { ! MOUNTED='' "$LAYOUT"; }
check "/data not mounted: refused" unmounted
check "/data not mounted: nothing created" test ! -e "$BREWBERRY_DATA_ROOT/config"

export MOUNTED=1
"$LAYOUT" > "$T/first.log"
for d in config containers/storage tmp update; do
   check "creates $d (0755)" test "$(mode "$BREWBERRY_DATA_ROOT/$d")" = 755
done
for d in app os; do
   check "creates config/$d (2775, set-group-ID)" test "$(mode "$BREWBERRY_DATA_ROOT/config/$d")" = 2775
   check "config/$d belongs to the share's user and group" \
      test "$(stat -c %U:%G "$BREWBERRY_DATA_ROOT/config/$d")" = "$BREWBERRY_CONFIG_OWNER"
done
check "creates secrets (0700)" test "$(mode "$BREWBERRY_DATA_ROOT/secrets")" = 700
check "seeds nothing in config/app (the app writes config.json and recipes/)" \
   test -z "$(ls -A "$BREWBERRY_DATA_ROOT/config/app")"

CONF=$ROOT_DIR/layer/brewberry-podman.rootfs-overlay/etc/containers/containers.conf.d/50-brewberry.conf
tmpdir=$(sed -n 's/^image_copy_tmp_dir *= *"\(.*\)"/\1/p' "$CONF")
check "Podman's image_copy_tmp_dir ($tmpdir) is a directory the layout creates" \
   test -d "$BREWBERRY_DATA_ROOT${tmpdir#/data}" -a "${tmpdir#/data/}" != "$tmpdir"

"$LAYOUT" > "$T/second.log"
check "second run: nothing to do, nothing written" test ! -s "$T/second.log"

echo '{"hardware": {"heating": {"pin": 17}}}' > "$BREWBERRY_DATA_ROOT/config/app/config.json"
"$LAYOUT" > /dev/null
check "existing config.json is kept" \
   test "$(jq -r .hardware.heating.pin "$BREWBERRY_DATA_ROOT/config/app/config.json")" = 17

rm -r "$BREWBERRY_DATA_ROOT/config/os" "$BREWBERRY_DATA_ROOT/tmp"
"$LAYOUT" > "$T/third.log"
check "missing config/os is created again" test "$(mode "$BREWBERRY_DATA_ROOT/config/os")" = 2775
check "missing directory is created again" test -d "$BREWBERRY_DATA_ROOT/tmp"

exit "$failures"
