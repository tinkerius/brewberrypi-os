#!/bin/bash

set -eu

LABEL="$1"

case $LABEL in
   ROOT)
      # /boot/firmware stays rw until brewberry-seal switches it to ro after
      # first boot (keep the 'vfat rw,' spelling: seal and brewberry-maint
      # match on it). /data is not in fstab: data.mount mounts it, so
      # overlayroot never covers it.
      cat << EOF2 > "$IMAGEMOUNTPATH/etc/fstab"
/dev/disk/by-slot/system  /               ext4  rw,relatime,errors=remount-ro,commit=30  0  1
/dev/disk/by-slot/boot    /boot/firmware  vfat  rw,noatime,errors=remount-ro  0  2
EOF2
      ;;
   BOOT)
      # No 'resize' token (the root is never grown) and no overlayroot yet
      # (brewberry-seal adds it after first boot).
      sed -i "s|root=\([^ ]*\)|root=/dev/disk/by-slot/system|" "$IMAGEMOUNTPATH/cmdline.txt"
      ;;
   *)
      ;;
esac
