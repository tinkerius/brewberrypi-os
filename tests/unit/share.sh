#!/bin/bash
# Tests for the file share (ADR-0003, OS10) with a fake root
# (BREWBERRY_SHARE_ROOT) and fake pdbedit, smbpasswd, mountpoint and logger: brewberry-share-sync gives the share the default
# password at first start, follows every password change through PAM, drops a
# password that no longer belongs to the account and fixes file owners. Run by
# scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SBIN=$ROOT_DIR/layer/brewberry-share.rootfs-overlay/usr/local/sbin
SYNC=$SBIN/brewberry-share-sync
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
export BREWBERRY_SHARE_ROOT=$T/root
R=$BREWBERRY_SHARE_ROOT
# The test's own user stands in for brewberry, so its files need no chown.
BREWBERRY_SHARE_USER=$(id -un)
BREWBERRY_SHARE_GROUP=$(id -gn)
export BREWBERRY_SHARE_USER BREWBERRY_SHARE_GROUP
U=$BREWBERRY_SHARE_USER
export LOG=$T/log FAKE=$T/fake
PRIV=$R/data/secrets/samba

mkdir -p "$T/bin"
# The passdb is $FAKE/passdb ("user:uid:" lines), the NT password $FAKE/pw-<user>.
cat > "$T/bin/pdbedit" <<'FAKE'
#!/bin/sh
[ "$1" = -L ] && cat "$FAKE/passdb" 2> /dev/null
exit 0
FAKE
cat > "$T/bin/smbpasswd" <<'FAKE'
#!/bin/bash
echo "smbpasswd $*" >> "$LOG"
user=${!#}
case $1 in
   -s) read -r a; read -r b; [ "$a" = "$b" ] || exit 1
       grep -v "^$user:" "$FAKE/passdb" > "$FAKE/passdb.new" 2> /dev/null || true
       echo "$user:1000:" >> "$FAKE/passdb.new"; mv "$FAKE/passdb.new" "$FAKE/passdb"
       printf '%s' "$a" > "$FAKE/pw-$user" ;;
   -x) grep -v "^$user:" "$FAKE/passdb" > "$FAKE/passdb.new" || true; mv "$FAKE/passdb.new" "$FAKE/passdb"
       rm -f "$FAKE/pw-$user" ;;
esac
FAKE
# shellcheck disable=SC2016  # $MOUNTED, $LOG and $* belong to the fake scripts
printf '#!/bin/sh\nexec test -n "$MOUNTED"\n' > "$T/bin/mountpoint"
# shellcheck disable=SC2016
printf '#!/bin/sh\nshift 2\ncat >> "$LOG"\n' > "$T/bin/logger"
chmod +x "$T"/bin/*
export PATH=$T/bin:$PATH

# shellcheck disable=SC2016  # password hashes start with $
DEFAULT_HASH='$y$j9T$default$pi-hash'
fixture() { # fresh device: password still 'pi', no passdb yet
   rm -rf "$R" "$FAKE"
   mkdir -p "$R/etc" "$R/data/config/recipes" "$R/data/secrets" "$R/usr/share/brewberry" "$FAKE"
   echo '{}' > "$R/data/config/config.json"
   echo "$DEFAULT_HASH" > "$R/usr/share/brewberry/default-password.hash"
   account "$DEFAULT_HASH"
   : > "$LOG"
}
# shellcheck disable=SC2016
account() { printf 'other:$y$x:1::\n%s:%s:20000:0:99999:7:::\n' "$U" "$1" > "$R/etc/shadow"; }
pam() { # <stdin password> [user] [type]: what pam_exec runs, with its environment
   printf '%s' "$1" | env -i PATH="$PATH" LOG="$LOG" FAKE="$FAKE" MOUNTED="${MOUNTED-1}" \
      BREWBERRY_LIB="$BREWBERRY_LIB" BREWBERRY_SHARE_ROOT="$R" BREWBERRY_SHARE_USER="$U" \
      PAM_USER="${2:-$U}" PAM_TYPE="${3:-password}" PAM_SERVICE=passwd "$SYNC" pam
}
smbpw() { cat "$FAKE/pw-$U" 2> /dev/null || echo none; }
record() { cat "$PRIV/account-hash" 2> /dev/null || echo none; }

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; }

fixture
run "$SYNC" start
expect "first start: the share gets the default password 'pi'" "$RC $(smbpw) $(record) $(stat -c %a "$PRIV")" "0 pi $DEFAULT_HASH 700"
: > "$LOG"; run "$SYNC" start
expect "next start: in step, the passdb is not written" "$RC $(grep -c smbpasswd "$LOG")" "0 0"

# shellcheck disable=SC2016
account '$y$j9T$new$hash'
pam 'New pass 1:x' > /dev/null
# shellcheck disable=SC2016
expect "PAM hook: the share gets the new password (spaces kept)" "$(smbpw) $(record)" 'New pass 1:x $y$j9T$new$hash'
run "$SYNC" start
expect "start after a PAM change: kept" "$RC $(smbpw)" "0 New pass 1:x"

: > "$LOG"
pam 'theirs' other > /dev/null
pam 'auth-pw' "$U" auth > /dev/null
expect "PAM hook: other users and other phases are ignored" "$(smbpw) $(grep -c smbpasswd "$LOG")" "New pass 1:x 0"
# shellcheck disable=SC2016
account '$y$j9T$third$hash'
MOUNTED='' pam 'unmounted' > /dev/null
expect "PAM hook: nothing written without /data" "$(smbpw) $(grep -c 'not mounted' "$LOG")" "New pass 1:x 1"
# Without any tools (no smbpasswd, awk, logger, mountpoint): still exit 0.
rc=0; printf 'x' | env -i PATH="$T/nothing" BREWBERRY_LIB="$BREWBERRY_LIB" BREWBERRY_SHARE_ROOT="$R" \
   BREWBERRY_SHARE_USER="$U" PAM_USER="$U" PAM_TYPE=password "$SYNC" pam > /dev/null 2>&1 || rc=$?
expect "PAM hook: never fails the password change" "$rc" 0

# The account hash changed without PAM (Imager's hashed password, usermod -p).
run "$SYNC" start
expect "start: a password of an old account hash is removed" "$RC $(smbpw) $(record) $(grep -c '^' "$FAKE/passdb")" "0 none none 0"
grep -q "Set it again in the device web interface" "$T/out" && hint=yes || hint=no
expect "start: says how to give the share a password" "$hint" yes

# Files written as root (an import, the seed config) are given to brewberry.
if [ "$(id -u)" = 0 ]; then
   fixture; chown -R 65534:65534 "$R/data/config"; touch -d '2026-01-01' "$R/data/config/config.json"
   BREWBERRY_SHARE_USER=root BREWBERRY_SHARE_GROUP=root "$SYNC" start > /dev/null 2>&1
   expect "start: wrong owners in /data/config are fixed" \
      "$(find "$R/data/config" ! -user root | wc -l) $(stat -c %y "$R/data/config/config.json" | cut -c1-10)" "0 2026-01-01"
else
   echo "skip  start: owners (needs root)"
fi

exit "$failures"
