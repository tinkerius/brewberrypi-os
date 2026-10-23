#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS10 hardware check (file share of /data/config, ADR-0003, ADR-0005), run on the device as root:
#
#   ssh <user>@brewberrypi.local 'sudo sh -s -- run' < tests/hardware/os10-check.sh
#
# run: smbd alone on port 445 and restarted when it fails, the share's
# settings, its password in step with brewberry's, file owners, the PAM hook,
# the outputs recorded at the app's start. Run it again after a reboot. The
# client side (log in from Windows, macOS or smbclient, change a file)
# is in tests/hardware/README.md.
set -u

fail=0
check() { # <description> <command...>
   desc=$1; shift
   if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
param() { testparm -s --suppress-prompt --parameter-name="$1" 2>/dev/null; }
listens() { ss -Hltn "sport = :$1" | grep -q .; }
password_in_step() {
   pdbedit -L | grep -q '^brewberry:' &&
      test "$(cat /data/secrets/samba/account-hash)" = "$(awk -F: '$1 == "brewberry" { print $2 }' /etc/shadow)"
}
comes_back() { # smbd is restarted after a crash
   systemctl kill -s KILL smbd.service
   sleep 8
   systemctl is-active --quiet smbd.service
}
# The app's own files belong to its UID 10001 until smbd's next start (ADR-0005).
owners_ok() { ! find /data/config -mindepth 1 \( \( ! -user brewberry ! -user 10001 \) -o ! -group brewberry-config \) | grep -q .; }
root_owned() { test "$(stat -c %U:%a /data/config)" = root:755; }
# Every file is writable by the group, so app, share and SSH can change it;
# wifi.json holds Wi-Fi passwords: brewberry-wifi writes it 0600 (ADR-0004).
modes_ok() { ! find /data/config -type f ! -perm -0060 ! -name wifi.json | grep -q .; }

run() {
   check "smbd.service is enabled and active" sh -c 'systemctl is-enabled --quiet smbd.service && systemctl is-active --quiet smbd.service'
   check "nmbd.service is not running (no NetBIOS)" sh -c '! systemctl is-active --quiet nmbd.service'
   check "port 445 is open" listens 445
   check "port 139 (NetBIOS) is closed" sh -c "! ss -Hltn 'sport = :139' | grep -q ."
   check "smb.conf loads" testparm -s --suppress-prompt
   check "SMB 3 only" test "$(param 'server min protocol')" = SMB3
   check "signing is required" test "$(param 'server signing')" = required
   check "no guests" test "$(param 'map to guest')" = Never
   check "only one share: config" test "$(testparm -s --suppress-prompt 2>/dev/null | grep -c '^\[')" = 2
   check "the passdb is on /data" test -f /data/secrets/samba/passdb.tdb
   check "/data/secrets/samba is 0700" test "$(stat -c %a /data/secrets/samba)" = 700
   check "the share has brewberry's password" password_in_step
   check "the PAM hook is in common-password" grep -q 'brewberry-share-sync pam' /etc/pam.d/common-password
   check "/data/config itself belongs to root (app and os can't be renamed)" root_owned
   check "files below /data/config belong to the group brewberry-config" owners_ok
   check "files below /data/config are group-writable" modes_ok
   check "mDNS announces the share" test -f /etc/avahi/services/brewberry-share.service
   check "brewberrypi.service records its outputs at start" \
      sh -c 'systemctl show brewberrypi.service -p ExecStartPre | grep -q "brewberrypi-outputs-off --record"'
   if systemctl is-active --quiet brewberrypi.service; then
      check "the running app's outputs are recorded" test -s /run/brewberrypi/outputs-started
   else
      echo "SKIP  the running app's outputs are recorded (the app is not running)"
   fi
   check "brewberry-system logs share shows smbd" sh -c 'brewberry-system logs share --json | jq -e ".lines | length > 0"'
   check "smbd comes back after a kill -9" comes_back
}

case ${1:-} in
   run) run ;;
   *) echo "usage: os10-check.sh run" >&2; exit 2 ;;
esac
exit "$fail"
