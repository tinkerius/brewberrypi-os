#!/bin/bash
# Tests for brewberry-update and brewberrypi-safemode with fake podman and
# systemctl: download with signature or contract rejection, install of a
# downloaded version with soak and rollback, removing downloads, configuration
# errors, rollback, garbage collection that keeps :previous and the downloads,
# the list of the registry's and the Pi's versions, a public or a private
# registry, the update in status, brewberry-update-check (the update check and
# the first install while no app is installed), and safe mode switching
# exactly once. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SBIN=$ROOT_DIR/layer/brewberry-update.rootfs-overlay/usr/local/sbin
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export FAKE=$T/fake
export BREWBERRY_UPDATE_ROOT=$T/root BREWBERRY_SOAK_S=0
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
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
         '{{.Size}}') echo 250000000 ;;
         *) l=$(echo "$4" | sed 's/.*Labels "\([^"]*\)".*/\1/'); sed -n "s/^$l=//p" "$FAKE/labels/$id" ;;
      esac ;;
   "pull -q")
      tag=${3##*:}
      # A private registry ($FAKE/private) refuses requests without a token.
      [ ! -e "$FAKE/private" ] || [ -n "${REGISTRY_AUTH_FILE:-}" ] ||
         { echo "Error: reading manifest $tag: unauthorized: authentication required" >&2; exit 125; }
      [ -f "$FAKE/registry/$tag" ] || { echo "rejected by policy" >&2; exit 125; }
      id=$(cat "$FAKE/registry/$tag"); touch "$FAKE/images/$id"
      echo "$id" > "$FAKE/tags/$(key "$3")"; echo "$id" ;;
   "untag "*) [ "$(resolve "$3" 2>/dev/null)" = "$(cat "$FAKE/tags/$(key "$3")" 2>/dev/null)" ] || true
      f=$FAKE/tags/$(key "$3"); [ -f "$f" ] && [ "$(cat "$f")" = "$2" ] && rm "$f"; exit 0 ;;
   "tag "*) id=$(resolve "$2") || exit 125; echo "$id" > "$FAKE/tags/$(key "$3")" ;;
   "images -q") for f in "$FAKE"/images/*; do [ -e "$f" ] && echo "sha256:${f##*/}"; done ;;
   "images --noheading") # --format {{.Tag}} localhost/brewberrypi
      for f in "$FAKE"/tags/localhost_brewberrypi_*; do [ -e "$f" ] && echo "${f##*/localhost_brewberrypi_}"; done ;;
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
# --- fake skopeo: the registry's tags plus a signature tag ---------------------
cat > "$T/bin/skopeo" <<'FAKE'
#!/bin/bash
set -u
[ "$1" = --command-timeout ] && shift 2
[ "$1" = list-tags ] || { echo "fake skopeo: unsupported: $*" >&2; exit 99; }
echo "list-tags auth=${REGISTRY_AUTH_FILE:+token}" >> "$FAKE/skopeo.log"
[ ! -e "$FAKE/offline" ] || { echo "pinging container registry: dial tcp: no route to host" >&2; exit 1; }
[ ! -e "$FAKE/private" ] || [ -n "${REGISTRY_AUTH_FILE:-}" ] ||
   { echo "FATA[0000] Error listing repository tags: unauthorized: authentication required" >&2; exit 1; }
{ ls "$FAKE/registry"; echo sha256-0123.sig; echo latest; } | jq -R . | jq -sc '{Tags: .}'
FAKE
# --- fake curl: the app's /healthz reports $FAKE/engine (none: not answering) --
cat > "$T/bin/curl" <<'FAKE'
#!/bin/bash
set -u
[ -f "$FAKE/engine" ] || exit 7
printf '{"status": "ok", "version": "1.0.0", "engine": "%s"}\n' "$(cat "$FAKE/engine")"
FAKE
chmod +x "$T/bin/podman" "$T/bin/systemctl" "$T/bin/skopeo" "$T/bin/curl"
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
1.0.0 id100 ok 2
1.1.0 id110 ok 2
1.2.0 id120 crash 2
1.3.0 id130 crashlater 2
1.5.0 id150 config 2
1.6.0 id160 ok 1
1.7.0 id170 ok 2
1.8.0 id180 ok 2 1.8.1
1.9.0-alpha.2 id192 ok 2
1.9.0-alpha.10 id193 ok 2
1.9.0-rc.1 id194 ok 2
1.9.0 id190 ok 2
END
   touch "$FAKE/images/id100"
   echo id100 > "$FAKE/tags/localhost_brewberrypi_active"
}
tag_of() { cat "$FAKE/tags/localhost_brewberrypi_$1" 2>/dev/null || echo none; }
dl() { "$UPDATE" download "$1" > /dev/null 2>&1; } # <version>
inst() { dl "$1"; "$UPDATE" --yes install "$1" > /dev/null 2>&1; } # <version>
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
fixture; run "$UPDATE" download 1.1.0
expect "download: exit code, kept as localhost/brewberrypi:<version>" "$RC $(tag_of 1.1.0)" "0 id110"
expect "download: nothing switches, registry ref untagged" "$(tag_of active) $(tag_of previous) $(images) $(phase)" "id100 none id100 id110 downloaded"
run "$UPDATE" download 1.1.0
expect "download twice: already downloaded" "$RC $(grep -c 'already downloaded' "$T/out")" "0 1"
run "$UPDATE" --yes install 1.1.0
expect "install: exit code" "$RC" 0
expect "install: new image active, old one previous" "$(tag_of active) $(tag_of previous)" "id110 id100"
expect "install: state done" "$(phase)" "done"
expect "install: the download stays, nothing else kept" "$(images) $(tag_of 1.1.0)" "id100 id110 id110"

