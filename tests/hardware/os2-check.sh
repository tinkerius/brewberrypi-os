#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS2 hardware check, run on the device as root:
#
#   ssh brewberry@brewberrypi.local 'sudo sh -s' < tests/hardware/os2-check.sh
#
# Then, from another machine: curl http://brewberrypi.local:8080/healthz
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then
      echo "PASS  $desc"
   else
      echo "FAIL  $desc"
      fail=1
   fi
}

in_app() { podman exec brewberrypi "$@"; }

config_seeded()       { test -f /data/config/config.json && jq -e 'type == "object"' /data/config/config.json; }
graphroot_on_data()   { test "$(podman info --format '{{.Store.GraphRoot}}')" = /data/containers/storage; }
active_tag_exists()   { podman image exists localhost/brewberrypi:active; }
service_active()      { systemctl is-active --quiet brewberrypi.service; }
runs_as_10001()       { test "$(in_app id -u)" = 10001; }
has_gpio_group()      { in_app id -G | tr ' ' '\n' | grep -qx "$(getent group gpio | cut -d: -f3)"; }
sees_gpiochips()      { in_app sh -c 'ls /dev/gpiochip*'; }
# shellcheck disable=SC2016  # expanded inside the container
gpiochip_rw()         { in_app sh -c 'for c in /dev/gpiochip*; do test -r "$c" && test -w "$c" || exit 1; done'; }
rootfs_read_only()    { ! in_app sh -c 'touch /probe' ; }
config_read_only()    { ! in_app sh -c 'touch /config/probe'; }
healthz_ok()          { in_app python3 -c 'import urllib.request as u; assert b"\"ok\"" in u.urlopen("http://127.0.0.1:8080/healthz").read()'; }

# systemctl restart must block until READY=1. The stub waits 2 s before READY.
restart_waits_ready() {
   t0=$(date +%s%N)
   systemctl restart brewberrypi.service || return 1
   ms=$(( ($(date +%s%N) - t0) / 1000000 ))
   echo "restart took ${ms} ms" >&2
   [ "$ms" -ge 2000 ] && systemctl is-active --quiet brewberrypi.service
}

check "/data/config/config.json exists (seeded {})"   config_seeded
check "Podman graphroot is /data/containers/storage"  graphroot_on_data
check "localhost/brewberrypi:active exists"            active_tag_exists
check "brewberrypi.service is active"                  service_active
check "app runs as UID 10001"                          runs_as_10001
check "app has the host gpio group"                    has_gpio_group
check "app sees /dev/gpiochip*"                        sees_gpiochips
check "app can open every gpiochip read-write"         gpiochip_rw
check "container root is read-only"                    rootfs_read_only
check "/config is read-only"                           config_read_only
check "GET /healthz answers ok"                        healthz_ok
check "systemctl restart waits for READY (>= 2 s)"     restart_waits_ready
echo
systemctl status --no-pager brewberrypi.service | head -n 5
exit "$fail"
