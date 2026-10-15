#!/bin/bash
# Tests for brewberry-passwd (ADR-0002, OS9) with a fake root
# (BREWBERRY_PASSWD_ROOT) and a fake usermod: login users' hashes are saved to
# /data only when they change, and restored at boot only where they differ.
# Run by scripts/lint.sh.
# shellcheck disable=SC2016  # the password hashes are literal '$y$...' strings
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASSWD=$ROOT_DIR/layer/brewberry-web.rootfs-overlay/usr/local/sbin/brewberry-passwd
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_PASSWD_ROOT=$T/root LOG=$T/log
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
R=$BREWBERRY_PASSWD_ROOT
S=$R/data/secrets/shadow.d

mkdir -p "$T/bin"
# shellcheck disable=SC2016  # $* and $LOG belong to the fake script
printf '#!/bin/sh\necho "usermod $*" >> "$LOG"\n' > "$T/bin/usermod"
chmod +x "$T/bin/usermod"
export PATH=$T/bin:$PATH

fixture() {
   rm -rf "$R"; mkdir -p "$R/etc" "$R/data"
   printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'brewberry-web:x:998:998::/nonexistent:/usr/sbin/nologin' \
      'brewberry:x:1000:1000::/home/brewberry:/bin/bash' 'pi:x:1001:1001::/home/pi:/bin/bash' \
      'nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin' > "$R/etc/passwd"
   printf '%s\n' 'root:*:20000:0:99999:7:::' 'brewberry-web:!:20000::::::' 'brewberry:$y$j9T$aaa$bbb:20000:0:99999:7:::' \
      'pi:$y$j9T$ccc$ddd:20000:0:99999:7:::' 'nobody:*:20000:0:99999:7:::' > "$R/etc/shadow"
   : > "$LOG"
}

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }
saved() { find "$S" -type f -printf '%f\n' 2>/dev/null | sort | paste -sd ' '; }

fixture; run "$PASSWD" persist
expect "persist: login users only" "$RC $(saved)" "0 brewberry pi"
expect "persist: the hash, private" "$(cat "$S/brewberry") $(stat -c %a "$S/brewberry") $(stat -c %a "$R/data/secrets")" '$y$j9T$aaa$bbb 600 700'
run "$PASSWD" persist
expect "persist: unchanged hashes are not written again" "$RC $(grep -c saved "$T/out" || true)" "0 0"
sed -i 's/^pi:[^:]*:/pi:$y$j9T$new$hash:/' "$R/etc/shadow"; run "$PASSWD" persist
expect "persist: a changed hash is saved" "$RC $(cat "$S/pi") $(grep -c 'saved the password of pi' "$T/out")" '0 $y$j9T$new$hash 1'

# A reboot: /etc/shadow is the image's again.
sed -i 's/^pi:[^:]*:/pi:$y$j9T$ccc$ddd:/' "$R/etc/shadow"; : > "$LOG"; run "$PASSWD" restore
expect "restore: only differing hashes, with usermod" "$RC $(cat "$LOG")" '0 usermod -p $y$j9T$new$hash pi'

fixture; mkdir -p "$S"; echo 'x' > "$S/ghost"; printf 'bad hash\n' > "$S/brewberry"; run "$PASSWD" restore
expect "restore: unknown users and broken files are ignored" "$RC $(grep -c . "$LOG" || true)" "0 0"

fixture; run "$PASSWD" restore
expect "restore: nothing saved yet" "$RC $(grep -c . "$LOG" || true)" "0 0"

exit "$failures"
