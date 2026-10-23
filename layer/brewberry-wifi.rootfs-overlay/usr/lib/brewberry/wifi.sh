# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are for the scripts that source it
# Shared by brewberry-wifi (the operator command) and brewberry-wifi-manager
# (the service) (ADR-0004, OS11): where the settings and the state live,
# reading and checking wifi.json, and what NetworkManager says about the Wi-Fi.
#
# Source after common.sh, with R set to the root ("" on the device, a fake
# root in tests/unit/wifi.sh).
#
# /data/config/os/wifi.json (in the file share; the CLI writes it 0600):
#   {"country": "DE",
#    "networks": [{"ssid": "Home", "password": "…", "hidden": false}],
#    "hotspot": {"password": ""}}
# A password is the passphrase (8-63 characters) or the 64-digit hex key, ""
# for an open network or hotspot. The networks are tried in this order.

WIFI_FILE=$R/data/config/os/wifi.json
WIFI_BACKUP_DIR=$R/data/config/os/backup
WIFI_STATE_DIR=$R/run/brewberry-wifi    # root only: entry keys are hashes of passwords
WIFI_STATE=$WIFI_STATE_DIR/state.json  # the service's state, read by the CLI
WIFI_SCAN=$WIFI_STATE_DIR/scan.json    # the service's last scan (none while the hotspot is up)
WIFI_LOCK=$WIFI_STATE_DIR/lock         # read-modify-write of wifi.json
NM_PROFILES=$R/run/NetworkManager/system-connections
HOTSPOT_ID=brewberry-hotspot
HOTSPOT_ADDRESS=10.42.0.1
# BREWBERRY_WIFI_OWNER is for tests: the share's user and group own the files in /data/config/os.
WIFI_OWNER=${BREWBERRY_WIFI_OWNER:-brewberry:brewberry-config}
WIFI_MAX_BYTES=65536
WIFI_EMPTY='{"country":null,"networks":[],"hotspot":{"password":""}}'

