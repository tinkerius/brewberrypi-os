#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS4 hardware check, run on the device as root, after
# scripts/publish-test-stubs.sh pushed the test versions 0.2.0-0.5.0.
#
#   scp work/test-signing/test.pub brewberry@brewberrypi.local:/tmp/
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- setup <registry/repository> /tmp/test.pub' < tests/hardware/os4-check.sh
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os4-check.sh
#
# setup only changes /etc in the RAM overlay: a reboot removes the test key and
# policy entry again. run takes about five minutes.
set -u

ENV=/run/brewberry-os4-test.env
REPO=$(sed -n 's/^REPO=//p' "$ENV" 2>/dev/null)
fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
version() { podman image inspect -f '{{index .Labels "org.opencontainers.image.version"}}' "localhost/brewberrypi:$1" 2>/dev/null; }
is_version() { test "$(version "$1")" = "$2"; }
# --yes: install, rollback and demo ask for confirmation otherwise (ADR-0002).
update() { BREWBERRY_UPDATE_REPO=$REPO brewberry-update "$@" --yes; }

setup() { # <repo> <test.pub>
   repo=$1; key=$2
   grep -q 'overlayroot=' /proc/cmdline || { echo "not sealed: refusing to change /etc on the real root" >&2; exit 1; }
   install -m 0644 "$key" /etc/containers/brewberry-test.pub
   jq --arg repo "$repo" '.transports.docker[$repo] = [{type: "sigstoreSigned",
         keyPath: "/etc/containers/brewberry-test.pub", signedIdentity: {type: "matchRepository"}}]' \
      /etc/containers/policy.json > /etc/containers/policy.json.new
   mv /etc/containers/policy.json.new /etc/containers/policy.json
   printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$repo" > /etc/containers/registries.d/brewberry-test.yaml
   echo "REPO=$repo" > "$ENV"
   echo "test key and policy entry installed until the next reboot"
}

wait_safemode_done() { # <since>: until safe mode gave up (it logs that), at most 4 minutes
   i=0
   while [ "$i" -lt 240 ]; do
      journalctl -q --since "$1" -t brewberrypi-safemode | grep -q 'failed as well' && return 0
      i=$((i + 1)); sleep 1
   done
   return 1
}

run() {
   [ -n "$REPO" ] || { echo "run setup first" >&2; exit 1; }
   start=$(date '+%Y-%m-%d %H:%M:%S')
   before=$(version active)
   echo "active before: $before"

   check "0.5.0 (signed with another key) is rejected" sh -c "! BREWBERRY_UPDATE_REPO=$REPO brewberry-update install 0.5.0 --yes"
   check "0.4.0 (unsigned) is rejected" sh -c "! BREWBERRY_UPDATE_REPO=$REPO brewberry-update install 0.4.0 --yes"
   check "active unchanged after the rejections" is_version active "$before"

   update install 0.2.0 >/dev/null 2>&1
   check "0.2.0 (signed, healthy) is installed and active" is_version active 0.2.0
   check "the version before is previous" is_version previous "$before"

   update install 0.3.0 >/dev/null 2>&1
   check "0.3.0 (crashes on start) is rolled back: 0.2.0 active" is_version active 0.2.0
   check "previous survived rollback and garbage collection" is_version previous "$before"
   check "the rejected 0.3.0 image is gone" sh -c "! podman images --format '{{.Labels}}' | grep -q 'version:0.3.0'"

   echo "safe mode: making every start crash (stub.json), waiting for systemd to give up twice..."
   printf '{"start": "crash"}\n' > /data/config/stub.json && sync -f /data
   systemctl reset-failed brewberrypi.service; systemctl restart brewberrypi.service 2>/dev/null
   check "systemd gave up twice; safe mode then left the app down" wait_safemode_done "$start"
   switches=$(journalctl -q --since "$start" -t brewberrypi-safemode | grep -c 'switched to the previous image')
   check "safe mode switched exactly once (got $switches)" test "$switches" -eq 1
   check "after the switch, previous ($before) is active" is_version active "$before"
   check "the app stays down after the second failure" test "$(systemctl show -p ActiveState --value brewberrypi.service)" = failed
   check "outputs are off" sh -c 'pinctrl get 23 | grep -q "| hi"'

   rm -f /data/config/stub.json && sync -f /data
   systemctl reset-failed brewberrypi.service && systemctl start brewberrypi.service
   check "back up after removing the crash setting" systemctl is-active --quiet brewberrypi.service
   echo; brewberry-update status
}

case ${1:-} in
   setup) [ $# -eq 3 ] || { echo "usage: os4-check.sh setup <registry/repository> <test.pub>" >&2; exit 2; }; setup "$2" "$3" ;;
   run) run ;;
   *) echo "usage: os4-check.sh setup <registry/repository> <test.pub> | run" >&2; exit 2 ;;
esac
exit "$fail"
