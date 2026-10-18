#!/bin/bash
# Tests for the Wi-Fi setup (ADR-0004, OS11) with a fake root
# (BREWBERRY_WIFI_ROOT), a fake clock (BREWBERRY_WIFI_CLOCK) and fake nmcli,
# iw, nft, hostname and systemctl: brewberry-wifi changes wifi.json (0600,
# checked), brewberry-wifi-manager renders the profiles, opens the hotspot
# without a home network (never open without the firewall rule), retries
# only while nobody is on the hotspot, stops trying a wrong password, and
# moves Imager's netplan Wi-Fi into wifi.json. Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SBIN=$ROOT_DIR/layer/brewberry-wifi.rootfs-overlay/usr/local/sbin
WIFI=$SBIN/brewberry-wifi
MANAGER=$SBIN/brewberry-wifi-manager
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export BREWBERRY_LIB=$ROOT_DIR/layer/brewberry-base.rootfs-overlay/usr/lib/brewberry
export BREWBERRY_WIFI_LIB=$ROOT_DIR/layer/brewberry-wifi.rootfs-overlay/usr/lib/brewberry
export BREWBERRY_WIFI_ROOT=$T/root BREWBERRY_WIFI_CLOCK=$T/clock
BREWBERRY_WIFI_OWNER="$(id -un):$(id -gn)"
export BREWBERRY_WIFI_OWNER
export LOG=$T/log FAKE=$T/fake
R=$BREWBERRY_WIFI_ROOT
CFG=$R/data/config/wifi.json
PROFILES=$R/run/NetworkManager/system-connections

mkdir -p "$T/bin"
# The device: $FAKE/active (profile on wlan0), $FAKE/state (NetworkManager's
# number), $FAKE/eth, $FAKE/scan (nmcli's terse list), $FAKE/clients, and
# $FAKE/up-<profile> (the error of a failing attempt; none: it connects).
cat > "$T/bin/nmcli" <<'FAKE'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do
   case $1 in --wait) shift 2 ;; *) opts+="$1 "; shift ;; esac
done
f() { cat "$FAKE/$1" 2> /dev/null || true; }
case "${opts:-}$*" in
   "-t -f DEVICE,TYPE device") [ -e "$FAKE/no-wifi" ] || echo "wlan0:wifi"; echo "eth0:ethernet" ;;
   "-t -f TYPE,STATE device") echo "wifi:x"; echo "ethernet:$(f eth)" ;;
   "-t -f GENERAL.STATE,GENERAL.CONNECTION device show wlan0")
      echo "GENERAL.STATE:$(f state) (whatever)"; echo "GENERAL.CONNECTION:$(f active)" ;;
   "-g IP4.ADDRESS device show wlan0")
      case $(f active) in brewberry-hotspot) echo "10.42.0.1/24" ;; "") ;; *) echo "192.168.1.23/24" ;; esac ;;
   "-g 802-11-wireless.ssid connection show "*) f "ssid-$4" ;;
   "-t -f SSID,SIGNAL,SECURITY device wifi list ifname wlan0 --rescan yes")
      [ "$(f active)" != brewberry-hotspot ] || exit 1 # no scans while it is the hotspot
      f scan ;;
   "connection up id "*)
      echo "nmcli up $4" >> "$LOG"
      if [ -s "$FAKE/up-$4" ]; then cat "$FAKE/up-$4" >&2; echo "" > "$FAKE/active"; echo 30 > "$FAKE/state"; exit 4; fi
      echo "$4" > "$FAKE/active"; echo 100 > "$FAKE/state" ;;
   "connection down id "*)
      echo "nmcli down $4" >> "$LOG"
      [ "$(f active)" != "$4" ] || { echo "" > "$FAKE/active"; echo 30 > "$FAKE/state"; } ;;
   "connection reload") echo "nmcli reload" >> "$LOG" ;;
   "device wifi rescan"*|"radio wifi on") ;;
   *) echo "fake nmcli: unexpected: ${opts:-}$*" >&2; exit 99 ;;
