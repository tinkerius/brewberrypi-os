#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS12 hardware check (configuration folders app and os, ADR-0005, runtime
# contract 2), run on the device as root with the real app installed:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os12-check.sh
#
# run: the folders and their owners, the app's own config.json and recipes/,
# the container's group and mount, and a recipe written as brewberry (as the
# share and SSH write it) appearing in and leaving the app's recipe list
# without a restart.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
port() { jq -r '.server.port // 8080' /data/config/app/config.json 2>/dev/null || echo 8080; }
recipes() { curl -fsS "http://127.0.0.1:$(port)/api/recipes"; }
folder_ok() { # <path> <mode:user:group>
   test "$(stat -c %a:%U:%G "$1")" = "$2"
}
app_wrote_config() { jq -e '.hardware.heating.pin and .recipes.directory' /data/config/app/config.json; }
app_wrote_recipes() { test "$(find /data/config/app/recipes -maxdepth 1 -name '*.json' | wc -l)" -ge 1; }
in_group() { podman exec brewberrypi id -G | tr ' ' '\n' | grep -qx "$(getent group brewberry-config | cut -d: -f3)"; }
only_app_mounted() {
   test "$(podman inspect brewberrypi --format '{{range .Mounts}}{{.Source}}:{{.Destination}}:{{.RW}} {{end}}' |
      tr ' ' '\n' | grep /data/config)" = /data/config/app:/config:true
}
shows() { # <id>: within 10 s
   n=0
   while [ "$n" -lt 20 ]; do
      recipes | jq -e --arg id "$1" 'any(.[]; .id == $id)' && return 0
      sleep 0.5; n=$((n + 1))
   done
   return 1
}
gone() { # <id>: within 10 s
   n=0
   while [ "$n" -lt 20 ]; do
      recipes | jq -e --arg id "$1" 'all(.[]; .id != $id)' && return 0
      sleep 0.5; n=$((n + 1))
   done
   return 1
}
add_recipe() {
   su -s /bin/sh brewberry -c 'printf "%s\n" "{\"name\": \"OS12 check\", \"goals\": [{\"type\": \"MashIn\"}]}" > /data/config/app/recipes/OS12CHECK.json'
}

run() {
   check "/data/config is root's (0755)" folder_ok /data/config 755:root:root
   check "/data/config/app is 2775 brewberry:brewberry-config" folder_ok /data/config/app 2775:brewberry:brewberry-config
   check "/data/config/os is 2775 brewberry:brewberry-config" folder_ok /data/config/os 2775:brewberry:brewberry-config
   check "brewberry is in brewberry-config (SSH)" sh -c 'id -nG brewberry | tr " " "\n" | grep -qx brewberry-config'
   check "brewberrypi.service is active" systemctl is-active --quiet brewberrypi.service
   check "the app wrote config.json with its defaults" app_wrote_config
   check "the app created recipes/ with its shipped recipes" app_wrote_recipes
   check "the container has the group brewberry-config" in_group
   check "only /data/config/app is mounted, read-write, at /config" only_app_mounted
   check "os/wifi.json is not visible in the container" sh -c '! podman exec brewberrypi ls /config/wifi.json'
   check "a recipe saved as brewberry is written" add_recipe
   check "it shows in the app's recipe list within 10 s" shows OS12CHECK
   rm -f /data/config/app/recipes/OS12CHECK.json
   check "deleted, it leaves the recipe list within 10 s" gone OS12CHECK
}

case ${1:-} in
   run) run ;;
   *) echo "usage: os12-check.sh run" >&2; exit 2 ;;
esac
exit "$fail"
