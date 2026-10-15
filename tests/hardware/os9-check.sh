#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS9 hardware check (device web interface, ADR-0002), run on the device as root:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run [password]' < tests/hardware/os9-check.sh
#   ssh <user>@brewberrypi.local 'sudo sh -s -- password <old> <new>' < tests/hardware/os9-check.sh
#   (reboot)
#   ssh <user>@brewberrypi.local 'sudo sh -s -- after-reboot <new>' < tests/hardware/os9-check.sh
#
# run: the services, login required, the same answers and prompts as the CLI, a
# job that survives a restart of the web server. password/after-reboot: a
# password changed in the browser survives the reboot. The password defaults
# to 'pi'. Uses the API on 127.0.0.1:8081, like the page does.
set -u

URL=http://127.0.0.1:8081
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT
fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
code() { # <method> <path> [json body]: the HTTP status
   if [ "$1" = GET ]; then
      curl -s -o /tmp/os9.body -w '%{http_code}' -b "$JAR" -c "$JAR" "$URL$2"
   else
      body=${3:-}
      [ -n "$body" ] || body='{}'
      curl -s -o /tmp/os9.body -w '%{http_code}' -b "$JAR" -c "$JAR" -X "$1" -H 'X-Brewberry: 1' \
         -H 'Content-Type: application/json' -d "$body" "$URL$2"
   fi
}
login() { [ "$(code POST /api/login "{\"password\": \"$1\"}")" = 200 ]; }
wait_job() { # <id>: until it is no longer running; prints its state
   n=0
   while [ $n -lt 300 ]; do
      code GET "/api/jobs/$1" > /dev/null
      s=$(jq -r .state /tmp/os9.body)
      [ "$s" = running ] || { echo "$s"; return; }
      sleep 1; n=$((n + 1))
   done
   echo timeout
}

run() { # [password]
   pw=${1:-pi}
   check "brewberry-web.service is active" systemctl is-active --quiet brewberry-web.service
   check "brewberry-webcmd.socket is listening" systemctl is-active --quiet brewberry-webcmd.socket
   check "the page answers on port 8081" sh -c "curl -sf $URL/ | grep -q 'BrewberryPi device'"
   check "the API needs a login" test "$(code GET /api/commands)" = 401
   check "a wrong password is refused" sh -c "! $(command -v curl) -sf -H 'X-Brewberry: 1' -d '{\"password\": \"wrong\"}' $URL/api/login"
   check "login as brewberry" login "$pw"
   check "a request without the page's header is refused" \
      test "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X POST -d '{}' "$URL/api/run/update.restart")" = 403

   code GET /api/run/update.status > /dev/null
   web=$(jq -r .output.active.version /tmp/os9.body)
   cli=$(brewberry-update status --json | jq -r .active.version)
   check "the app version is the CLI's ($cli)" test "$web" = "$cli"

   code POST /api/run/update.restart > /dev/null
   web=$(jq -r .confirm /tmp/os9.body)
   cli=$(brewberry-update restart --json < /dev/null | jq -r .confirm)
   check "restart asks with the CLI's words" test -n "$web" -a "$web" = "$cli"

   code POST /api/run/update.restart '{"yes": true}' > /dev/null
   job=$(jq -r .job /tmp/os9.body)
   sleep 1
   systemctl restart brewberry-web.service
   sleep 2
   check "login again after the web server restart" login "$pw"
   check "the restart job finished despite the web server restart" test "$(wait_job "$job")" = "done"
   check "the app runs again" systemctl is-active --quiet brewberrypi.service
   check "the job is in the log (brewberry-system logs web)" sh -c "brewberry-system logs web | grep -q 'brewberry-job-$job'"

   # shellcheck disable=SC2016  # expanded by the inner sh
   check "parity: every catalogue command has a CLI" sh -c '
      jq -r ".commands[] | select(.argv) | .argv[0]" /usr/share/brewberry/commands.json | sort -u |
      while read -r c; do command -v "$c" > /dev/null || exit 1; done'
}

password() { # <old> <new>
   check "login with the old password" login "$1"
   check "change the password in the browser" test "$(code POST /api/password "{\"old\": \"$1\", \"new\": \"$2\"}")" = 200
   sleep 2
   check "the new hash is saved on /data" sh -c \
      "test \"\$(cat /data/secrets/shadow.d/brewberry)\" = \"\$(getent shadow brewberry | cut -d: -f2)\""
   echo "now reboot, then run: after-reboot <new>"
}

after_reboot() { # <new>
   check "the new password works after the reboot" login "$1"
   check "no default-password reminder" sh -c "jq -e '.defaultPassword == false' /tmp/os9.body"
   check "the old default is refused" sh -c "! curl -sf -H 'X-Brewberry: 1' -d '{\"password\": \"pi\"}' $URL/api/login"
}

case ${1:-} in
   run) shift; run "$@" ;;
   password) [ $# -eq 3 ] || { echo "usage: password <old> <new>" >&2; exit 2; }; password "$2" "$3" ;;
   after-reboot) [ $# -eq 2 ] || { echo "usage: after-reboot <new>" >&2; exit 2; }; after_reboot "$2" ;;
   *) sed -n '2,13s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
[ "$fail" = 0 ] && echo "OS9 checks passed" || echo "OS9 checks FAILED"
exit "$fail"
