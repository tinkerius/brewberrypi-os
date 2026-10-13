#!/bin/sh
# shellcheck disable=SC2317  # the check functions are called indirectly by check()
# OS7 hardware check after flashing through the Imager manifest with
# customisation, run on the device as root:
#
#   ssh <user>@<hostname>.local 'sudo sh -s -- <hostname> <user> [<wifi ssid>]' < tests/hardware/os7-check.sh
#
# <hostname>, <user> and <wifi ssid> are what you entered in Imager. Leave the
# SSID out for a wired-only test.
set -u

HOST=${1:?usage: os7-check.sh <hostname> <user> [<wifi ssid>]}
USER_NAME=${2:?usage: os7-check.sh <hostname> <user> [<wifi ssid>]}
SSID=${3:-}

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

sealed()                { grep -q 'overlayroot=tmpfs:recurse=0' /proc/cmdline; }
# Imager's seed on the boot partition, not a fallback: older Imager versions
# add no ds=nocloud to the kernel command line.
customised()            { jq -r .v1.datasource /var/lib/cloud/data/status.json | grep -q '^DataSourceNoCloud .*file:///boot/firmware'; }
cloud_init_finished()   { test -e /var/lib/cloud/instance/boot-finished; }
cloud_init_no_errors()  { test "$(jq '[.v1[]?.errors? // [] | length] | add // 0' /var/lib/cloud/data/status.json)" = 0; }
cloud_init_disabled()   { test -e /etc/cloud/cloud-init.disabled && ! systemctl is-active --quiet cloud-init-main.service cloud-final.service; }
hostname_set()          { test "$(hostname)" = "$HOST"; }
user_has_key()          { test -s "$(getent passwd "$USER_NAME" | cut -d: -f6)/.ssh/authorized_keys"; }
user_has_password()     { test "$(passwd -S "$USER_NAME" | cut -d' ' -f2)" = P; }
user_groups()           { id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx sudo && id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx gpio; }
password_ssh_off()      { sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; }
password_ssh_on()       { sshd -T 2>/dev/null | grep -qx 'passwordauthentication yes'; }
root_ssh_off()          { sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'; }
nm_active()             { systemctl is-active --quiet NetworkManager.service; }
networkd_off()          { ! systemctl is-active --quiet systemd-networkd.service; }
wifi_connected()        { nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device | grep -q "^wlan0:wifi:connected:"; }
wifi_ssid()             { nmcli -t -f ACTIVE,SSID device wifi | grep -qx "yes:$SSID"; }
no_raspi_config()       { ! test -e /usr/bin/raspi-config; }
spi_still_off()         { grep -qx 'dtparam=spi=off' /boot/firmware/config.txt && ! ls /dev/spidev*; }

check "system is sealed (overlay root)"                     sealed
check "cloud-init read Imager's seed from /boot/firmware"   customised
check "cloud-init finished its first boot"                  cloud_init_finished
check "cloud-init reported no errors"                       cloud_init_no_errors
check "cloud-init is disabled and not running"              cloud_init_disabled
check "hostname is $HOST"                                   hostname_set
check "user $USER_NAME has a password (console login)"      user_has_password
check "user $USER_NAME is in the sudo and gpio groups"      user_groups
# Imager's SSH choice: "Use password authentication" writes ssh_pwauth: true.
if grep -qx 'ssh_pwauth: true' /boot/firmware/user-data; then
   check "SSH password login is on (Imager: password authentication)" password_ssh_on
else
   check "user $USER_NAME has an SSH key"                   user_has_key
   check "SSH password login is off"                        password_ssh_off
fi
check "SSH root login is off"                               root_ssh_off
check "NetworkManager is active"                            nm_active
check "systemd-networkd is not running"                     networkd_off
if [ -n "$SSID" ]; then
   check "wlan0 is connected"                               wifi_connected
   check "Wi-Fi network is $SSID"                           wifi_ssid
fi
check "raspi-config is not installed"                       no_raspi_config
check "SPI is still off (buzzer pin BCM 10)"                spi_still_off
echo
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device
exit "$fail"