dl 1.7.0; run "$UPDATE" --yes install 1.7.0
expect "second install: previous moves up, the old previous goes" "$(tag_of active) $(tag_of previous) | $(images)" "id170 id110 | id110 id170"

fixture; run "$UPDATE" --yes install 1.1.0
expect "install of a version not on the Pi: refused, says to download" "$RC $(tag_of active) $(grep -c 'download it first' "$T/out")" "1 id100 1"

fixture; dl 1.1.0; dl 1.7.0
expect "two downloads kept, nothing switched" "$(images) $(tag_of active)" "id100 id110 id170 id100"
run "$UPDATE" remove 1.7.0
expect "remove: the download is gone, the rest stays" "$RC $(images) $(tag_of 1.7.0)" "0 id100 id110 none"
run "$UPDATE" remove 1.7.0
expect "remove: not downloaded" "$RC $(grep -c 'not downloaded' "$T/out")" "1 1"
"$UPDATE" --yes install 1.1.0 > /dev/null 2>&1
run "$UPDATE" remove 1.1.0
expect "remove: never the active version" "$RC $(images) $(grep -c 'active version' "$T/out")" "1 id100 id110 1"
run "$UPDATE" remove 1.0.0
expect "remove: never the previous version" "$RC $(images) $(grep -c 'previous version' "$T/out")" "1 id100 id110 1"
run "$UPDATE" remove latest
expect "remove: not an app version refused" "$RC" 1

fixture; inst 1.1.0; dl 1.2.0; run "$UPDATE" --yes install 1.2.0
expect "crash on start: exit code" "$RC" 1
expect "crash on start: rolled back, previous restored" "$(tag_of active) $(tag_of previous)" "id110 id100"
expect "crash on start: the rejected version stays downloaded, and it says so" "$(images) $(grep -c 'stays downloaded' "$T/out")" "id100 id110 id120 1"
expect "crash on start: state rolled-back" "$(phase)" rolled-back

fixture; dl 1.3.0; run "$UPDATE" --yes install 1.3.0
expect "crash during the soak: rolled back" "$RC $(tag_of active) $(tag_of previous) $(phase)" "1 id100 none rolled-back"

