#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS11 hardware check (Wi-Fi setup through a fallback hotspot, ADR-0004), run on the device as root:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os11-check.sh
#   ssh <user>@10.42.0.1 'sudo sh -s -- hotspot' < tests/hardware/os11-check.sh   # while the hotspot is up
#
# run: the services, the redirect on port 80, the profiles in /run, wifi.json
# and the Wi-Fi status. hotspot: the hotspot's address, no IPv6 on it, the
# firewall rule while it is open, dnsmasq. The steps on a phone and a laptop
# (captive portal, joining a network, a wrong password, the router switched
# off and on, a brew through every switch) are in tests/hardware/README.md.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
listens() { ss -Hltn "sport = :$1" | grep -q .; }
status() { brewberry-wifi status --json; }
dev() { nmcli -t -f DEVICE,TYPE device | awk -F: '$2 == "wifi" { print $1; exit }'; }
redirects() { # <host> <expected Location>
   test "$(curl -s -o /dev/null -w '%{redirect_url}' -H "Host: $1" http://127.0.0.1/)" = "$2"
}
profiles_private() { ! find /run/NetworkManager/system-connections -name 'brewberry-*' ! -perm 0600 | grep -q .; }
wifi_json_ok() { [ ! -e /data/config/wifi.json ] || [ "$(stat -c %a /data/config/wifi.json)" = 600 ] || [ "$(stat -c %a /data/config/wifi.json)" = 644 ]; }

run() {
   check "brewberry-wifi.service is enabled and active" sh -c 'systemctl is-enabled --quiet brewberry-wifi.service && systemctl is-active --quiet brewberry-wifi.service'
   check "brewberry-wifi-migrate ran on the first boot (or had nothing to do)" sh -c '! systemctl is-failed --quiet brewberry-wifi-migrate.service'
   check "port 80 redirects (brewberry-portal.socket)" listens 80
   check "a foreign host name goes to the Wi-Fi page" redirects captive.apple.com "http://127.0.0.1:8081/#wifi"
   check "the Pi's own name goes to port 8081" redirects "$(hostname).local" "http://$(hostname).local:8081/"
   check "the hotspot profile exists, root only" sh -c 'test -f /run/NetworkManager/system-connections/brewberry-hotspot.nmconnection'
   check "every BrewberryPi profile is 0600" profiles_private
   check "dnsmasq answers every name with the Pi on the hotspot" grep -qx 'address=/#/10.42.0.1' /etc/NetworkManager/dnsmasq-shared.d/brewberry-portal.conf
   check "nftables.service is not used" sh -c '! systemctl is-enabled --quiet nftables.service'
   check "wifi.json, if any, is not world-writable" wifi_json_ok
   check "brewberry-wifi status --json reports a mode" sh -c 'brewberry-wifi status --json | jq -e ".mode | IN(\"home\", \"hotspot\", \"ethernet\", \"waiting\")"'
   check "no netplan Wi-Fi left (moved into wifi.json)" sh -c '! grep -rqs "wifis:" /etc/netplan'
   check "brewberry-system logs wifi shows the service" sh -c 'brewberry-system logs wifi --json | jq -e ".lines | length > 0"'
   check "the app is untouched by Wi-Fi changes (brewberrypi.service active)" systemctl is-active --quiet brewberrypi.service
}

hotspot() {
   d=$(dev)
   check "the Pi is on its hotspot" sh -c 'brewberry-wifi status --json | jq -e ".mode == \"hotspot\""'
   check "the hotspot's address is 10.42.0.1" sh -c "ip -4 -br address show dev $d | grep -q '10.42.0.1/24'"
   check "no IPv6 address on the hotspot" sh -c "! ip -6 address show dev $d | grep -q inet6"
   check "NetworkManager's dnsmasq runs for the hotspot" pgrep -f 'dnsmasq.*NetworkManager'
   if status | jq -e '.hotspot.open' > /dev/null; then
      check "open hotspot: the firewall rule keeps the app off it" sh -c "nft list table inet brewberry_wifi | grep -q 'iifname \"$d\"'"
   else
      check "hotspot with a password: no firewall rule" sh -c '! nft list table inet brewberry_wifi'
   fi
}

case ${1:-} in
   run) run ;;
   hotspot) hotspot ;;
   *) echo "usage: os11-check.sh run|hotspot" >&2; exit 2 ;;
esac
exit "$fail"
