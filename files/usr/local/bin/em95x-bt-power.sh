#!/bin/sh
# Power the RTL8723BS BT core and leave it in ROM state before the WiFi side
# initialises.  hci_uart is deliberately not loaded here; the firmware download
# is deferred until the link is up (em95x-bt-delay.conf, em95x-bt-load.sh).
#
# The combo chip shares one radio between WiFi and Bluetooth.  If the BT core is
# left in reset while r8723bs initialises, wlan0 loses its first association
# attempts for 1.5-3 minutes; the same happens if the BT firmware is running
# during that window.  A powered core running ROM code is the state the WiFi
# side needs, so the reset line is pulsed low->high here and then left alone.
#
# GPIOX_17 = periphs-banks line 96 (gpiochip base + 96).  em95x-bt-power.service
# orders this before NetworkManager.service, which places it at ~10.5 s on the
# tested image: after the pinctrl gpiochip appears (~10.4 s) and ~3.4 s before
# r8723bs probes the WiFi side (~13.8 s).

LINE=96

log() { logger -t em95x-bt "$*" 2>/dev/null || true; }

base=""
tries=0
while [ "$tries" -lt 20 ]; do
	for c in /sys/class/gpio/gpiochip*; do
		[ -e "$c/label" ] || continue
		if [ "$(cat "$c/label" 2>/dev/null)" = periphs-banks ]; then
			base=$(cat "$c/base" 2>/dev/null)
			break
		fi
	done
	[ -n "$base" ] && break
	sleep 1
	tries=$((tries + 1))
done

if [ -z "$base" ]; then
	log "no periphs-banks gpiochip after ${tries}s, BT core left alone"
	exit 1
fi

n=$((base + LINE))
G=/sys/class/gpio/gpio$n

# already powered by an earlier run: do not pulse the BT core a second time
if [ -d "$G" ] && [ "$(cat "$G/direction" 2>/dev/null)" = out ] && [ "$(cat "$G/value" 2>/dev/null)" = 1 ]; then
	exit 0
fi

if [ ! -d "$G" ]; then
	echo "$n" > /sys/class/gpio/export 2>/dev/null || true
	# the gpio class can take a moment to create the attribute directory
	c=0
	while [ ! -d "$G" ] && [ "$c" -lt 10 ]; do
		sleep 0.2
		c=$((c + 1))
	done
fi

echo out > "$G/direction" 2>/dev/null || true
# pulse low -> high so the BT core always restarts from ROM, even if a warm
# reboot left it running a previously loaded firmware
echo 0 > "$G/value" 2>/dev/null || true
sleep 0.2
echo 1 > "$G/value" 2>/dev/null || true

if [ "$(cat "$G/value" 2>/dev/null)" = 1 ]; then
	log "BT core powered (gpio$n high, ROM state)"
else
	log "failed to drive gpio$n high"
	exit 1
fi