fixture; run "$UPDATE" download 1.4.0
expect "download of an unsigned or missing version: nothing kept" "$RC $(images) $(tag_of 1.4.0) $(phase)" "1 id100 none failed"

fixture; run "$UPDATE" download 1.6.0
expect "download with the wrong runtime contract: image removed" "$RC $(tag_of active) $(images) $(tag_of 1.6.0) $(phase)" "1 id100 id100 none failed"

fixture; dl 1.5.0; run "$UPDATE" --yes install 1.5.0
expect "configuration error: image kept, not rolled back" "$RC $(tag_of active) $(tag_of previous) $(phase)" "1 id150 id100 config-error"

fixture; run "$UPDATE" download 1.8.0
expect "download: version label differs from the tag, not kept" "$RC $(tag_of active) $(images) $(phase)" "1 id100 id100 failed"

fixture; run "$UPDATE" download latest
expect "non-release tag refused before pulling" "$RC $(tag_of active) $(grep -c . "$FAKE/log")" "1 id100 0"

fixture; rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"; run "$UPDATE" download 1.1.0
expect "no registry token, public registry: downloads anonymously" "$RC $(tag_of 1.1.0)" "0 id110"
fixture; rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"; touch "$FAKE/private"; run "$UPDATE" download 1.1.0
expect "no registry token, private registry: refused, says to log in" \
   "$RC $(images) $(phase) $(jq -r '.message | test("needs a token; run: brewberry-update login")' "$BREWBERRY_UPDATE_ROOT/data/update/state.json")" "1 id100 failed true"
fixture; touch "$FAKE/private"; run "$UPDATE" download 1.1.0
expect "private registry with a token: downloads" "$RC $(tag_of 1.1.0)" "0 id110"

fixture; inst 1.1.0; run "$UPDATE" --yes install 1.1.0
expect "already active: nothing changed" "$RC $(tag_of active) $(tag_of previous) $(phase)" "0 id110 id100 done"

fixture; inst 1.1.0; run "$UPDATE" --yes install 1.0.0
expect "install the previous version (no download tag): switches back" "$RC $(tag_of active) $(tag_of previous)" "0 id100 id110"

fixture; inst 1.1.0; run "$UPDATE" --yes rollback
expect "rollback: swapped" "$RC $(tag_of active) $(tag_of previous) $(phase)" "0 id100 id110 done"

fixture; run "$UPDATE" --yes rollback
expect "rollback without previous: refused" "$RC $(tag_of active)" "1 id100"

fixture; exec 8> "$BREWBERRY_UPDATE_ROOT/run/brewberry-update.lock"; flock 8
run "$UPDATE" download 1.1.0; exec 8>&-
expect "a download while another update runs: refused" "$RC $(images)" "1 id100"

fixture; dl 1.1.0; inst 1.7.0
run "$UPDATE" list
expect "list: versions newest first in SemVer order, pre-releases before their release; the Pi's marked" "$RC $(paste -sd '|' "$T/out")" \
   "0 1.9.0|1.9.0-rc.1|1.9.0-alpha.10|1.9.0-alpha.2|1.8.0|1.7.0  active, on the Pi (250 MB)|1.6.0|1.5.0|1.3.0|1.2.0|1.1.0  on the Pi (250 MB)|1.0.0  previous, on the Pi (250 MB)"
expect "list: tags.json" "$(jq -c '[.active, .tags[0], (.tags | length), .error, .time == .tried]' "$BREWBERRY_UPDATE_ROOT/data/update/tags.json")" '["1.7.0","1.9.0",11,null,true]'
expect "list --json: the Pi's versions" "$("$UPDATE" list --json 2>/dev/null | jq -c '[.active, .previous, (.tags | length), [.local[] | [.version, .active, .previous, .downloaded, .mb]], .registryError]')" \
   '["1.7.0","1.0.0",11,[["1.7.0",true,false,true,250],["1.1.0",false,false,true,250],["1.0.0",false,true,false,250]],null]'