esac
FAKE
cat > "$T/bin/iw" <<'FAKE'
#!/bin/bash
case "$*" in
   "reg set "*) echo "iw $*" >> "$LOG" ;;
   "dev wlan0 station dump") for _ in $(seq 1 "$(cat "$FAKE/clients" 2> /dev/null || echo 0)"); do echo "Station 00:11:22:33:44:55 (on wlan0)"; done ;;
   *) exit 99 ;;
esac
FAKE
cat > "$T/bin/nft" <<'FAKE'
#!/bin/bash
[ ! -e "$FAKE/nft-fails" ] || exit 1
if [ "$1" = -f ]; then echo "nft load: $(tr -s ' \n' ' ' | grep -o 'iifname.*reset')" >> "$LOG"; touch "$FAKE/fw"
else echo "nft $*" >> "$LOG"; rm -f "$FAKE/fw"; fi
FAKE
printf '#!/bin/sh\necho brewberrypi\n' > "$T/bin/hostname"
printf '#!/bin/sh\necho active\n' > "$T/bin/systemctl"
chmod +x "$T"/bin/*
export PATH=$T/bin:$PATH

failures=0
expect() { # <description> <got> <want>
   if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; failures=1; fi
}
run() { RC=0; "$@" > "$T/out" 2> "$T/err" || RC=$?; }
fixture() {
   rm -rf "$R" "$FAKE"
   mkdir -p "$R/data/config" "$R/etc/netplan" "$FAKE"
   echo '{}' > "$R/data/config/config.json"
   echo 1000 > "$T/clock"
   echo "" > "$FAKE/active"; echo 30 > "$FAKE/state"; echo unavailable > "$FAKE/eth"; echo 0 > "$FAKE/clients"
   printf '%s\n' 'Home:72:WPA2' 'Nachbar\:WLAN:40:WPA1 WPA2' 'Cafe:30:--' > "$FAKE/scan"
   : > "$LOG"
}
tick() { "$MANAGER" tick 2>> "$T/manager.log"; }
at() { echo "$1" > "$T/clock"; tick; } # one round at time <t>
mode() { jq -r .mode "$R/run/brewberry-wifi/state.json"; }
active() { cat "$FAKE/active"; }
add() { printf '%s\n' "$2" | "$WIFI" add "$1" 2> "$T/err"; } # <ssid> <password>
logged() { grep -c -F -- "$1" "$LOG" || true; }
id_of() { printf 'brewberry-wifi-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-10)"; }

# --- brewberry-wifi -----------------------------------------------------------
fixture
add Home 'brew secret'
expect "add: saved first, readable only by its owner" "$(stat -c %a "$CFG") $(jq -c .networks "$CFG")" \
   '600 [{"ssid":"Home","password":"brew secret","hidden":false}]'
add 'My Hidden' 'hidden-pass'
expect "add: a network not in range is probed for (hidden), newest first" "$(jq -c '[.networks[] | [.ssid, .hidden]]' "$CFG")" \
   '[["My Hidden",true],["Home",false]]'
add 'Nachbar:WLAN' ''
expect "add: open network; an SSID with ':' from the scan" "$(jq -c '.networks[0]' "$CFG")" \
   '{"ssid":"Nachbar:WLAN","password":"","hidden":false}'
add Home 'new secret 2'
expect "add: a changed network replaces its entry and goes first" "$(jq -c '[.networks[] | .ssid]' "$CFG") $(jq -r '.networks[0].password' "$CFG")" \
   '["Home","Nachbar:WLAN","My Hidden"] new secret 2'
before=$(cat "$CFG")
run sh -c "printf 'short\n' | '$WIFI' add Shed"
expect "add: a password under 8 characters refused" "$RC $(cat "$CFG")" "1 $before"
run sh -c "printf 'longenough\n' | '$WIFI' add $(printf 'x%.0s' $(seq 1 33))"
expect "add: a name over 32 bytes refused" "$RC $(cat "$CFG")" "1 $before"
run "$WIFI" add
expect "add: usage" "$RC" 1

run "$WIFI" forget Shed
expect "forget: not configured" "$RC $(grep -c 'not one of' "$T/err")" "1 1"
run "$WIFI" forget 'My Hidden'
expect "forget: another network goes at once" "$RC $(jq -c '[.networks[] | .ssid]' "$CFG")" '0 ["Home","Nachbar:WLAN"]'
id_of Home > "$FAKE/active"; echo 100 > "$FAKE/state"; echo Home > "$FAKE/ssid-$(id_of Home)"
run "$WIFI" forget Home --json
expect "forget: the network the Pi is on asks first (exit 10, no brew warning)" \
   "$RC $(jq -r '.confirm | test("connected to .Home.") and (test("A brew") | not)' "$T/out") $(jq '.networks | length' "$CFG")" "10 true 2"
run "$WIFI" forget Home --yes
expect "forget --yes" "$RC $(jq -c '[.networks[] | .ssid]' "$CFG")" '0 ["Nachbar:WLAN"]'

run "$WIFI" country de
expect "country: two letters, upper case" "$RC $(jq -r .country "$CFG")" "0 DE"
run "$WIFI" country Deutschland
expect "country: anything else refused" "$RC $(jq -r .country "$CFG")" "1 DE"

printf 'hotspot pass\n' | "$WIFI" hotspot-password 2> "$T/err"
expect "hotspot-password: set" "$(jq -r .hotspot.password "$CFG") $(grep -c 'app can be used' "$T/err")" "hotspot pass 1"
run sh -c "printf '%s\n' $(printf 'a%.0s' $(seq 1 64)) | '$WIFI' hotspot-password"
expect "hotspot-password: no 64-digit keys" "$RC $(jq -r .hotspot.password "$CFG")" "1 hotspot pass"
printf '\n' | "$WIFI" hotspot-password 2> "$T/err"
expect "hotspot-password: empty makes it open, and says so" "$(jq -r .hotspot.password "$CFG")|$(grep -c 'app is blocked' "$T/err")" "|1"

echo '{"networks": [{"ssid": "x"' > "$CFG"
"$WIFI" status --json > "$T/out"
expect "status: an unusable wifi.json is reported" "$(jq -r .fileError "$T/out")" "wifi.json is not valid JSON"
add Home 'brew secret'
expect "add: an unusable wifi.json is backed up, new settings start empty" \
   "$(jq -c '[.networks[] | .ssid]' "$CFG") $(cat "$R"/data/config/backup/*/wifi.json) $(grep -c 'moved to' "$T/err")" \
   '["Home"] {"networks": [{"ssid": "x" 1'

