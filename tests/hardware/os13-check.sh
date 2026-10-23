#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS13 hardware check (the app on port 80, ADR-0006), run on the device as root:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os13-check.sh
#
# run: the forward rule follows the app's port and leaves the hotspot address
# alone. Port 80 from another machine (the forward works only for traffic that
# arrives over the network) is in tests/hardware/README.md.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
port() { jq -r '.server.port // 8080' /data/config/app/config.json 2>/dev/null || echo 8080; }
rules() { nft list table inet brewberry-app; }
forwards() { rules | grep -q "tcp dport 80 redirect to :$(port)"; }
own_only() { rules | grep -q 'fib daddr type local'; }
not_hotspot() { rules | grep -q 'ip daddr 10.42.0.1 return'; }

run() {
   check "brewberrypi.service is active" systemctl is-active --quiet brewberrypi.service
   check "the unit loads the rule before the app starts" \
      sh -c 'systemctl show brewberrypi.service -p ExecStartPre | grep -q brewberrypi-port80'
   check "port 80 is forwarded to the app's port $(port)" forwards
   check "only connections to the Pi's own addresses" own_only
   check "not on the setup hotspot's address" not_hotspot
   check "nftables.service is disabled (no ruleset flush at boot)" sh -c '! systemctl is-enabled --quiet nftables.service'
   check "the captive portal still listens on port 80" sh -c "ss -Hltn 'sport = :80' | grep -q ."
}

case ${1:-} in
   run) run ;;
   *) echo "usage: os13-check.sh run" >&2; exit 2 ;;
esac
exit "$fail"
