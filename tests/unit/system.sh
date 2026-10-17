#!/bin/bash
# Tests for brewberry-system (ADR-0002, OS9) with a fake root
# (BREWBERRY_SYSTEM_ROOT) and a fake journalctl: info as text and JSON, logs
# per name, and refusing unknown names. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SYSTEM=$ROOT_DIR/layer/brewberry-update.rootfs-overlay/usr/local/sbin/brewberry-system
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_SYSTEM_ROOT=$T/root LOG=$T/log
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
R=$BREWBERRY_SYSTEM_ROOT

mkdir -p "$T/bin" "$R"/{etc,proc/device-tree,data}
cat > "$T/bin/journalctl" <<'FAKE'
#!/bin/sh
echo "journalctl $*" >> "$LOG"
echo "2026-10-15T10:00:00+0000 brewberrypi brewberrypi-outputs-off[42]: heating (BCM 23): off"
echo "2026-10-15T10:00:01+0000 brewberrypi systemd[1]: Started brewberrypi.service."
FAKE
chmod +x "$T/bin/journalctl"
export PATH=$T/bin:$PATH
printf '%s\n' BREWBERRY_OS_VERSION=v0.1.0-alpha.14 BREWBERRY_OS_IMAGE=brewberrypi-os-pi34 \
   BREWBERRY_OS_APP_PRELOAD=stub BREWBERRY_OS_BUILD_DATE=2026-10-15T09:00:00Z > "$R/etc/brewberry-release"
printf 'Raspberry Pi 4 Model B Rev 1.5\0' > "$R/proc/device-tree/model"
echo "7384.12 1000.00" > "$R/proc/uptime"

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; : > "$LOG"; "$@" > "$T/out" 2>&1 || RC=$?; }

expect "info --json" "$("$SYSTEM" info --json | jq -c '[.os.version, .os.appPreload, .board, .uptimeSeconds, (.data.size > 0)]')" \
   '["v0.1.0-alpha.14","stub","Raspberry Pi 4 Model B Rev 1.5",7384,true]'
expect "info: text" "$("$SYSTEM" info | sed -n '1p;5p')" \
   "$(printf '%s\n' 'OS:        BrewberryPi OS v0.1.0-alpha.14 (brewberrypi-os-pi34, built 2026-10-15T09:00:00Z, preload stub)' 'uptime:    2 h 3 min')"

run "$SYSTEM" logs app
expect "logs app: this boot's journal of the app" "$RC $(cat "$LOG")" "0 journalctl -b --no-pager -o short-iso -n 200 -u brewberrypi.service"
run "$SYSTEM" logs safemode --lines 50
expect "logs --lines" "$RC $(cat "$LOG")" "0 journalctl -b --no-pager -o short-iso -n 50 -u brewberrypi-safemode.service"
expect "logs outputs-off --json: only the reset's lines" "$("$SYSTEM" logs outputs-off --json | jq -c '[.name, (.lines | length), (.lines[0] | test("heating"))]')" \
   '["outputs-off",1,true]'
run "$SYSTEM" logs share
expect "logs share: smbd and the share's password hook" "$RC $(cat "$LOG")" \
   "0 journalctl -b --no-pager -o short-iso -n 200 _SYSTEMD_UNIT=smbd.service + SYSLOG_IDENTIFIER=brewberry-share-sync"
run "$SYSTEM" logs wifi
expect "logs wifi: the Wi-Fi service, its first-boot move and NetworkManager" "$RC $(cat "$LOG")" \
   "0 journalctl -b --no-pager -o short-iso -n 200 -u brewberry-wifi.service -u brewberry-wifi-migrate.service -u NetworkManager.service"
run "$SYSTEM" logs kernel
expect "logs: unknown name refused" "$RC $(grep -c . "$LOG")" "1 0"
run "$SYSTEM" logs app --lines 0
expect "logs: bad --lines refused" "$RC $(grep -c . "$LOG")" "1 0"

exit "$failures"