touch "$FAKE/offline"
run "$UPDATE" list
expect "list without the registry: the Pi's versions, and why" "$RC $(paste -sd '|' "$T/out" | sed 's/^brewberry-update: [^|]*|//')" \
   "0 1.7.0  active, on the Pi (250 MB)|1.1.0  on the Pi (250 MB)|1.0.0  previous, on the Pi (250 MB)"
expect "list --json without the registry: registryError" "$("$UPDATE" list --json 2>/dev/null | jq -c '[(.tags | length), (.local | length), (.registryError | test("did not answer"))]')" '[0,3,true]'
expect "list without the registry: tags.json keeps the last answer, records the failed try" \
   "$(jq -c '[(.tags | length), (.error | test("did not answer")), (.tried >= .time)]' "$BREWBERRY_UPDATE_ROOT/data/update/tags.json")" '[11,true,true]'
rm "$FAKE/offline"; rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"
expect "list --json without a token, public registry: anonymous" "$("$UPDATE" list --json 2>/dev/null | jq -c '[(.tags | length), .registryError]') $(tail -n 1 "$FAKE/skopeo.log")" '[11,null] list-tags auth='
touch "$FAKE/private"
expect "list --json without a token, private registry: says so" "$("$UPDATE" list --json 2>/dev/null | jq -r .registryError)" "the registry needs a token; run: brewberry-update login"

fixture; dl 1.9.0-alpha.2; run "$UPDATE" --yes install 1.9.0-alpha.2
expect "install a pre-release (runtime contract §1)" "$RC $(tag_of active) $(phase)" "0 id192 done"

fixture; run "$UPDATE" --yes install 1.9.0-beta
expect "install: not an app version refused" "$RC $(tag_of active)" "1 id100"

# --- demo mode -----------------------------------------------------------------
ARGS_FILE=$BREWBERRY_UPDATE_ROOT/data/update/app-args.env
fixture; run "$UPDATE" --yes demo on
expect "demo on: --dummymode for the app, app restarted" \
   "$RC $(cat "$ARGS_FILE") $(grep -c '^restart' "$FAKE/log")" "0 BREWBERRYPI_ARGS=--dummymode 1"
expect "demo on: status says so" "$("$UPDATE" status 2>/dev/null | tail -n 1)" "demo mode: on"
run "$UPDATE" --yes demo off
expect "demo off: no extra arguments, app restarted" \
   "$RC $(test -e "$ARGS_FILE" && echo kept || echo removed) $(grep -c '^restart' "$FAKE/log")" "0 removed 2"
expect "demo off: status says so" "$("$UPDATE" status 2>/dev/null | tail -n 1)" "demo mode: off"
fixture; run "$UPDATE" --yes demo maybe
expect "demo with a wrong argument: refused, nothing changed" \
   "$RC $(test -e "$ARGS_FILE" && echo written || echo none) $(grep -c . "$FAKE/log")" "1 none 0"
# The unit must read the file the command writes, and pass its variable to the
# app after the contract's command.
UNIT=$ROOT_DIR/layer/brewberry-podman.rootfs-overlay/usr/share/brewberrypi/brewberrypi.container.in
expect "unit reads brewberry-update's argument file" \
   "$(grep -c '^EnvironmentFile=-/data/update/app-args.env$' "$UNIT")" 1
# shellcheck disable=SC2016  # a literal $BREWBERRYPI_ARGS, expanded by systemd
expect "unit passes the arguments after the contract's command" \
   "$(grep -cxF 'Exec=--config /config/config.json $BREWBERRYPI_ARGS' "$UNIT")" 1

# --- confirmation protocol, brew warning, JSON, restart (ADR-0002) -------------
fixture; dl 1.1.0; : > "$FAKE/log"; run "$UPDATE" install 1.1.0 < /dev/null
expect "install without --yes and without a terminal: exit 10, nothing changed" \
   "$RC $(tag_of active) $(grep -c . "$FAKE/log")" "10 id100 0"
