#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS5 hardware check, run on the device as root. Prepare the stick on your
# machine first (tests/hardware/README.md, OS5), then plug it into the Pi.
#
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- setup <registry/repository> /tmp/test.pub' < tests/hardware/os5-check.sh
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os5-check.sh
#
# setup changes /etc in the RAM overlay only: the device then accepts USB
# exports of the test repository signed with the test key until it reboots.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
version() { podman image inspect -f '{{index .Labels "org.opencontainers.image.version"}}' "localhost/brewberrypi:$1" 2>/dev/null; }
is_version() { test "$(version "$1")" = "$2"; }
not_mounted() { ! mountpoint -q /media/brewberry-usb; }
lists_both() { printf '%s\n' "$listing" | grep -qx '  0.2.0' && printf '%s\n' "$listing" | grep -qx '  9.9.9'; }

setup() { # <repo> <test.pub>
   grep -q 'overlayroot=' /proc/cmdline || { echo "not sealed: refusing to change /etc on the real root" >&2; exit 1; }
   install -m 0644 "$2" /etc/containers/brewberry-test.pub
   jq --arg repo "$1" '.transports.dir["/media/brewberry-usb"] = [{type: "sigstoreSigned",
         keyPath: "/etc/containers/brewberry-test.pub",
         signedIdentity: {type: "exactRepository", dockerRepository: $repo}}]' \
      /etc/containers/policy.json > /etc/containers/policy.json.new
   mv /etc/containers/policy.json.new /etc/containers/policy.json
   echo "USB test rule installed until the next reboot"
}

run() {
   before=$(version active)
   listing=$(brewberry-usb list 2>&1)
   check "the stick lists 0.2.0 and 9.9.9" lists_both
   check "the stick is unmounted again" not_mounted

   check "9.9.9 (tampered) is rejected" sh -c '! brewberry-usb install 9.9.9 --yes'
   check "active unchanged after the rejection" is_version active "$before"
   check "the stick is unmounted after a failed install" not_mounted

   brewberry-usb install 0.2.0 --yes >/dev/null 2>&1
   check "0.2.0 installs offline from the stick and is active" is_version active 0.2.0
   check "brewberrypi.service is running" systemctl is-active --quiet brewberrypi.service

   brewberry-usb import-config >/dev/null 2>&1
   check "config imported to /data/config" test -f /data/config/config.json
   check "the stick is unmounted at the end" not_mounted
   echo; brewberry-update status
}

case ${1:-} in
   setup) [ $# -eq 3 ] || { echo "usage: os5-check.sh setup <registry/repository> <test.pub>" >&2; exit 2; }; setup "$2" "$3" ;;
   run) run ;;
   *) echo "usage: os5-check.sh setup <registry/repository> <test.pub> | run" >&2; exit 2 ;;
esac
exit "$fail"