# --- brewberry-wifi-manager: no networks -----------------------------------------
fixture
tick
expect "no networks: the hotspot at once, behind the firewall rule" \
   "$(mode) $(active) $(logged 'nft load: iifname "wlan0" tcp dport { 8080 } reject with tcp reset')" "hotspot brewberry-hotspot 1"
hs=$PROFILES/brewberry-hotspot.nmconnection
expect "hotspot profile: AP on 2.4 GHz at 10.42.0.1, no IPv6, open, root only" \
   "$(grep -cxE 'mode=ap|band=bg|method=shared|address1=10.42.0.1/24|method=disabled|autoconnect=false' "$hs") $(grep -c wifi-security "$hs") $(stat -c %a "$hs")" "6 0 600"
expect "hotspot profile: SSID = host name, as bytes" "$(sed -n 's/^ssid=//p' "$hs")" "98;114;101;119;98;101;114;114;121;112;105;"
"$WIFI" status --json > "$T/out"
expect "status: hotspot, open, app blocked" "$(jq -c '[.mode, .hotspot.ssid, .hotspot.open, .hotspot.appBlocked, .addresses]' "$T/out")" \
   '["hotspot","brewberrypi",true,true,["10.42.0.1/24"]]'
"$WIFI" status > "$T/out"
expect "status: text" "$(head -n 1 "$T/out")" 'wifi:      hotspot "brewberrypi" at 10.42.0.1, open: the app is blocked on it, 0 device(s) connected'
at 1005
expect "a round later: still up, nothing started twice" "$(logged 'nmcli up brewberry-hotspot')" 1

