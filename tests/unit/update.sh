#!/bin/bash
# Tests for brewberry-update and brewberrypi-safemode with fake podman and
# systemctl: install with soak and rollback, signature or contract rejection,
# configuration errors, rollback, garbage collection that keeps :previous, and
# safe mode switching exactly once. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SBIN=$ROOT_DIR/layer/brewberry-update.rootfs-overlay/usr/local/sbin
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export FAKE=$T/fake
export BREWBERRY_UPDATE_ROOT=$T/root BREWBERRY_SOAK_S=0
mkdir -p "$T/bin"

# --- fake podman: images, tags and labels as files under $FAKE ---------------
cat > "$T/bin/podman" <<'FAKE'
#!/bin/bash
set -u
key() { echo "$1" | tr '/:' '__'; }
resolve() { # <ref|id> -> id
   if [ -f "$FAKE/tags/$(key "$1")" ]; then cat "$FAKE/tags/$(key "$1")"
   elif [ -f "$FAKE/images/$1" ]; then echo "$1"
   else return 1; fi
}
case "$1 ${2:-}" in
   "image inspect")
      id=$(resolve "$5") || exit 125
      case $4 in
         '{{.Id}}') echo "$id" ;;
         *) l=$(echo "$4" | sed 's/.*Labels "\([^"]*\)".*/\1/'); sed -n "s/^$l=//p" "$FAKE/labels/$id" ;;
      esac ;;
   "pull -q")
      if [ "${3#dir:}" != "$3" ]; then
         [ -f "${3#dir:}/fake-id" ] || { echo "rejected by policy" >&2; exit 125; }
         id=$(cat "${3#dir:}/fake-id"); touch "$FAKE/images/$id"; echo "$id"; exit 0
      fi
      tag=${3##*:}
      [ -f "$FAKE/registry/$tag" ] || { echo "rejected by policy" >&2; exit 125; }
      id=$(cat "$FAKE/registry/$tag"); touch "$FAKE/images/$id"
      echo "$id" > "$FAKE/tags/$(key "$3")"; echo "$id" ;;
   "untag "*) [ "$(resolve "$3" 2>/dev/null)" = "$(cat "$FAKE/tags/$(key "$3")" 2>/dev/null)" ] || true
      f=$FAKE/tags/$(key "$3"); [ -f "$f" ] && [ "$(cat "$f")" = "$2" ] && rm "$f"; exit 0 ;;
   "tag "*) id=$(resolve "$2") || exit 125; echo "$id" > "$FAKE/tags/$(key "$3")" ;;
   "images -q") for f in "$FAKE"/images/*; do [ -e "$f" ] && echo "sha256:${f##*/}"; done ;;
   "rmi -f") id=$4; rm -f "$FAKE/images/$id"; grep -lx "$id" "$FAKE"/tags/* 2>/dev/null | xargs -r rm -f
      echo "rmi $id" >> "$FAKE/log" ;;
   "image prune") ;;
   *) echo "fake podman: unsupported: $*" >&2; exit 99 ;;
esac
FAKE

# --- fake systemctl: behaviour chosen by the active image ---------------------
cat > "$T/bin/systemctl" <<'FAKE'
#!/bin/bash
set -u
active_id() { cat "$FAKE/tags/localhost_brewberrypi_active" 2>/dev/null; }
behaviour() { cat "$FAKE/behave/$(active_id)" 2>/dev/null || echo ok; }
s() { cat "$FAKE/sys/$1" 2>/dev/null || echo "$2"; }
case "$*" in
   "reset-failed brewberrypi.service") ;;
   "restart brewberrypi.service")
      echo "restart $(active_id)" >> "$FAKE/log"
      echo 0 > "$FAKE/sys/nrestarts"; echo 0 > "$FAKE/sys/shows"
      case $(behaviour) in
         ok | crashlater) echo active > "$FAKE/sys/state"; echo 0 > "$FAKE/sys/status" ;;
         crash) echo failed > "$FAKE/sys/state"; echo 1 > "$FAKE/sys/status"; exit 1 ;;
         config) echo failed > "$FAKE/sys/state"; echo 2 > "$FAKE/sys/status"; exit 1 ;;
      esac ;;
   "show -p NRestarts --value brewberrypi.service")
      # crashlater: restarts once during the soak (second query sees it).
      n=$(( $(s shows 0) + 1 )); echo "$n" > "$FAKE/sys/shows"
      if [ "$(behaviour)" = crashlater ] && [ "$n" -ge 2 ]; then echo 1; else s nrestarts 0; fi ;;
   "show -p ExecMainStatus --value brewberrypi.service") s status 0 ;;
   # crashlater: systemd restarted it, so it looks active; only NRestarts shows it.
   "is-active --quiet brewberrypi.service") [ "$(s state active)" = active ] ;;
   "is-active brewberrypi.service") s state active ;;
   "--no-block start brewberrypi.service") echo "start $(active_id)" >> "$FAKE/log" ;;
   *) echo "fake systemctl: unsupported: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$T/bin/podman" "$T/bin/systemctl"
export PATH=$T/bin:$PATH

# --- fixture ------------------------------------------------------------------
# A registry with signed versions; behaviour per image; the device starts with
# 1.0.0 active and nothing previous.
fixture() {
   rm -rf "$FAKE" "$BREWBERRY_UPDATE_ROOT"
   mkdir -p "$FAKE"/{tags,images,labels,registry,behave,sys} "$BREWBERRY_UPDATE_ROOT"/{data/secrets,run}
   echo token > "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"
   : > "$FAKE/log"
   local v id behave contract labelled
   while read -r v id behave contract labelled; do
      printf 'org.opencontainers.image.version=%s\norg.brewberrypi.runtime-contract=%s\n' "${labelled:-$v}" "$contract" > "$FAKE/labels/$id"
      echo "$behave" > "$FAKE/behave/$id"
      [ "$v" = 1.0.0 ] || echo "$id" > "$FAKE/registry/$v"
   done <<'END'
1.0.0 id100 ok 1
1.1.0 id110 ok 1
1.2.0 id120 crash 1
1.3.0 id130 crashlater 1
1.5.0 id150 config 1
1.6.0 id160 ok 2
1.7.0 id170 ok 1
1.8.0 id180 ok 1 1.8.1
END
   touch "$FAKE/images/id100"
   echo id100 > "$FAKE/tags/localhost_brewberrypi_active"
}
tag_of() { cat "$FAKE/tags/localhost_brewberrypi_$1" 2>/dev/null || echo none; }
images() { find "$FAKE/images" -type f -printf '%f\n' | sort | paste -sd ' '; }
phase() { jq -r .phase "$BREWBERRY_UPDATE_ROOT/data/update/state.json"; }

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { # <cmd...> -> sets RC
   RC=0
   "$@" > "$T/out" 2>&1 || RC=$?
}
UPDATE=$SBIN/brewberry-update
SAFEMODE=$SBIN/brewberrypi-safemode

# --- brewberry-update ---------------------------------------------------------
fixture; run "$UPDATE" install 1.1.0
expect "install: exit code" "$RC" 0
expect "install: new image active, old one previous" "$(tag_of active) $(tag_of previous)" "id110 id100"
expect "install: state done" "$(phase)" "done"
expect "install: pulled ref untagged, nothing else kept" "$(images)" "id100 id110"

run "$UPDATE" install 1.7.0
expect "second install: previous moves up, oldest removed" "$(tag_of active) $(tag_of previous) | $(images)" "id170 id110 | id110 id170"

fixture; "$UPDATE" install 1.1.0 > /dev/null 2>&1; run "$UPDATE" install 1.2.0
expect "crash on start: exit code" "$RC" 1
expect "crash on start: rolled back, previous restored" "$(tag_of active) $(tag_of previous)" "id110 id100"
expect "crash on start: rejected image removed" "$(images)" "id100 id110"
expect "crash on start: state rolled-back" "$(phase)" rolled-back

fixture; run "$UPDATE" install 1.3.0
expect "crash during the soak: rolled back" "$RC $(tag_of active) $(tag_of previous) $(phase)" "1 id100 none rolled-back"

fixture; run "$UPDATE" install 1.4.0
expect "unsigned or missing version: nothing changed" "$RC $(tag_of active) $(tag_of previous) $(phase)" "1 id100 none failed"

fixture; run "$UPDATE" install 1.6.0
expect "wrong runtime contract: nothing changed, image removed" "$RC $(tag_of active) $(images) $(phase)" "1 id100 id100 failed"

fixture; run "$UPDATE" install 1.5.0
expect "configuration error: image kept, not rolled back" "$RC $(tag_of active) $(tag_of previous) $(phase)" "1 id150 id100 config-error"

fixture; run "$UPDATE" install 1.8.0
expect "version label differs from the tag: nothing changed" "$RC $(tag_of active) $(images) $(phase)" "1 id100 id100 failed"

fixture; mkdir -p "$T/stick/1.1.0"; echo '{}' > "$T/stick/1.1.0/manifest.json"; echo id110 > "$T/stick/1.1.0/fake-id"
rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"
run "$UPDATE" install 1.1.0 --from-dir "$T/stick/1.1.0"
expect "install from a dir: export (no registry token needed)" "$RC $(tag_of active) $(tag_of previous) $(phase)" "0 id110 id100 done"

fixture; mkdir -p "$T/stick/1.2.0"; echo '{}' > "$T/stick/1.2.0/manifest.json"
run "$UPDATE" install 1.2.0 --from-dir "$T/stick/1.2.0"
expect "dir: export rejected by policy: nothing changed" "$RC $(tag_of active) $(phase)" "1 id100 failed"

fixture; run "$UPDATE" install latest
expect "non-release tag refused before pulling" "$RC $(tag_of active) $(grep -c . "$FAKE/log")" "1 id100 0"

fixture; rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"; run "$UPDATE" install 1.1.0
expect "no registry token: refused" "$RC $(tag_of active)" "1 id100"

fixture; "$UPDATE" install 1.1.0 > /dev/null 2>&1; run "$UPDATE" install 1.1.0
expect "already active: nothing changed" "$RC $(tag_of active) $(tag_of previous) $(phase)" "0 id110 id100 done"

fixture; "$UPDATE" install 1.1.0 > /dev/null 2>&1; run "$UPDATE" rollback
expect "rollback: swapped" "$RC $(tag_of active) $(tag_of previous) $(phase)" "0 id100 id110 done"

fixture; run "$UPDATE" rollback
expect "rollback without previous: refused" "$RC $(tag_of active)" "1 id100"

fixture; exec 8> "$BREWBERRY_UPDATE_ROOT/run/brewberry-update.lock"; flock 8
run "$UPDATE" install 1.1.0; exec 8>&-
expect "second update while one runs: refused" "$RC $(tag_of active)" "1 id100"

# --- brewberrypi-safemode -----------------------------------------------------
# Device with 1.1.0 active and 1.0.0 previous, after the start limit was hit.
safemode_fixture() {
   fixture; "$UPDATE" install 1.1.0 > /dev/null 2>&1; : > "$FAKE/log"; echo "${1:-1}" > "$FAKE/sys/status"
}
safemode_fixture; run "$SAFEMODE"
expect "safe mode: switches to previous and starts" "$RC $(tag_of active) $(tag_of previous) $(cat "$FAKE/log")" "0 id100 id110 start id100"
run "$SAFEMODE"
expect "safe mode: previous fails too -> stays down" "$(tag_of active) $(tag_of previous) $(grep -c start "$FAKE/log")" "id100 id110 1"

safemode_fixture 2; run "$SAFEMODE"
expect "safe mode: configuration error never switches" "$(tag_of active) $(grep -c . "$FAKE/log")" "id110 0"

fixture; echo 1 > "$FAKE/sys/status"; run "$SAFEMODE"
expect "safe mode: no previous -> stays down" "$(tag_of active) $(grep -c . "$FAKE/log")" "id100 0"

safemode_fixture; exec 8> "$BREWBERRY_UPDATE_ROOT/run/brewberry-update.lock"; flock 8
run "$SAFEMODE"; exec 8>&-
expect "safe mode: leaves it to a running update" "$(tag_of active) $(grep -c . "$FAKE/log")" "id110 0"

safemode_fixture; "$SAFEMODE" > /dev/null; "$UPDATE" install 1.7.0 > /dev/null 2>&1
expect "a successful install clears the safe-mode marker" "$(test -f "$BREWBERRY_UPDATE_ROOT/data/update/safemode.json" && echo kept || echo cleared)" cleared

exit "$failures"
