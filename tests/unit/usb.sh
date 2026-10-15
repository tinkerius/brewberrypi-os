#!/bin/bash
# Tests for brewberry-usb with a stick directory (BREWBERRY_USB_DIR) and a fake
# brewberry-update: listing, install hand-over, and the config import (all
# files validated before anything is written, backup, boot-pin warning, the
# recipes/ folder replaced as a whole).
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
   mkdir -p "$T/stick/brewberrypi/images"/{1.2.0,1.10.0,1.10.0-alpha.2,1.10.0-alpha.10,1.10.0-rc.1,1.10.0-beta,not-a-version} \
      "$T/stick/brewberrypi/config/recipes/archive" "$BREWBERRY_UPDATE_ROOT/data/config/recipes"
   echo '{"hardware": {"heating": {"pin": 23}}}' > "$T/stick/brewberrypi/config/config.json"
   echo '{"name": "Zora", "goals": []}' > "$T/stick/brewberrypi/config/recipes/ZORA.json"
   echo '{"name": "Wit", "goals": []}' > "$T/stick/brewberrypi/config/recipes/WIT.json"
   echo 'notes' > "$T/stick/brewberrypi/config/recipes/README.txt"
   echo '{}' > "$T/stick/brewberrypi/config/recipes/archive/OLD.json"
   echo '{"old": true}' > "$BREWBERRY_UPDATE_ROOT/data/config/config.json"
   echo '{"name": "Old"}' > "$BREWBERRY_UPDATE_ROOT/data/config/recipes/HIPA.json"
   : > "$LOG"
}

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }
cfg() { jq -c . "$BREWBERRY_UPDATE_ROOT/data/config/$1" 2>/dev/null || echo missing; }
names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd ' '; } # entries of a folder

fixture; run "$USB" list
expect "list: versions newest first in SemVer order, config files" "$(grep '^  ' "$T/out" | tr -d ' ' | paste -sd ' ')" \
   "1.10.0 1.10.0-rc.1 1.10.0-alpha.10 1.10.0-alpha.2 1.2.0 config.json recipes/WIT.json recipes/ZORA.json"

fixture; run "$USB" install 1.2.0
expect "install: hands the export to brewberry-update" "$RC $(cat "$LOG")" \
   "0 brewberry-update install 1.2.0 --from-dir $T/stick/brewberrypi/images/1.2.0"

fixture; run "$USB" install 9.9.9
expect "install: missing version refused" "$RC $(grep -c . "$LOG")" "1 0"

fixture; run "$USB" import-config
expect "import: files copied" "$RC $(cfg config.json) $(cfg recipes/ZORA.json)" '0 {"hardware":{"heating":{"pin":23}}} {"name":"Zora","goals":[]}'
expect "import: recipes/ replaced as a whole, only <id>.json files" "$(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" "WIT.json ZORA.json"
expect "import: previous config backed up" "$(cat "$BREWBERRY_UPDATE_ROOT"/data/config/backup/*/config.json)" '{"old": true}'
expect "import: previous recipes backed up" "$(names "$BREWBERRY_UPDATE_ROOT"/data/config/backup/*/recipes)" "HIPA.json"
expect "import: no staging folder left" "$(test -e "$BREWBERRY_UPDATE_ROOT/data/config/.recipes.new" && echo left || echo none)" none
expect "import: lists the imported recipes" "$(grep -c 'imported recipes: WIT ZORA' "$T/out")" 1
expect "import: no boot-pin warning for the default pins" "$(grep -c WARNING "$T/out" || true)" 0

fixture; mkdir -p "$BREWBERRY_UPDATE_ROOT/data/config/.recipes.new"; echo stale > "$BREWBERRY_UPDATE_ROOT/data/config/.recipes.new/STALE.json"
run "$USB" import-config
expect "import: a staging folder left by a power cut is discarded" "$RC $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" "0 WIT.json ZORA.json"

fixture; rm -r "$T/stick/brewberrypi/config/recipes"; run "$USB" import-config
expect "import: no recipes/ on the stick -> recipes kept" "$RC $(cfg config.json) $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" \
   '0 {"hardware":{"heating":{"pin":23}}} HIPA.json'

fixture; rm "$T/stick/brewberrypi/config/config.json"; run "$USB" import-config
expect "import: only recipes/ on the stick -> config.json kept" "$RC $(cfg config.json) $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" \
   '0 {"old":true} WIT.json ZORA.json'

fixture; rm -r "$BREWBERRY_UPDATE_ROOT/data/config/recipes"; run "$USB" import-config
expect "import: recipes/ created when the Pi had none" "$RC $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" "0 WIT.json ZORA.json"

fixture; echo '{"broken": ' > "$T/stick/brewberrypi/config/config.json"; run "$USB" import-config
expect "import: one invalid file -> nothing changed" "$RC $(cfg config.json) $(test -d "$BREWBERRY_UPDATE_ROOT/data/config/backup" && echo backup || echo nobackup)" \
   '1 {"old":true} nobackup'

fixture; echo '{"broken": ' > "$T/stick/brewberrypi/config/recipes/WIT.json"; run "$USB" import-config
expect "import: one invalid recipe -> nothing changed" "$RC $(cfg config.json) $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" \
   '1 {"old":true} HIPA.json'

fixture; echo '{}' > "$T/stick/brewberrypi/config/recipes/my.recipe.json"; run "$USB" import-config
expect "import: recipe file name that is no recipe id refused" "$RC $(cfg config.json) $(grep -c 'recipes/my.recipe.json: file names' "$T/out")" '1 {"old":true} 1'

fixture; rm "$T/stick/brewberrypi/config/recipes/"*.json; run "$USB" import-config
expect "import: empty recipes/ refused (would leave no recipes)" "$RC $(names "$BREWBERRY_UPDATE_ROOT/data/config/recipes")" '1 HIPA.json'

fixture; echo '{}' > "$T/stick/brewberrypi/config/bad name.json"; run "$USB" import-config
expect "import: unsafe file name refused" "$RC $(cfg config.json)" '1 {"old":true}'

fixture; echo '{"hardware": {"heating": {"pin": 24}}}' > "$T/stick/brewberrypi/config/config.json"; run "$USB" import-config
expect "import: warns when the heater leaves the boot-time pin" "$RC $(grep -c 'heating is on BCM 24' "$T/out")" "0 1"

fixture; rm -r "$T/stick/brewberrypi/config"; run "$USB" import-config
expect "import: no config folder -> refused" "$RC $(cfg config.json)" '1 {"old":true}'

exit "$failures"