fixture
echo '{"server": {"port": 9000}}' > "$R/data/config/config.json"
tick
expect "firewall: the app's own port too" "$(logged 'tcp dport { 8080, 9000 }')" 1
fixture
touch "$FAKE/nft-fails"
tick
expect "no firewall rule: no open hotspot" "$(mode) $(logged 'nmcli up brewberry-hotspot')" "waiting 0"
rm "$FAKE/nft-fails"
at 1020
expect "... it tries again after 30 s" "$(mode)" waiting
at 1031
expect "... and opens the hotspot once the rule loads" "$(mode)" hotspot

fixture
printf '%s\n' '{"hotspot": {"password": "pass word\\x"}}' > "$CFG"
tick
expect "hotspot with a password: WPA2, no firewall rule" \
   "$(mode) $(grep -c '^key-mgmt=wpa-psk' "$hs") $(sed -n 's/^psk=//p' "$hs") $(logged 'nft load')" 'hotspot 1 pass\sword\\x 0'
printf '\n' | "$WIFI" hotspot-password 2> /dev/null
at 1005
expect "hotspot made open while up: restarted behind the rule" \
   "$(mode) $(logged 'nmcli down brewberry-hotspot') $(logged 'nmcli up brewberry-hotspot') $(logged 'nft load') $(grep -c wifi-security "$hs")" "hotspot 1 2 1 0"

fixture
echo '{"networks": [{"ssid": "x"' > "$CFG"
tick
expect "unusable wifi.json: open hotspot" "$(mode) $(jq -r .fileError "$R/run/brewberry-wifi/state.json")" "hotspot wifi.json is not valid JSON"

# --- with home networks ------------------------------------------------------------
fixture
add Home 'brew secret'; add Shed 'shed pass'
echo '{"networks": [{"ssid": "Shed", "password": "shed pass"}, {"ssid": "Home", "password": "brew secret"}], "country": "DE"}' > "$CFG"
tick
home=$PROFILES/$(id_of Home).nmconnection
expect "client profiles: in order, root only, autoconnect" \
   "$(sed -n 's/^autoconnect-priority=//p' "$PROFILES/$(id_of Shed).nmconnection" "$home" | paste -sd ' ') $(stat -c %a "$home") $(grep -c '^autoconnect=true' "$home")" "100 99 600 1"
expect "client profile: SSID as bytes, WPA-PSK, escaped key" \
   "$(sed -n 's/^ssid=//p' "$home") $(sed -n 's/^psk=//p' "$home")" '72;111;109;101; brew\ssecret'
expect "country set once" "$(logged 'iw reg set DE')" 1
expect "with networks: no hotspot at first" "$(mode) $(active)" "waiting "
at 1085
expect "... not before 90 s" "$(mode)" waiting
echo 70 > "$FAKE/state"
at 1095
expect "... nor while NetworkManager is connecting" "$(mode)" waiting
echo 30 > "$FAKE/state"
at 1100
expect "... then the hotspot" "$(mode) $(active) $(logged 'iw reg set DE')" "hotspot brewberry-hotspot 1"
echo 1 > "$FAKE/clients"
at 1300
expect "retry due, but a device is on the hotspot: no attempt" "$(mode) $(logged 'nmcli down brewberry-hotspot')" "hotspot 0"
echo 0 > "$FAKE/clients"
at 1310
expect "retry with nobody on the hotspot: Shed not in range, Home connects" \
   "$(mode) $(active) $(logged "nmcli up $(id_of Shed)") $(logged 'nft delete table inet brewberry_wifi')" "home $(id_of Home) 0 1"
echo Home > "$FAKE/ssid-$(id_of Home)"
"$WIFI" status --json > "$T/out"
expect "status: home network, last try" "$(jq -c '[.mode, .network, .last.result, .hotspot.active]' "$T/out")" '["home","Home","connected",false]'
expect "scan saved for the CLI" "$(jq -c '[.networks[].ssid]' "$R/run/brewberry-wifi/scan.json")" '["Home","Nachbar:WLAN","Cafe"]'