# jq: the first problem of a settings object, or "" when it is valid.
# shellcheck disable=SC2016  # jq program
WIFI_CHECK='
def control: explode | any(. < 32 or . == 127);
def ssid_ok: type == "string" and utf8bytelength >= 1 and utf8bytelength <= 32 and (control | not);
def key_ok: type == "string" and (. == "" or test("^[ -~]{8,63}$") or test("^[0-9A-Fa-f]{64}$"));
if type != "object" then "not a JSON object"
elif (.country // null) != null and ((.country | type) != "string" or (.country | test("^[A-Z]{2}$") | not))
   then "country: two capital letters, such as DE"
elif (.networks // []) | type != "array" then "networks: a list"
elif any((.networks // [])[]; type != "object" or (.ssid | ssid_ok | not))
   then "networks: every entry needs an ssid of 1 to 32 bytes"
elif any((.networks // [])[]; (.password // "") | key_ok | not)
   then "networks: a password has 8 to 63 characters (or 64 hex digits), or is empty"
elif any((.networks // [])[]; (.hidden // false) | type != "boolean")
   then "networks: hidden is true or false"
elif ([(.networks // [])[].ssid] | length) != ([(.networks // [])[].ssid] | unique | length)
   then "networks: an ssid is listed twice"
elif (.hotspot // {}) | type != "object" then "hotspot: an object"
elif (.hotspot.password // "") | (type != "string" or (. != "" and (test("^[ -~]{8,63}$") | not)))
   then "hotspot: the password has 8 to 63 characters, or is empty"
else "" end'
WIFI_NORMAL='{country: (.country // null),
   networks: [(.networks // [])[] | {ssid, password: (.password // ""), hidden: (.hidden // false)}],
   hotspot: {password: (.hotspot.password // "")}}'

# Sets WIFI_JSON (normalised settings) and WIFI_ERROR (why the file can't be
# used, or ""). A missing or unusable file means no networks and an open
# hotspot, so the Pi can always be reached to fix it.
wifi_read() {
   local raw err
   WIFI_ERROR="" WIFI_JSON=$WIFI_EMPTY
   [ -e "$WIFI_FILE" ] || return 0
   if [ "$(stat -c %s "$WIFI_FILE" 2> /dev/null || echo 0)" -gt "$WIFI_MAX_BYTES" ]; then
      WIFI_ERROR="wifi.json is larger than $WIFI_MAX_BYTES bytes"
      return 0
   fi
   if ! raw=$(jq -c -s 'if length == 1 then .[0] else error("not one JSON value") end' "$WIFI_FILE" 2> /dev/null); then
      WIFI_ERROR="wifi.json is not valid JSON"
      return 0
   fi
   err=$(jq -r "$WIFI_CHECK" <<< "$raw")
   if [ -n "$err" ]; then
      WIFI_ERROR="wifi.json: $err"
      return 0
   fi
   WIFI_JSON=$(jq -c "$WIFI_NORMAL" <<< "$raw")
}

# Writes settings (checked, normalised JSON) atomically, readable only by the
# share's user (the app container can't read it).
wifi_write() { # <json>
   local err
   err=$(jq -r "$WIFI_CHECK" <<< "$1")
   [ -z "$err" ] || die "not saved: $err"
   rm -f "$WIFI_FILE.tmp"
   (umask 077; jq "$WIFI_NORMAL" <<< "$1" | write_atomic "$WIFI_FILE")
   chown "$WIFI_OWNER" "$WIFI_FILE"
}

wifi_lock() {
   install -d -m 0700 "$WIFI_STATE_DIR"
   exec 9> "$WIFI_LOCK"
   flock -w 30 9 || die "wifi.json is locked by another command"
}

# Checks for an SSID and a password given to the CLI ("" when fine).
wifi_ssid_problem() { # <ssid>
   local bytes
   bytes=$(printf '%s' "$1" | wc -c)
   if [ "$bytes" -lt 1 ] || [ "$bytes" -gt 32 ]; then
      echo "the network name has 1 to 32 bytes"
   elif [[ $1 =~ [[:cntrl:]] ]]; then
      echo "the network name has control characters"
   fi
}
wifi_key_problem() { # <password> <what>
   if [ -n "$1" ] && ! [[ $1 =~ ^[\ -~]{8,63}$ ]] && ! [[ $1 =~ ^[0-9A-Fa-f]{64}$ ]]; then
      echo "the $2 has 8 to 63 characters (letters, digits, spaces and ASCII symbols), or is empty"
   fi
}

# NetworkManager's name of the profile for a network.
wifi_id() { # <ssid>
   printf 'brewberry-wifi-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-10)"
}

# Identifies a network's entry, so a mark ("wrong password") ends when the
# entry changes. Never written anywhere but /run.
wifi_entry_key() { # <ssid> <password>
   printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-16
}

# The hotspot's name: the host name, cut to the 32 bytes an SSID may have.
wifi_hotspot_ssid() {
   hostname | head -c 32
}

# The Wi-Fi device, or nothing.
wifi_device() {
   nmcli -t -f DEVICE,TYPE device 2> /dev/null | awk -F: '$2 == "wifi" { print $1; exit }'
}

ethernet_connected() {
   nmcli -t -f TYPE,STATE device 2> /dev/null | grep -qx 'ethernet:connected'
}

nm_unescape() { sed 's/\\:/:/g; s/\\\\/\\/g'; }

# Sets DEV_STATE (NetworkManager's number: 100 connected, 40-90 connecting,
# 30 disconnected) and DEV_CON (the active profile, or "").
wifi_device_state() { # <device>
   local out
   out=$(nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION device show "$1" 2> /dev/null || true)
   DEV_STATE=$(sed -n 's/^GENERAL\.STATE:\([0-9]*\).*/\1/p' <<< "$out")
   DEV_STATE=${DEV_STATE:-0}
   DEV_CON=$(sed -n 's/^GENERAL\.CONNECTION://p' <<< "$out" | nm_unescape)
   [ "$DEV_CON" != -- ] || DEV_CON=""
}

wifi_connection_ssid() { # <profile>
   nmcli -g 802-11-wireless.ssid connection show "$1" 2> /dev/null | nm_unescape || true
}

wifi_addresses() { # <device>: IPv4 addresses, one per line
   nmcli -g IP4.ADDRESS device show "$1" 2> /dev/null | tr '|' '\n' | sed 's/^ *//; s/ *$//; /^$/d' || true
}

wifi_clients() { # <device>: devices connected to the hotspot
   iw dev "$1" station dump 2> /dev/null | grep -c '^Station' || true
}

# Networks in range as a JSON list [{ssid, signal, security}], strongest
# first; fails when the device can't scan (as while it is the hotspot).
wifi_scan_live() { # <device>
   local out line security rest signal ssid
   out=$(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$1" --rescan yes 2> /dev/null) || return 1
   while IFS= read -r line; do
      # SIGNAL and SECURITY never hold ':'; the SSID may (escaped as \:).
      security=${line##*:}; rest=${line%:*}; signal=${rest##*:}; ssid=${rest%:*}
      ssid=$(nm_unescape <<< "$ssid")
      [ -n "$ssid" ] || continue
      printf '%s\t%s\t%s\n' "$ssid" "$signal" "$security"
   done <<< "$out" | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t")
      | {ssid: .[0], signal: (.[1] | tonumber? // 0), security: (if (.[2] // "--") == "--" then "" else .[2] end)})
      | group_by(.ssid) | map(max_by(.signal)) | sort_by(-.signal)'
}
