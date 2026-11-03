#!/bin/sh
# Load the RTL8723BS Bluetooth side once the WiFi link is up.
#
# The BT firmware download disturbs the radio shared with WiFi: run during WiFi
# initialisation it makes wlan0 lose its association attempts for 1.5-3 minutes.
# The same download after wlan0 is connected is harmless, so hci_uart is
# blacklisted (em95x-bt-delay.conf) and loaded from here instead.
#
# The BT core is powered from early boot by em95x-bt-power.sh.  This script only
# hands GPIOX_17 over to hci_uart and loads the module; it waits at most 120 s
# for the link and loads anyway afterwards, so a box with a dead AP does not end
# up without Bluetooth as well.

log() { logger -t em95x-bt "$*"; }

state() {
	nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: '$1 == "wlan0" { print $2; exit }'
}

waited=0
timeout=120
while [ "$waited" -lt "$timeout" ]; do
	if [ "$(state)" = connected ]; then
		break
	fi
	sleep 2
	waited=$((waited + 2))
done

# let NetworkManager finish the IP setup, then give the radio a moment to settle
sleep 5

# hand GPIOX_17 over to hci_uart: it requests the line through enable-gpios, so
# the sysfs export from em95x-bt-power.sh has to be released first
base=""
for c in /sys/class/gpio/gpiochip*; do
	[ -e "$c/label" ] || continue
	if [ "$(cat "$c/label")" = periphs-banks ]; then
		base=$(cat "$c/base")
		break
	fi
done
if [ -n "$base" ]; then
	n=$((base + 96))
	[ -d "/sys/class/gpio/gpio$n" ] && echo "$n" > /sys/class/gpio/unexport 2>/dev/null
fi

if /sbin/modprobe hci_uart 2>/dev/null; then
	log "hci_uart loaded after ${waited}s (wlan0=$(state))"
else
	log "modprobe hci_uart failed (wlan0=$(state))"
	exit 1
fi
