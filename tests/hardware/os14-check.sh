#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS14 hardware check (first install and update notice, ADR-0007), run on the
# device as root:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os14-check.sh
#
# run: the check timer is on, the registry answered, status reports the update,
# and the app (not the placeholder) is installed. The fresh-card and the
# notice steps are in tests/hardware/README.md.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
status() { brewberry-update status --json; }

run() {
   check "brewberry-update-check.timer is enabled and waiting" systemctl is-active --quiet brewberry-update-check.timer
   check "the check ran this boot" sh -c 'journalctl -b -u brewberry-update-check.service | grep -q .'
   check "the registry answered (tags.json has versions)" sh -c 'jq -e ".tags | length > 0" /data/update/tags.json'
   check "the last check did not fail" sh -c 'brewberry-update status --json | jq -e ".update.error == null"'
   check "status reports the offered version" sh -c 'brewberry-update status --json | jq -e ".update.latest != null and (.update | has(\"available\"))"'
   check "an app is installed (not the placeholder)" sh -c 'brewberry-update status --json | jq -e ".active.placeholder == false"'
   check "the app is running" systemctl is-active --quiet brewberrypi.service
   echo "update: $(status | jq -c '.update')"
   echo "first install: $(cat /data/update/first-install.json 2>/dev/null || echo 'none (the image preloaded an app, or installed by hand)')"
}

case ${1:-} in
   run) run ;;
   *) echo "usage: os14-check.sh run" >&2; exit 2 ;;
esac
exit "$fail"