expect "install without --yes: says what it would do" "$(grep -c 'This installs 1.1.0 and restarts the app' "$T/out")" 1
fixture; dl 1.1.0; RC=0; "$UPDATE" --json install 1.1.0 < /dev/null > "$T/out" 2> /dev/null || RC=$?
expect "--json: the prompt as {confirm}" "$RC $(jq -r '.confirm | startswith("This installs 1.1.0")' "$T/out")" "10 true"
fixture; echo Running > "$FAKE/engine"; RC=0; "$UPDATE" --json rollback < /dev/null > "$T/out" 2> /dev/null || RC=$?
expect "rollback without previous: refused before asking" "$RC $(grep -c . "$T/out" || true)" "1 0"
fixture; echo Running > "$FAKE/engine"; RC=0; "$UPDATE" demo on --json < /dev/null > "$T/out" 2> /dev/null || RC=$?
expect "brew loaded or running: the prompt warns first" \
   "$RC $(jq -r '.confirm | startswith("A brew is loaded or running (engine: Running). This ends it. This switches")' "$T/out")" "10 true"
fixture; dl 1.1.0; echo Running > "$FAKE/engine"; run "$UPDATE" install 1.1.0 --yes
expect "brew running + --yes: a warning only, the install goes ahead" \
   "$RC $(tag_of active) $(grep -c 'A brew is loaded or running' "$T/out")" "0 id110 1"
fixture; echo NoProcess > "$FAKE/engine"; RC=0; "$UPDATE" --json demo on < /dev/null > "$T/out" 2> /dev/null || RC=$?
expect "no brew loaded: no warning" "$RC $(jq -r .confirm "$T/out")" "10 This switches demo mode on and restarts the app."
fixture; run "$UPDATE" install 9.9 --json
expect "invalid version: refused before asking" "$RC $(grep -c confirm "$T/out" || true)" "1 0"

fixture; inst 1.1.0; echo NoProcess > "$FAKE/engine"
expect "status --json" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.active.version, .previous.version, .service, .engine, .last.phase, .demo, .safemode, .update.checked]')" \
   '["1.1.0","1.0.0","active","NoProcess","done",false,null,null]'
fixture; printf 'org.opencontainers.image.version=placeholder\norg.brewberrypi.runtime-contract=2\n' > "$FAKE/labels/id100"
expect "status: the preloaded placeholder is no app" "$("$UPDATE" status 2>/dev/null | head -n 1 | grep -c 'placeholder (no app installed)')" 1
expect "status --json: the placeholder is marked" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.active.version, .active.placeholder]')" '["placeholder",true]'
inst 1.1.0
expect "install over the placeholder: it becomes previous" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.active.version, .active.placeholder, .previous.placeholder]')" '["1.1.0",false,true]'
fixture
expect "status --json: no previous, app not answering" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.previous, .engine, .last]')" '[null,null,null]'
fixture; echo '{}' > "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"
expect "list --json: tags.json" "$("$UPDATE" list --json 2>/dev/null | jq -c '[.active, .tags[0]]')" '["1.0.0","1.9.0"]'

fixture; run "$UPDATE" restart --yes
expect "restart: the app is restarted, images untouched" "$RC $(cat "$FAKE/log") $(tag_of active)" "0 restart id100 id100"
fixture; echo config > "$FAKE/behave/id100"; run "$UPDATE" restart --yes
expect "restart: a configuration error is reported" "$RC $(grep -c 'refuses its configuration' "$T/out") $(tag_of active)" "1 1 id100"
fixture; run "$UPDATE" restart < /dev/null
expect "restart without --yes: exit 10, not restarted" "$RC $(grep -c . "$FAKE/log")" "10 0"

