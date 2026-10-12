#!/bin/bash
# Tests for brewberry-datalayout with a fake /data (BREWBERRY_DATA_ROOT) and a
# fake mountpoint: the directories and the seed config.json ({} = the app's
# built-in defaults) are created once, an existing config is never touched,
# and a healthy /data is not written to. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
LAYOUT=$ROOT_DIR/layer/brewberry-readonly.rootfs-overlay/usr/local/sbin/brewberry-datalayout
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_DATA_ROOT=$T/data

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
check "creates secrets (0700)" test "$(mode "$BREWBERRY_DATA_ROOT/secrets")" = 700
check "seeds config.json with {} (built-in defaults)" \
   test "$(jq -c . "$BREWBERRY_DATA_ROOT/config/config.json")" = '{}'
check "config.json is readable by the app (0644)" test "$(mode "$BREWBERRY_DATA_ROOT/config/config.json")" = 644
check "no temporary file left" test ! -e "$BREWBERRY_DATA_ROOT/config/config.json.tmp"

"$LAYOUT" > "$T/second.log"
check "second run: nothing to do, nothing written" test ! -s "$T/second.log"

echo '{"hardware": {"heating": {"pin": 17}}}' > "$BREWBERRY_DATA_ROOT/config/config.json"
"$LAYOUT" > /dev/null
check "existing config.json is kept" \
   test "$(jq -r .hardware.heating.pin "$BREWBERRY_DATA_ROOT/config/config.json")" = 17

rm "$BREWBERRY_DATA_ROOT/config/config.json"
rm -r "$BREWBERRY_DATA_ROOT/tmp"
"$LAYOUT" > "$T/third.log"
check "missing config.json is seeded again" test -f "$BREWBERRY_DATA_ROOT/config/config.json"
check "missing directory is created again" test -d "$BREWBERRY_DATA_ROOT/tmp"

exit "$failures"
