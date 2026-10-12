#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS3 hardware check, run on the device as root, with LEDs or the relay board
# (NOT the heater) on the default pins: heater BCM 23 and pump BCM 22
# active-low, buzzer BCM 10 active-high.
#
#   ssh brewberry@brewberrypi.local 'sudo sh -s -- <mode>' < tests/hardware/os3-check.sh
#
# Modes:
#   status   host safety settings and the current output levels
#   enable   allow the stub's heater test (/data/config/stub.json) and restart
#   kill9    heater on, then kill -9 the app       -> heater must go off
#   hang     heater on, then stop watchdog pings   -> killed within ~20 s, off
#   rm       heater on, then podman rm -f the app  -> heater must go off
#   heat     heater on and leave it on (for the power-cut test)
#   disable  remove the heater test permission again and restart
set -u

HEATER=23
STUB_JSON=/data/config/stub.json
fail=0

check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}

level() { pinctrl get "$1" | sed -n 's/.*| \(hi\|lo\).*/\1/p'; }
heater_off() { test "$(level "$HEATER")" = hi; }
heater_on() { test "$(level "$HEATER")" = lo; }
strict_gpiod() {
   grep -q 'persist_gpio_outputs=n' /proc/cmdline ||
      grep -qx N /sys/module/pinctrl_bcm2835/parameters/persist_gpio_outputs 2>/dev/null
}

post() { # <path>: HTTP POST to the app from inside its container
   podman exec brewberrypi python3 -c \
      "import sys, urllib.request as u; u.urlopen(u.Request('http://127.0.0.1:8080' + sys.argv[1], method='POST'), timeout=5)" "$1"
}

wait_active() {
   i=0
   while ! systemctl is-active --quiet brewberrypi.service; do
      i=$((i + 1)); [ "$i" -le 90 ] || return 1; sleep 1
   done
}

# Turns the heater on, runs <action>, then measures how long until it is off.
scenario() { # <name> <action...>
   name=$1; shift
   wait_active || { echo "FAIL  $name: brewberrypi.service not active"; fail=1; return; }
   post "/stub/heat?on=1" || { echo "FAIL  $name: could not switch the heater on (run 'enable' first)"; fail=1; return; }
   sleep 1
   check "$name: heater is on (BCM $HEATER low)" heater_on
   t0=$(date +%s%N)
   "$@"
   i=0
   while ! heater_off; do
      i=$((i + 1)); [ "$i" -le 600 ] || break; sleep 0.1
   done
   ms=$(( ($(date +%s%N) - t0) / 1000000 ))
   check "$name: heater off again (after ${ms} ms)" heater_off
   wait_active && echo "      service active again"
}

kill9()  { kill -9 "$(podman inspect -f '{{.State.Pid}}' brewberrypi)"; }
hang()   { post /stub/hang; }
remove() { podman rm -f -t 0 brewberrypi >/dev/null; }

status() {
   check "strict_gpiod: persist_gpio_outputs is off" strict_gpiod
   check "SPI is off (no /dev/spidev*)" sh -c '! ls /dev/spidev* 2>/dev/null'
   check "1-Wire master present (w1-gpio)" test -d /sys/bus/w1/devices
   check "hardware watchdog device present" test -e /dev/watchdog0
   check "systemd pets the hardware watchdog (RuntimeWatchdogUSec=14s)" sh -c 'systemctl show -p RuntimeWatchdogUSec | grep -q =14s'
   check "brewberrypi.service has WatchdogSec=20s" sh -c 'systemctl show brewberrypi.service -p WatchdogUSec | grep -q =20s'
   check "brewberrypi.service runs brewberrypi-outputs-off after stop" sh -c 'systemctl show brewberrypi.service -p ExecStopPost | grep -q brewberrypi-outputs-off'
   check "heater BCM 23 off (high)" heater_off
   check "pump BCM 22 off (high)" test "$(level 22)" = hi
   check "buzzer BCM 10 off (low)" test "$(level 10)" = lo
   echo; pinctrl get 10,22,23
}

case ${1:-status} in
   status)  status ;;
   enable)  printf '{"allowHeat": true}\n' > "$STUB_JSON.tmp" && sync "$STUB_JSON.tmp" && mv "$STUB_JSON.tmp" "$STUB_JSON" && sync -f /data
            systemctl restart brewberrypi.service && echo "heater test enabled" ;;
   disable) rm -f "$STUB_JSON" && sync -f /data && systemctl restart brewberrypi.service && echo "heater test disabled" ;;
   kill9)   scenario "kill -9" kill9 ;;
   hang)    scenario "hang (watchdog)" hang ;;
   rm)      scenario "container removed" remove ;;
   heat)    wait_active && post "/stub/heat?on=1" && sleep 1 && check "heater is on: now pull the plug" heater_on ;;
   *)       echo "usage: os3-check.sh status|enable|kill9|hang|rm|heat|disable" >&2; exit 2 ;;
esac
exit "$fail"
