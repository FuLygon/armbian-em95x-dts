#!/bin/sh
#
# Installer for the EM95X support files on an ophub Amlogic Armbian system.
# README.md documents the hardware, the boot sequence and the reason for each
# file this script installs.
#
# Usage, on the box, from a checkout of this repository:
#
#     sudo ./install.sh
#
# The script is idempotent: a file is written only when its content or mode
# differs, /boot/uEnv.txt and /etc/ophub-release only when the value is wrong
# (timestamped backup first, APPEND= is never modified), and a unit is only
# reconfigured when its state is wrong.  If nothing differs it reports that and
# exits without offering a reboot.
#
# It installs files and unit state only; it does not install packages.
# Bluetooth additionally needs the bluez userspace package.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DTB=meson-gxl-s905x-em95x.dtb
UENV=/boot/uEnv.txt
STAMP=$(date +%Y%m%d-%H%M%S)

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CHANGED=0
UNITS_CHANGED=0

# --- sanity ---------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "run as root (sudo sh install.sh)"
[ -f "$HERE/dts/$DTB" ] || die "dts/$DTB not found next to this script"
[ -f "$HERE/files/etc/systemd/system/em95x-vfd-boot.service" ] || die "files/ tree missing"
[ -f /etc/ophub-release ] || die "not an ophub Armbian image (/etc/ophub-release missing)"
[ -f "$UENV" ] || die "$UENV not found (expected on amlogic ophub images)"
grep -q '^APPEND=' "$UENV" || die "$UENV has no APPEND= line, refusing to touch it"

# Known-good DTB.  A mismatch is not fatal (you may have rebuilt the DTS), but on a
# fresh copy it usually means the transfer corrupted the file.
DTB_MD5=a10d1fc4d9f141ab2f4bedea2bc54d94
src_md5=$(md5sum "$HERE/dts/$DTB" | cut -d' ' -f1)
if [ "$src_md5" != "$DTB_MD5" ]; then
	warn "dts/$DTB md5 is $src_md5, known good is $DTB_MD5."
	warn "Expected if you rebuilt the DTS yourself; otherwise the copy is corrupt."
fi