# --- the update in status (from the last list) -----------------------------------
upd() { "$UPDATE" status --json 2>/dev/null | jq -c '[.update.latest, .update.available]'; }
placeholder() { printf 'org.opencontainers.image.version=placeholder\norg.brewberrypi.runtime-contract=2\n' > "$FAKE/labels/id100"; }
fixture
expect "status: not checked yet" "$(upd) $("$UPDATE" status 2>/dev/null | grep -c '^update: not checked yet$')" '[null,false] 1'
"$UPDATE" list > /dev/null 2>&1
expect "update on a release: the newest release" "$(upd)" '["1.9.0",true]'
dl 1.9.0
expect "update: downloaded already" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.update.latest, .update.onPi]')" '["1.9.0",true]'
expect "status: the update in words" "$("$UPDATE" status 2>/dev/null | grep -c '^update: 1.9.0 is available (registry checked at ')" 1
rm "$FAKE/registry/1.9.0"; "$UPDATE" list > /dev/null 2>&1
expect "update on a release: never a pre-release" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.update.latest, .update.available, .update.onPi]')" '["1.8.0",true,false]'
dl 1.9.0-alpha.2; "$UPDATE" --yes install 1.9.0-alpha.2 > /dev/null 2>&1
expect "update on a pre-release: newer pre-releases too" "$(upd)" '["1.9.0-rc.1",true]'
echo id190 > "$FAKE/registry/1.9.0"; "$UPDATE" list > /dev/null 2>&1
expect "update on a pre-release: its release" "$(upd)" '["1.9.0",true]'
inst 1.9.0
expect "on the newest version: no update" "$(upd) $("$UPDATE" status 2>/dev/null | grep -c '^update: none (registry checked at ')" '["1.9.0",false] 1'
fixture; placeholder; "$UPDATE" list > /dev/null 2>&1
expect "no app installed: the newest release, a first install" "$(upd) $("$UPDATE" status --json 2>/dev/null | jq .update.firstInstall)" '["1.9.0",true] true'
for v in 1.1.0 1.2.0 1.3.0 1.5.0 1.6.0 1.7.0 1.8.0 1.9.0; do rm "$FAKE/registry/$v"; done
"$UPDATE" list > /dev/null 2>&1
expect "no app installed and no release yet: the newest pre-release" "$(upd)" '["1.9.0-rc.1",true]'
touch "$FAKE/offline"; "$UPDATE" list > /dev/null 2>&1
expect "status: a failed check is reported, the last answer kept" \
   "$("$UPDATE" status --json 2>/dev/null | jq -c '[.update.latest, (.update.error | test("did not answer"))]') $("$UPDATE" status 2>/dev/null | grep -c '; the last check failed: the registry did not answer')" '["1.9.0-rc.1",true] 1'

# --- brewberry-update-check: the update check and the first install ------------
CHECK=$SBIN/brewberry-update-check
export BREWBERRY_UPDATE=$UPDATE
FIRST=$BREWBERRY_UPDATE_ROOT/data/update/first-install.json
lists() { grep -c list-tags "$FAKE/skopeo.log" 2>/dev/null || echo 0; }

fixture; placeholder; run "$CHECK"
expect "check, no app installed: the newest version downloaded and installed" \
   "$RC $(tag_of active) $(tag_of previous) $(phase) $(jq -c '[.version, .attempts, .result]' "$FIRST")" '0 id190 id100 done ["1.9.0",1,"installed"]'
run "$CHECK"
expect "check, an app installed: nothing installed, no new registry check within 6 h" "$RC $(tag_of active) $(lists)" "0 id190 1"

fixture; run "$CHECK"
expect "check, an app installed: the registry asked, the update reported, nothing installed" \
   "$RC $(tag_of active) $(grep -c '^restart' "$FAKE/log") $(upd) $(grep -c 'update available: 1.9.0' "$T/out")" '0 id100 0 ["1.9.0",true] 1'
