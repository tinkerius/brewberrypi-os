#!/bin/bash
# Tests for brewberrypi-outputs-off with fake pinctrl and podman: the pinctrl
# calls it makes for each kind of config, and with the outputs recorded at the
# app's start (--record) when the config changed while it ran. Run by
# scripts/lint.sh.
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
   PATH=$T/bin:$PATH BREWBERRYPI_OUTPUTS_CONFIG=$T/config.json BREWBERRYPI_OUTPUTS_STARTED=$T/run/started \
      FAIL_PIN=$fail_pin \
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

# started <outputs|"">: what --record wrote at the app's start (empty: nothing).
started() {
   rm -rf "$T/run"
   [ -z "$1" ] || { mkdir -p "$T/run"; printf '%s\n' "$1" > "$T/run/started"; }
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

# record <name> <config|NONE> <expected record|NONE>
record() {
   local got
   rm -rf "$T/run" "$T/config.json"
   [ "$2" = NONE ] || printf '%s' "$2" > "$T/config.json"
   BREWBERRYPI_OUTPUTS_CONFIG=$T/config.json BREWBERRYPI_OUTPUTS_STARTED=$T/run/started \
      sh "$SCRIPT" --record > /dev/null || { echo "FAIL  $1: --record failed"; failures=1; return; }
   got=$(paste -sd ';' "$T/run/started" 2> /dev/null || echo NONE)
   if [ "$got" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: recorded '$got' (want '$3')"; failures=1; fi
}
record "--record: the defaults without a config" NONE 'heating 23 true;pump 22 true;buzzer 10 false'
record "--record: the config's outputs" '{"hardware":{"heating":{"pin":5,"activeLow":false}}}' \
   'heating 5 false;pump 22 true;buzzer 10 false'
record "--record: nothing for an unreadable config" '{"hardware": nope' NONE
record "--record: nothing for an invalid pin" '{"hardware":{"pump":{"pin":30}}}' NONE

# The config changed while the app ran: the app's pins first, at their off
# level; the config's other pins after them.
started 'heating 5 false
pump 6 true
buzzer 7 false'
case_ "started outputs first, then the config's" NONE 0 "5 op pd dl;6 op pu dh;7 op pd dl;$DEF"
started 'heating 23 false
pump 22 true
buzzer 10 false'
case_ "a pin in both keeps the running app's off level" \
   '{"hardware":{"heating":{"pin":23,"activeLow":true},"pump":{"pin":24}}}' \
   0 '23 op pd dl;22 op pu dh;10 op pd dl;24 op pu dh'
case_ "invalid config after the start: started, then the rest of the defaults" \
   '{"hardware":{"heating":{"pin":99}}}' 1 '23 op pd dl;22 op pu dh;10 op pd dl'
started 'heating 23 true
pump 99 true'
case_ "a bad recorded line is skipped" NONE 1 '23 op pu dh;22 op pu dh;10 op pd dl'
started ""

exit "$failures"
