#!/bin/bash
# Tests for brewberry-usb with a stick directory (BREWBERRY_USB_DIR) and a fake
# brewberry-update: listing, install hand-over, and the config import (all
# files validated before anything is written, backup, boot-pin warning).
# Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
USB=$ROOT_DIR/layer/brewberry-update.rootfs-overlay/usr/local/sbin/brewberry-usb
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_UPDATE_ROOT=$T/root BREWBERRY_USB_DIR=$T/stick

mkdir -p "$T/bin"
cat > "$T/bin/brewberry-update" <<'FAKE'
#!/bin/sh
echo "brewberry-update $*" >> "$LOG"
FAKE
chmod +x "$T/bin/brewberry-update"
export PATH=$T/bin:$PATH LOG=$T/log

fixture() {
   rm -rf "$T/stick" "$BREWBERRY_UPDATE_ROOT"
   mkdir -p "$T/stick/brewberrypi/images"/{1.2.0,1.10.0,1.10.0-alpha.2,1.10.0-alpha.10,1.10.0-rc.1,1.10.0-beta,not-a-version} "$T/stick/brewberrypi/config" \
      "$BREWBERRY_UPDATE_ROOT/data/config"
   echo '{"hardware": {"heating": {"pin": 23}}}' > "$T/stick/brewberrypi/config/config.json"
   echo '[]' > "$T/stick/brewberrypi/config/recipes.json"
   echo '{"old": true}' > "$BREWBERRY_UPDATE_ROOT/data/config/config.json"
   : > "$LOG"
}

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }
cfg() { jq -c . "$BREWBERRY_UPDATE_ROOT/data/config/$1" 2>/dev/null || echo missing; }

fixture; run "$USB" list
expect "list: versions newest first in SemVer order, config files" "$(grep '^  ' "$T/out" | tr -d ' ' | paste -sd ' ')" \
   "1.10.0 1.10.0-rc.1 1.10.0-alpha.10 1.10.0-alpha.2 1.2.0 config.json recipes.json"

fixture; run "$USB" install 1.2.0
expect "install: hands the export to brewberry-update" "$RC $(cat "$LOG")" \
   "0 brewberry-update install 1.2.0 --from-dir $T/stick/brewberrypi/images/1.2.0"

fixture; run "$USB" install 9.9.9
expect "install: missing version refused" "$RC $(grep -c . "$LOG")" "1 0"

fixture; run "$USB" import-config
expect "import: files copied" "$RC $(cfg config.json) $(cfg recipes.json)" '0 {"hardware":{"heating":{"pin":23}}} []'
expect "import: previous config backed up" "$(cat "$BREWBERRY_UPDATE_ROOT"/data/config/backup/*/config.json)" '{"old": true}'
expect "import: no boot-pin warning for the default pins" "$(grep -c WARNING "$T/out" || true)" 0

fixture; echo '{"broken": ' > "$T/stick/brewberrypi/config/recipes.json"; run "$USB" import-config
expect "import: one invalid file -> nothing changed" "$RC $(cfg config.json) $(test -d "$BREWBERRY_UPDATE_ROOT/data/config/backup" && echo backup || echo nobackup)" \
   '1 {"old":true} nobackup'

fixture; echo '{}' > "$T/stick/brewberrypi/config/bad name.json"; run "$USB" import-config
expect "import: unsafe file name refused" "$RC $(cfg config.json)" '1 {"old":true}'

fixture; echo '{"hardware": {"heating": {"pin": 24}}}' > "$T/stick/brewberrypi/config/config.json"; run "$USB" import-config
expect "import: warns when the heater leaves the boot-time pin" "$RC $(grep -c 'heating is on BCM 24' "$T/out")" "0 1"

fixture; rm -r "$T/stick/brewberrypi/config"; run "$USB" import-config
expect "import: no config folder -> refused" "$RC $(cfg config.json)" '1 {"old":true}'

exit "$failures"