jq '.tried = "2000-01-01T00:00:00Z"' "$BREWBERRY_UPDATE_ROOT/data/update/tags.json" > "$T/tags" && mv "$T/tags" "$BREWBERRY_UPDATE_ROOT/data/update/tags.json"
run "$CHECK"
expect "check, an app installed: the registry asked again after 6 h" "$RC $(lists)" "0 2"
jq '.tried = "2999-01-01T00:00:00Z"' "$BREWBERRY_UPDATE_ROOT/data/update/tags.json" > "$T/tags" && mv "$T/tags" "$BREWBERRY_UPDATE_ROOT/data/update/tags.json"
run "$CHECK"
expect "check: a last try in the future (clock set back) counts as never" "$RC $(lists)" "0 3"

fixture; placeholder; touch "$FAKE/offline"; run "$CHECK"; run "$CHECK"
expect "check, no app installed, offline: asks at every run, the placeholder keeps running" \
   "$RC $(lists) $(tag_of active) $(grep -c '^restart' "$FAKE/log")" "0 2 id100 0"
rm "$FAKE/offline"; run "$CHECK"
expect "check, no app installed, online again: installed" "$RC $(tag_of active)" "0 id190"

fixture; placeholder; rm "$BREWBERRY_UPDATE_ROOT/data/secrets/auth.json"; touch "$FAKE/private"; run "$CHECK"
expect "check, private registry without a token: says so, nothing installed" \
   "$RC $(tag_of active) $(grep -c 'registry: the registry needs a token' "$T/out")" "0 id100 1"

fixture; placeholder; for v in 1.1.0 1.3.0 1.5.0 1.6.0 1.7.0 1.8.0 1.9.0 1.9.0-alpha.2 1.9.0-alpha.10 1.9.0-rc.1; do rm "$FAKE/registry/$v"; done
for _ in 1 2 3; do run "$CHECK"; done
expect "check, the newest version crashes: rolled back to the placeholder, 3 tries" \
   "$RC $(tag_of active) $(jq -c '[.version, .attempts, .result]' "$FIRST") $(grep -c '^restart id120' "$FAKE/log")" '1 id100 ["1.2.0",3,"install-failed"] 3'
run "$CHECK"
expect "check: no fourth try of the same version" "$RC $(grep -c '^restart id120' "$FAKE/log") $(grep -c 'not trying it again' "$T/out")" "0 3 1"
echo id130 > "$FAKE/registry/1.3.0"; echo ok > "$FAKE/behave/id130"; run "$CHECK"
expect "check: a newer version is tried again" "$RC $(tag_of active) $(jq -c '[.version, .attempts]' "$FIRST")" '0 id130 ["1.3.0",1]'

fixture; placeholder; rm "$FAKE/images/id100" "$FAKE/tags/localhost_brewberrypi_active"; run "$CHECK"
expect "check, no image at all: installs the newest version" "$RC $(tag_of active) $(tag_of previous)" "0 id190 none"

fixture; placeholder; run "$CHECK"; "$UPDATE" --yes rollback > /dev/null 2>&1
expect "rolled back to the placeholder: no first install any more" "$("$UPDATE" status --json 2>/dev/null | jq -c '[.active.placeholder, .update.firstInstall, .update.available]')" '[true,false,true]'
: > "$FAKE/log"; jq '.tried = "2000-01-01T00:00:00Z"' "$BREWBERRY_UPDATE_ROOT/data/update/tags.json" > "$T/tags" && mv "$T/tags" "$BREWBERRY_UPDATE_ROOT/data/update/tags.json"
run "$CHECK"
expect "check after a rollback to the placeholder: announces, never installs" "$RC $(tag_of active) $(grep -c '^restart' "$FAKE/log")" "0 id100 0"

# --- brewberrypi-safemode -----------------------------------------------------
# Device with 1.1.0 active and 1.0.0 previous, after the start limit was hit.
safemode_fixture() {
   fixture; inst 1.1.0; : > "$FAKE/log"; echo "${1:-1}" > "$FAKE/sys/status"
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

safemode_fixture; "$SAFEMODE" > /dev/null; inst 1.7.0
expect "a successful install clears the safe-mode marker" "$(test -f "$BREWBERRY_UPDATE_ROOT/data/update/safemode.json" && echo kept || echo cleared)" cleared

exit "$failures"
