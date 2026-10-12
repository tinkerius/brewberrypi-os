#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS1 hardware check, run on the device as root:
#
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- status'   < tests/hardware/os1-check.sh
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- checksum' < tests/hardware/os1-check.sh
#
# status:   mount layout after sealing (overlay root, ro boot, rw /data).
# checksum: SHA-256 of the boot and root partitions, appended to
#           /data/os1-checksums.log and compared with the first entry. Run it
#           once after sealing and again after every power cut.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then
      echo "PASS  $desc"
   else
      echo "FAIL  $desc"
      fail=1
   fi
}

fs_type() { findmnt -no FSTYPE "$1"; }
has_opt() { findmnt -no OPTIONS "$1" | tr ',' '\n' | grep -qx "$2"; }
data_dev() { readlink -f /dev/disk/by-slot/data; }

root_is_overlay()  { test "$(fs_type /)" = overlay; }
boot_is_ro_vfat()  { test "$(fs_type /boot/firmware)" = vfat && has_opt /boot/firmware ro; }
data_is_ext4()     { test "$(fs_type /data)" = ext4 && test "$(findmnt -no SOURCE /data)" = "$(data_dev)"; }
data_grown()       { test "$(blockdev --getsize64 "$(data_dev)")" -gt 1073741824; }
data_layout()      { for d in config containers/storage tmp update secrets; do test -d "/data/$d" || return 1; done; }
journal_volatile() { journalctl --header 2>/dev/null | grep -q /run/log/journal && test ! -d /var/log/journal/"$(cat /etc/machine-id)"; }
no_failed_units()  { test "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0; }

status() {
   check "/ is an overlay"                         root_is_overlay
   check "overlayroot=tmpfs:recurse=0 is active"   grep -q 'overlayroot=tmpfs:recurse=0' /proc/cmdline
   check "lower root /media/root-ro is read-only"  has_opt /media/root-ro ro
   check "/boot/firmware is vfat, read-only"       boot_is_ro_vfat
   check "/data is ext4 from by-slot/data"         data_is_ext4
   check "/data is read-write"                     has_opt /data rw
   check "/data was grown (> 1 GiB)"               data_grown
   check "/data layout exists"                     data_layout
   check "journal is volatile"                     journal_volatile
   check "no failed units"                         no_failed_units
   echo
   findmnt / ; findmnt /media/root-ro ; findmnt /boot/firmware ; findmnt /data
   systemctl --failed --no-legend
}

checksum() {
   log=/data/os1-checksums.log
   boot=$(sha256sum < "$(readlink -f /dev/disk/by-slot/boot)" | cut -d' ' -f1)
   root=$(sha256sum < "$(readlink -f /dev/disk/by-slot/system)" | cut -d' ' -f1)
   line="boot=$boot root=$root"
   first=$(head -n1 "$log" 2>/dev/null | cut -d' ' -f3-)
   printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat /proc/sys/kernel/random/boot_id)" "$line" >> "$log"
   sync -f /data
   echo "$line"
   if [ -z "$first" ]; then
      echo "baseline recorded in $log"
   else
      check "boot and root match the baseline" test "$line" = "$first"
   fi
   echo "$(wc -l < "$log") entries in $log"
}

case ${1:-status} in
   status) status ;;
   checksum) checksum ;;
   *) echo "usage: os1-check.sh status|checksum" >&2; exit 2 ;;
esac
exit "$fail"