# A drop at home: the hotspot after 90 s, then the wrong password.
echo "" > "$FAKE/active"; echo 30 > "$FAKE/state"
at 1320
at 1415
expect "dropped at home: the hotspot after 90 s" "$(mode)" hotspot
echo 'Error: Connection activation failed: Secrets were required, but not provided.' > "$FAKE/up-$(id_of Home)"
at 1600
expect "wrong password: marked, hotspot back" "$(mode) $(jq -r '.failed.Home.reason' "$R/run/brewberry-wifi/state.json")" "hotspot wrong password"
at 1605
expect "the marked network is no longer autoconnected" "$(grep -c '^autoconnect=false' "$home")" 1
"$WIFI" status --json > "$T/out"
expect "status: the network's problem" "$(jq -c '[.networks[] | select(.ssid == "Home") | .problem]' "$T/out")" '["wrong password"]'
ups=$(logged "nmcli up $(id_of Home)")
at 1800
expect "no more attempts at it; Shed, out of range, is still looked for" \
   "$(logged "nmcli up $(id_of Home)") $(grep -c 'trying the home networks' "$T/manager.log")" "$ups 3"
rm "$FAKE/up-$(id_of Home)"
echo 1 > "$FAKE/clients"
add Home 'right secret'
at 1805
expect "changed entry: tried at once, though a device is on the hotspot" \
   "$(mode) $(jq -r '.failed.Home // "cleared"' "$R/run/brewberry-wifi/state.json") $(cat "$T/clock")" "home cleared 1813"

echo connected > "$FAKE/eth"
echo "brewberry-hotspot" > "$FAKE/active"
at 1820
expect "Ethernet: no hotspot" "$(mode) $(active)" "ethernet "

fixture
echo '{"networks": [{"ssid": "Gone", "password": "", "hidden": true}]}' > "$CFG"
tick
echo '{"networks": []}' > "$CFG"
at 1005
expect "a network removed: its profile goes" "$(find "$PROFILES" -name 'brewberry-wifi-*' | wc -l)" 0

fixture
echo 'Some Other' > "$FAKE/ssid-netplan-wlan0-Some"
echo "netplan-wlan0-Some" > "$FAKE/active"; echo 100 > "$FAKE/state"
tick
expect "connected by another profile: home" "$(mode) $(jq -r .network "$R/run/brewberry-wifi/state.json")" "home Some Other"

fixture
touch "$FAKE/no-wifi"
tick
expect "no Wi-Fi device: nothing to do" "$(mode)" no-wifi

# --- first boot: Imager's Wi-Fi ----------------------------------------------------
fixture
cat > "$R/etc/netplan/50-cloud-init.yaml" <<'EOF'
network:
  version: 2
  wifis:
    renderer: NetworkManager
    wlan0:
      dhcp4: true
      regulatory-domain: "de"
      access-points:
        "Home":
          password: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        "Hidden Net":
          hidden: true
          auth:
            key-management: psk
            password: "hidden secret"
      optional: true
EOF
cat > "$R/etc/netplan/60-other.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
  wifis:
    wlan0:
      access-points:
        "Shed":
          password: "shed pass"
EOF
echo '{"networks": [{"ssid": "Shed", "password": "mine wins"}]}' > "$CFG"
"$MANAGER" migrate 2> "$T/err"
expect "migrate: Imager's networks and country added, the file's own entry kept" \
   "$(jq -c '[.country, [.networks[] | [.ssid, .hidden, (.password | length)]]]' "$CFG") $(jq -r '.networks[0].password' "$CFG") $(stat -c %a "$CFG")" \
   '["DE",[["Shed",false,9],["Home",false,64],["Hidden Net",true,13]]] mine wins 600'
expect "migrate: netplan keeps no Wi-Fi" "$(ls "$R/etc/netplan") $(grep -c wifis "$R/etc/netplan/60-other.yaml") $(grep -c eth0 "$R/etc/netplan/60-other.yaml") $(stat -c %a "$R/etc/netplan/60-other.yaml")" \
   "60-other.yaml 0 1 600"
run "$MANAGER" migrate
expect "migrate: nothing left to move" "$RC $(grep -c 'nothing to move' "$T/err")" "0 1"

exit "$failures"