# put <mode> <source> <destination>
# Installs only when content or mode differs, so a re-run does not touch mtimes.
put() {
	put_mode=$1
	put_src=$2
	put_dst=$3
	put_same=0
	if [ -f "$put_dst" ] && [ ! -L "$put_dst" ]; then
		put_same=1
		# /boot is vfat on ophub images: no UNIX modes there, stat always says 755.
		case "$put_dst" in
		/boot/*) ;;
		*) [ "$(stat -c %a "$put_dst")" = "$put_mode" ] || put_same=0 ;;
		esac
		[ "$(md5sum "$put_src" | cut -d' ' -f1)" = "$(md5sum "$put_dst" | cut -d' ' -f1)" ] || put_same=0
	fi
	if [ "$put_same" -eq 1 ]; then
		return 0
	fi
	rm -f "$put_dst"
	install -D -m "$put_mode" "$put_src" "$put_dst"
	printf '    updated %s\n' "$put_dst"
	CHANGED=$((CHANGED + 1))
	case "$put_dst" in
	/etc/systemd/system/*) UNITS_CHANGED=1 ;;
	esac
	return 0
}

# --- 1. userspace files ---------------------------------------------------

say "1/6 userspace files -> /etc, /usr, /lib"
put 755 "$HERE/files/etc/custom_service/start_service.sh" /etc/custom_service/start_service.sh
put 644 "$HERE/files/etc/modprobe.d/em95x-bt-delay.conf" /etc/modprobe.d/em95x-bt-delay.conf
put 644 "$HERE/files/etc/systemd/system/em95x-vfd-boot.service" /etc/systemd/system/em95x-vfd-boot.service
put 644 "$HERE/files/etc/systemd/system/em95x-bt-load.service" /etc/systemd/system/em95x-bt-load.service
put 644 "$HERE/files/etc/systemd/system/em95x-bt-power.service" /etc/systemd/system/em95x-bt-power.service
put 755 "$HERE/files/usr/local/bin/em95x-vfd-boot" /usr/local/bin/em95x-vfd-boot
put 755 "$HERE/files/usr/local/bin/em95x-bt-load.sh" /usr/local/bin/em95x-bt-load.sh
put 755 "$HERE/files/usr/local/bin/em95x-bt-power.sh" /usr/local/bin/em95x-bt-power.sh
put 644 "$HERE/files/usr/share/openvfd/conf/diy.conf" /usr/share/openvfd/conf/diy.conf
# The BT blob must be a real file: on a fresh image this path is a symlink to
# rtl8723b_config.bin, and "put" replaces symlinks instead of writing through them.
put 644 "$HERE/files/lib/firmware/rtl_bt/rtl8723bs_config.bin" /lib/firmware/rtl_bt/rtl8723bs_config.bin

# --- 2. device tree -------------------------------------------------------

say "2/6 device tree -> /boot/dtb/amlogic/$DTB"
put 644 "$HERE/dts/$DTB" "/boot/dtb/amlogic/$DTB"

# --- 3. boot loader config ------------------------------------------------

say "3/6 boot config"
FDT_LINE="FDT=/dtb/amlogic/$DTB"
if grep -qxF "$FDT_LINE" "$UENV" && [ "$(grep -c '^FDT=' "$UENV")" -eq 1 ]; then
	printf '    FDT= in %s already correct\n' "$UENV"
else
	cp -a "$UENV" "$UENV.bak.$STAMP"
	if grep -q '^FDT=' "$UENV"; then
		sed -i "s|^FDT=.*|$FDT_LINE|" "$UENV"
	else
		printf '%s\n' "$FDT_LINE" >> "$UENV"
	fi
	CHANGED=$((CHANGED + 1))
	printf '    FDT= set in %s (backup: %s.bak.%s)\n' "$UENV" "$UENV" "$STAMP"
fi

FDTFILE_LINE="FDTFILE='$DTB'"
if grep -qxF "$FDTFILE_LINE" /etc/ophub-release && [ "$(grep -c '^FDTFILE=' /etc/ophub-release)" -eq 1 ]; then
	printf '    FDTFILE= in /etc/ophub-release already correct\n'
else
	cp -a /etc/ophub-release "/etc/ophub-release.bak.$STAMP"
	if grep -q '^FDTFILE=' /etc/ophub-release; then
		sed -i "s|^FDTFILE=.*|$FDTFILE_LINE|" /etc/ophub-release
	else
		printf '%s\n' "$FDTFILE_LINE" >> /etc/ophub-release
	fi
	CHANGED=$((CHANGED + 1))
	printf '    FDTFILE= set in /etc/ophub-release (backup: /etc/ophub-release.bak.%s)\n' "$STAMP"
fi

# --- 4. systemd -----------------------------------------------------------

say "4/6 systemd units"
if [ "$UNITS_CHANGED" -eq 1 ]; then
	systemctl daemon-reload
	printf '    daemon-reload (unit files changed)\n'
fi
for u in em95x-vfd-boot.service em95x-bt-load.service em95x-bt-power.service; do
	if systemctl is-enabled --quiet "$u" 2>/dev/null; then
		printf '    %s already enabled\n' "$u"
	else
		systemctl enable "$u" >/dev/null 2>&1 ||
			printf '    could not enable %s\n' "$u"
		CHANGED=$((CHANGED + 1))
		printf '    %s enabled\n' "$u"
	fi
done
# The power LED is driven by the DT alone (default-state="on" -> blue from the
# moment gpio-leds probes), so armbian-led-state.service has nothing to do here
# and is broken anyway: its state file contains the openvfd LED class, and the
# restore script aborts on the empty "led_cmd=" line ("Invalid state file")
# after it has already written trigger=none to openvfd, blanking the 7-seg at
# basic.target.  Masked = cannot come back through a package upgrade either.
if [ "$(systemctl is-enabled armbian-led-state.service 2>/dev/null || true)" = masked ]; then
	printf '    armbian-led-state.service already masked\n'
else
	systemctl disable --now armbian-led-state.service >/dev/null 2>&1 || true
	systemctl mask armbian-led-state.service >/dev/null 2>&1 || true
	CHANGED=$((CHANGED + 1))
	printf '    armbian-led-state.service masked\n'
fi
# Only needed by rpc-statd-notify (NFS) here, and it does not bring the link up --
# it blocks network-online.target until nm-online sees a configured connection
# (30 s default).  A slow/absent AP then shows up as a failed unit and delays
# rc-local, i.e. the 7-seg handover from BOOT to the clock.  Disabled, rc-local
# runs at ~15 s whether or not WiFi is up.
if systemctl is-enabled --quiet NetworkManager-wait-online.service 2>/dev/null; then
	systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true
	CHANGED=$((CHANGED + 1))
	printf '    NetworkManager-wait-online.service disabled\n'
else
	printf '    NetworkManager-wait-online.service already disabled\n'
fi

# --- 5. checks ------------------------------------------------------------

say "5/6 checks"
if ! modinfo -n openvfd >/dev/null 2>&1; then
	warn "kernel module 'openvfd' not found for $(uname -r)."
	warn "The 7-seg needs the ophub kernel (it ships openvfd); everything else works without it."
fi
if [ ! -x /usr/sbin/armbian-openvfd ]; then
	warn "/usr/sbin/armbian-openvfd is missing: the clock will never take over from BOOT."
	warn "Expected on ophub images (package armbian-openvfd)."
fi
# On newer images BOOT_CONF says uEnv.conf, but the amlogic u-boot script still reads
# uEnv.txt, so trust the script itself rather than the release metadata.
if ! grep -qa 'uEnv\.txt' /boot/boot.scr /boot/boot.ini /boot/boot.cmd 2>/dev/null; then
	warn "no boot script under /boot reads uEnv.txt (image may use extlinux.conf):"
	warn "FDT= in $UENV might be ignored, check which dtb the box actually boots."
fi
# A fresh image has no wifi profile until the first-login wizard has run. Without
# one, em95x-bt-load.sh falls back to its 120 s timeout before loading BT.
if command -v nmcli >/dev/null 2>&1 &&
	! nmcli -t -f TYPE con show 2>/dev/null | grep -qx '802-11-wireless'; then
	warn "no WiFi profile configured yet: BT will only load after 120 s."
	warn "Configure WiFi (armbian-config or nmcli) and re-run, or accept that."
fi
if [ "$(stat -c %s /lib/firmware/rtl_bt/rtl8723bs_config.bin 2>/dev/null || echo 0)" -ne 68 ]; then
	warn "rtl8723bs_config.bin is not 68 bytes, BT will probably fail with -110."
fi

# --- 6. summary and reboot ------------------------------------------------

say "6/6 done"
printf '\n'
grep -E '^(FDT|APPEND)=' "$UENV" | sed -e 's/\(APPEND=root=[^ ]*\).*/\1 .../'
grep -E '^FDTFILE=' /etc/ophub-release
printf '\n'
printf 'DTB   : %s\n' "/boot/dtb/amlogic/$DTB"
inst_md5=$(md5sum "/boot/dtb/amlogic/$DTB" | cut -d' ' -f1)
printf 'md5   : %s\n' "$inst_md5"
printf 'expect: %s\n' "$DTB_MD5"
if [ "$inst_md5" != "$src_md5" ]; then
	warn "installed DTB does not match the source file, copy it again before rebooting."
fi
printf '\n'

if [ "$CHANGED" -eq 0 ]; then
	printf 'Nothing changed: everything was already installed.\n'
	exit 0
fi

if [ -t 0 ]; then
	printf 'Reboot now? [y/N] '
	answer=
	read -r answer || answer=
	case "$answer" in
		y|Y|yes|YES|Yes)
			printf 'Rebooting.\n'
			sync
			systemctl reboot
			;;
		*)
			printf 'Not rebooting. The new device tree and units take effect on the next boot.\n'
			;;
	esac
else
	printf 'Not running on a terminal, so not asking about a reboot.\n'
	printf 'Reboot when you are ready: the new device tree and units take effect then.\n'
fi
