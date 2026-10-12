#!/bin/bash
# Tests for brewberrypi-outputs-off with fake pinctrl and podman: the pinctrl
# calls it makes for each kind of config. Run by scripts/lint.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/layer/brewberry-safety.rootfs-overlay/usr/local/sbin/brewberrypi-outputs-off
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir "$T/bin"
cat > "$T/bin/pinctrl" <<'FAKE'
#!/bin/sh
echo "pinctrl $*" >> "$LOG"
[ "$2" != "${FAIL_PIN:-}" ]
FAKE
cat > "$T/bin/podman" <<'FAKE'
#!/bin/sh
echo "podman $*" >> "$LOG"
FAKE
chmod +x "$T/bin/pinctrl" "$T/bin/podman"

failures=0
# case <name> <config|NONE> <expected rc> <expected pinctrl calls, ';'-separated> [fail pin]
case_() {
   local name=$1 config=$2 want_rc=$3 want=$4 fail_pin=${5:-} rc=0
   export LOG=$T/log
   : > "$LOG"
   rm -f "$T/config.json"
   [ "$config" = NONE ] || printf '%s' "$config" > "$T/config.json"
   PATH=$T/bin:$PATH BREWBERRYPI_OUTPUTS_CONFIG=$T/config.json FAIL_PIN=$fail_pin \
      sh "$SCRIPT" > /dev/null || rc=$?
   local got
   got=$(grep '^pinctrl' "$LOG" | sed 's/^pinctrl set //' | paste -sd ';')
   if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
      echo "ok    $name"
   else
      echo "FAIL  $name: rc $rc (want $want_rc), calls '$got' (want '$want')"
      failures=1
   fi
   grep -q '^podman rm -f -t 0 -i brewberrypi$' "$LOG" || { echo "FAIL  $name: container not removed"; failures=1; }
}

DEF='23 op pu dh;22 op pu dh;10 op pd dl'
case_ "no config: defaults, heater first" NONE 0 "$DEF"
case_ "custom pins and polarity" \
   '{"hardware":{"heating":{"pin":5,"activeLow":false},"pump":{"pin":6,"activeLow":true},"buzzer":{"pin":7,"activeLow":true}}}' \
   0 '5 op pd dl;6 op pu dh;7 op pu dh'
case_ "explicit activeLow false is kept" '{"hardware":{"heating":{"activeLow":false},"pump":{"pin":17}}}' \
   0 '23 op pd dl;17 op pu dh;10 op pd dl'
case_ "unreadable config: defaults, rc 1" '{"hardware": nope' 1 "$DEF"
case_ "invalid pin: others still reset, then defaults" '{"hardware":{"heating":{"pin":24},"pump":{"pin":30}}}' \
   1 "24 op pu dh;10 op pd dl;$DEF"
case_ "invalid activeLow: skipped, then defaults" '{"hardware":{"pump":{"activeLow":"yes"}}}' \
   1 "23 op pu dh;10 op pd dl;$DEF"
case_ "pinctrl fails for the heater: the rest still reset" NONE 1 "$DEF" 23

exit "$failures"
