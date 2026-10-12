#!/bin/bash
# Tests for brewberry-maint with a fake root (BREWBERRY_MAINT_ROOT) and fake
# mount, systemctl and brewberry-seal: 'on' takes the overlay off the kernel
# command line before it writes the maintenance flag and a writable boot entry
# into the real root; 'off' checks config.txt's safety block, removes the flag
# and hands over to brewberry-seal. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
MAINT=$ROOT_DIR/layer/brewberry-readonly.rootfs-overlay/usr/local/sbin/brewberry-maint
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export R=$T/root BREWBERRY_MAINT_ROOT=$T/root LOG=$T/log

mkdir -p "$T/bin"
for cmd in mount systemctl brewberry-seal; do
   # shellcheck disable=SC2016  # $* and $LOG belong to the fake script
   printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$cmd" > "$T/bin/$cmd"
done
chmod +x "$T"/bin/*
export PATH=$T/bin:$PATH

CMD="console=serial0,115200 console=tty1 root=/dev/disk/by-slot/system fsck.repair=yes rootwait"
fixture() { # sealed|maintenance
   rm -rf "$R"
   mkdir -p "$R"/{proc,boot/firmware,media/root-ro/etc,etc/brewberry}
   printf '%s\n' "# --- BrewberryPi (ADR-0001, runtime contract §6) ---" "dtparam=strict_gpiod" \
      "gpio=22,23=op,pu,dh" "gpio=10=op,pd,dl" > "$R/boot/firmware/config.txt"
   if [ "$1" = sealed ]; then
      echo "overlayroot=tmpfs:recurse=0 $CMD" > "$R/proc/cmdline"
      echo "overlayroot=tmpfs:recurse=0 $CMD" > "$R/boot/firmware/cmdline.txt"
      printf '%s\n' "/dev/disk/by-slot/system  /  ext4  rw,relatime  0  1" \
         "/dev/disk/by-slot/boot  /boot/firmware  vfat  ro,noatime,errors=remount-ro  0  2" > "$R/media/root-ro/etc/fstab"
   else
      echo "$CMD" > "$R/proc/cmdline"
      echo "$CMD" > "$R/boot/firmware/cmdline.txt"
      date > "$R/etc/brewberry/maintenance"
   fi
   : > "$LOG"
}

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }
boot_opts() { awk '$2 == "/boot/firmware" {print $4}' "$R/media/root-ro/etc/fstab"; }

fixture sealed; run "$MAINT" on --yes
expect "on: overlay removed, rest of cmdline kept" "$RC $(cat "$R/boot/firmware/cmdline.txt")" "0 $CMD"
expect "on: maintenance flag in the real root" "$(test -s "$R/media/root-ro/etc/brewberry/maintenance" && echo yes)" yes
expect "on: boot writable in the real root's fstab" "$(boot_opts)" "rw,noatime,errors=remount-ro"
expect "on: cmdline changed before the real root, then reboot" "$(grep -o 'remount,rw [^ ]*\|reboot' "$LOG" | sed "s|$R||" | paste -sd ' ')" \
   "remount,rw /boot/firmware remount,rw /media/root-ro reboot"

fixture maintenance; run "$MAINT" on --yes
expect "on: refused when not sealed" "$RC $(grep -c . "$LOG")" "1 0"

fixture maintenance; run "$MAINT" off --yes
expect "off: flag removed, brewberry-seal runs" "$RC $(test -e "$R/etc/brewberry/maintenance" && echo kept || echo removed) $(cat "$LOG")" \
   "0 removed brewberry-seal "

fixture maintenance; sed -i '/strict_gpiod/d' "$R/boot/firmware/config.txt"; run "$MAINT" off --yes
expect "off: refused when config.txt lost the safety block" "$RC $(test -e "$R/etc/brewberry/maintenance" && echo kept) $(grep -c . "$LOG")" "1 kept 0"

fixture maintenance; sed -i 's/^gpio=22,23=/gpio=17,23=/' "$R/boot/firmware/config.txt"; run "$MAINT" off --yes
expect "off: moved boot pins are fine" "$RC $(cat "$LOG")" "0 brewberry-seal "

fixture sealed; run "$MAINT" off --yes
expect "off: refused when already sealed" "$RC $(grep -c . "$LOG")" "1 0"

fixture sealed; RC=0; echo no | "$MAINT" on > /dev/null 2>&1 || RC=$?
expect "on: cancelled without 'yes'" "$RC $(grep -c . "$LOG") $(grep -c overlayroot "$R/boot/firmware/cmdline.txt")" "1 0 1"

fixture sealed; run "$MAINT" status
expect "status: sealed" "$(head -n1 "$T/out")" "sealed: overlay root, read-only boot"

exit "$failures"
