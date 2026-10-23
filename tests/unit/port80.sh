#!/bin/bash
# Tests for brewberrypi-port80 with a fake nft: the rule forwards port 80 to the
# app's port from the config (8080 without one or with an unusable port), only
# for the Pi's own addresses and not on the setup hotspot, is removed when the
# app itself is on port 80, and never fails the app's start. Run by
# scripts/lint.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/layer/brewberry-podman.rootfs-overlay/usr/local/sbin/brewberrypi-port80
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRYPI_PORT80_CONFIG=$T/config.json NFT_IN=$T/nft-in

mkdir "$T/bin"
cat > "$T/bin/nft" <<'FAKE'
#!/bin/sh
cat > "$NFT_IN"
[ -z "${NFT_FAIL:-}" ]
FAKE
chmod +x "$T/bin/nft"
export PATH=$T/bin:$PATH

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
target() { sed -n 's/.*tcp dport 80 redirect to :\([0-9]*\)$/\1/p' "$NFT_IN"; }
run() { RC=0; : > "$NFT_IN"; "$SCRIPT" > "$T/out" 2>&1 || RC=$?; }

rm -f "$BREWBERRYPI_PORT80_CONFIG"; run
expect "no config yet: forwards to 8080" "$RC $(target)" "0 8080"
expect "only to the Pi's own addresses" "$(grep -c 'fib daddr type local tcp dport 80' "$NFT_IN")" 1
expect "not on the setup hotspot (the captive portal keeps port 80)" "$(grep -c 'ip daddr 10.42.0.1 return' "$NFT_IN")" 1
expect "replaces an older rule" "$(head -n 2 "$NFT_IN" | paste -sd ';')" "table inet brewberry-app;delete table inet brewberry-app"

echo '{"server": {"port": 9000}}' > "$BREWBERRYPI_PORT80_CONFIG"; run
expect "follows server.port" "$RC $(target)" "0 9000"

for bad in '{"server": {"port": "x"}}' '{"server": {"port": 70000}}' '{"server": {"port": 0}}' 'not json'; do
   echo "$bad" > "$BREWBERRYPI_PORT80_CONFIG"; run
   expect "unusable config ($bad): 8080" "$RC $(target)" "0 8080"
done

echo '{"server": {"port": 80}}' > "$BREWBERRYPI_PORT80_CONFIG"; run
expect "app on port 80 itself: no rule" "$RC $(grep -c redirect "$NFT_IN") $(grep -c 'delete table inet brewberry-app' "$NFT_IN")" "0 0 1"

echo '{}' > "$BREWBERRYPI_PORT80_CONFIG"; RC=0; NFT_FAIL=1 "$SCRIPT" > "$T/out" 2>&1 || RC=$?
expect "nft fails: the app still starts (exit 0), logged" "$RC $(grep -c 'could not load the rule' "$T/out")" "0 1"

expect "--print loads nothing" "$(: > "$NFT_IN"; "$SCRIPT" --print | grep -c redirect) $(wc -c < "$NFT_IN")" "1 0"

exit "$failures"
