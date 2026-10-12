#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS6 hardware check, run on the device as root, mode by mode (each reboot ends
# the SSH session; reconnect and run the next mode):
#
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- <mode>' < tests/hardware/os6-check.sh
#
#   sealed    the system is sealed (run first and last)
#   on        brewberry-maint on (reboots into maintenance mode)
#   maint     maintenance mode is active
#   upgrade   apt update && apt full-upgrade
#   off       brewberry-maint off (seals and reboots)
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
fs_type() { findmnt -no FSTYPE "$1"; }
has_opt() { findmnt -no OPTIONS "$1" | tr ',' '\n' | grep -qx "$2"; }
# apt runs the DPkg::Pre-Invoke guard before it calls dpkg (lists go to RAM).
apt_refused() {
   apt-get -qq update >/dev/null 2>&1
   apt-get -y --reinstall install jq 2>&1 | grep -q 'sealed: run brewberry-maint on'
}

case ${1:-} in
   sealed)
      check "/ is the overlay" test "$(fs_type /)" = overlay
      check "/boot/firmware is read-only" has_opt /boot/firmware ro
      check "no maintenance flag in the real root" test ! -e /media/root-ro/etc/brewberry/maintenance
      check "apt refuses to change packages while sealed" apt_refused
      check "the app is running" systemctl is-active --quiet brewberrypi.service
      check "config.txt still has the safety block" grep -qx 'dtparam=strict_gpiod' /boot/firmware/config.txt
      ;;
   on) brewberry-maint on --yes ;;
   maint)
      check "/ is the real ext4 root (no overlay)" test "$(fs_type /)" = ext4
      check "/ is writable" has_opt / rw
      check "/boot/firmware is writable" has_opt /boot/firmware rw
      check "maintenance flag present" test -e /etc/brewberry/maintenance
      check "brewberry-seal did not seal again" sh -c "! grep -q overlayroot= /proc/cmdline"
      check "/data is still mounted" mountpoint -q /data
      check "the app is running" systemctl is-active --quiet brewberrypi.service
      ;;
   upgrade)
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
      check "apt full-upgrade succeeded" test $? -eq 0
      check "the initramfs still contains overlayroot" sh -c 'lsinitramfs /boot/firmware/initramfs8 | grep -q scripts/init-bottom/overlayroot'
      ;;
   off) brewberry-maint off --yes ;;
   *) echo "usage: os6-check.sh sealed|on|maint|upgrade|off" >&2; exit 2 ;;
esac
exit "$fail"
