#!/bin/bash
# Tests for brewberry-config (ADR-0002, OS9): show, import from a folder, a
# single .json file or an export archive (checked before anything is written,
# no links or paths outside the archive; backups in os/backup, all recipes
# replaced in place), and export of the app folder /data/config/app. Run by
# scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG=$ROOT_DIR/layer/brewberry-update.rootfs-overlay/usr/local/sbin/brewberry-config
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_UPDATE_ROOT=$T/root
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
D=$BREWBERRY_UPDATE_ROOT/data/config/app
B=$BREWBERRY_UPDATE_ROOT/data/config/os/backup

fixture() {
   rm -rf "$BREWBERRY_UPDATE_ROOT" "$T/src"
   mkdir -p "$D/recipes" "${B%/*}" "$BREWBERRY_UPDATE_ROOT/data/tmp" "$T/src/recipes"
   echo '{"server": {"port": 8080}}' > "$D/config.json"
   echo '{"name": "Old"}' > "$D/recipes/HIPA.json"
   echo '{"hardware": {"pump": {"pin": 22}}}' > "$T/src/config.json"
   echo '{"name": "Wit"}' > "$T/src/recipes/WIT.json"
}

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }
cfg() { jq -c . "$D/$1" 2>/dev/null || echo missing; }
names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd ' '; }
leftovers() { find "$BREWBERRY_UPDATE_ROOT/data/tmp" -mindepth 1 | wc -l; }

fixture
expect "show --json" "$("$CONFIG" show --json | jq -c '[.config.server.port, .files, .recipes]')" '[8080,["config.json"],["HIPA"]]'
rm -r "$D/recipes" "$D/config.json"
expect "show --json before the app's first start" "$("$CONFIG" show --json | jq -c '[.config, .files, .recipes]')" '[null,[],null]'
expect "show: the app creates recipes/ at its next start" "$("$CONFIG" show | tail -n 1)" \
   "recipes: none yet (the app creates recipes/ with its shipped recipes at its next start)"

fixture; echo '{"old": true}' > "$D/config.json"; echo '{}' > "$D/recipes/._HIPA.json"; echo '{}' > "$T/src/recipes/._WIT.json"
run "$CONFIG" import "$T/src"
expect "import: recipes replaced as a whole, hidden files not imported" "$(names "$D/recipes")" "._HIPA.json WIT.json"
expect "import: previous config backed up in os/backup" "$(cat "$B"/*/config.json)" '{"old": true}'
expect "import: previous recipes backed up" "$(names "$B"/*/recipes)" "HIPA.json"
expect "import: group-writable files, no temporary files" \
   "$(stat -c %a "$D/config.json" "$D/recipes/WIT.json" | paste -sd ' ') $(find "$D" -name '*.tmp' | wc -l)" "664 664 0"
expect "import: recipes need no restart, config.json does" \
   "$(grep -c 'new recipes within a few seconds' "$T/out") $(grep -c 'brewberry-update restart' "$T/out")" "1 1"

fixture; rm -r "$D/recipes"; run "$CONFIG" import "$T/src/recipes/WIT.json"
expect "import a recipe file as config file: no recipes/ created" "$RC $(test -d "$D/recipes" && echo created || echo none)" "0 none"

fixture; rm -r "$D/recipes" "$T/src/config.json"; run "$CONFIG" import "$T/src"
expect "import: recipes/ created when the Pi had none, no restart needed" \
   "$RC $(names "$D/recipes") $(stat -c %a "$D/recipes") $(grep -c 'brewberry-update restart' "$T/out")" "0 WIT.json 2775 0"

fixture; echo '{"broken": ' > "$T/src/recipes/WIT.json"; run "$CONFIG" import "$T/src"
expect "import: one invalid recipe -> nothing changed" "$RC $(cfg config.json) $(names "$D/recipes") $(test -d "$B" && echo backup || echo none)" \
   '1 {"server":{"port":8080}} HIPA.json none'

fixture; run "$CONFIG" import "$T/src"
expect "import a folder" "$RC $(cfg config.json) $(names "$D/recipes")" '0 {"hardware":{"pump":{"pin":22}}} WIT.json'

fixture; echo '{"a": 1}' > "$T/single.json"; run "$CONFIG" import "$T/single.json"
expect "import one .json file: added, recipes kept, work folder removed" \
   "$RC $(cfg single.json) $(cfg config.json) $(names "$D/recipes") $(leftovers)" '0 {"a":1} {"server":{"port":8080}} HIPA.json 0'

fixture; echo '{"broken": ' > "$T/config.json"; run "$CONFIG" import "$T/config.json"
expect "import an invalid .json file: nothing changed" "$RC $(cfg config.json) $(leftovers)" '1 {"server":{"port":8080}} 0'

fixture; "$CONFIG" export > "$T/export.tar.gz"
expect "export: config files and recipes" "$(tar -tzf "$T/export.tar.gz" | sort | paste -sd ' ')" "config.json recipes/HIPA.json"
echo '{"changed": true}' > "$D/config.json"; rm "$D/recipes/HIPA.json"
run "$CONFIG" import "$T/export.tar.gz"
expect "import an export: restores it" "$RC $(cfg config.json) $(names "$D/recipes") $(leftovers)" '0 {"server":{"port":8080}} HIPA.json 0'

fixture; python3 - "$T/evil.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name in ("config.json", "/etc/evil.json"):
        info = tarfile.TarInfo(name); info.size = 2
        t.addfile(info, io.BytesIO(b"{}"))
PY
run "$CONFIG" import "$T/evil.tar.gz"
expect "archive with an absolute path: refused, nothing changed" "$RC $(cfg config.json)" '1 {"server":{"port":8080}}'

fixture; python3 - "$T/dots.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    data = b"{}"
    info = tarfile.TarInfo("../config.json"); info.size = len(data)
    t.addfile(info, io.BytesIO(data))
PY
run "$CONFIG" import "$T/dots.tar.gz"
expect "archive with ../: refused" "$RC $(cfg config.json)" '1 {"server":{"port":8080}}'

fixture; ln -s /etc/passwd "$T/src/link.json"; (cd "$T/src" && tar -czf "$T/link.tar.gz" config.json link.json)
run "$CONFIG" import "$T/link.tar.gz"
expect "archive with a link: refused" "$RC $(cfg config.json) $(test -e "$D/link.json" && echo imported || echo none)" '1 {"server":{"port":8080}} none'

fixture; run "$CONFIG" import "$T/src/recipes/WIT.txt"
expect "import a missing file: refused" "$RC" 1
fixture; echo x > "$T/notes.txt"; run "$CONFIG" import "$T/notes.txt"
expect "import another file type: refused" "$RC $(grep -c 'import a folder, a .json file or a .tar.gz' "$T/out")" "1 1"

# The folders belong to brewberry on the Pi (the file share, ADR-0003).
if [ "$(id -u)" = 0 ]; then
   fixture; chown -R 65534:65534 "$D" "${B%/*}"; run "$CONFIG" import "$T/src"
   expect "import: written files and backups belong to the folders' owners" \
      "$RC $(find "$D" "$B" \( ! -user 65534 -o ! -group 65534 \) | wc -l) $(find "$B" -name HIPA.json | wc -l)" "0 0 1"
else
   echo "skip  import: owners (needs root)"
fi

exit "$failures"
