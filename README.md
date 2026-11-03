# EnyBox EM95X (Amlogic S905X) device tree for Armbian

Device tree and userspace fixes that make an ophub Amlogic Armbian image work on the EnyBox EM95X (Amlogic S905X, `p212` reference board). They cover the RTL8723BS WiFi/Bluetooth combo chip, boot status and clock on VFD display via OpenVFD, and the systemd units that sequence those at boot.

The board runs the stock `meson-gxl-s905x-p212.dtb`; this repository ships a DTB derived from it that adds the EM95X-specific nodes, plus the driver and firmware handling needed by the RTL8723BS on this particular board.

## Tested baseline

|                  |                                                                              |
| ---------------- | ---------------------------------------------------------------------------- |
| image            | `Armbian_26.11.0_amlogic_s905x_trixie_6.18.56_server_2026.10.15.img` (ophub) |
| kernel           | `6.18.56-ophub` and `6.18.59-ophub`                                          |
| boot medium      | USB, ophub u-boot (`u-boot-p212.bin`)                                        |
| base device tree | `meson-gxl-s905x-p212.dtb`                                                   |

## Support status

| block                                                      | state     | notes                                                                                                |
| ---------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------- |
| Front 7-seg (FD628, 3-wire)                                | **works** | `stb` = GPIOAO_3, `clk` = GPIOAO_4, `dat` = GPIOAO_5; shows `BOOT` during boot, the clock afterwards |
| Power LED                                                  | **works** | blue from power-on, driven by the device tree (`default-state = "on"`)                               |
| Power button                                               | **works** | `gpio-keys-polled`, `KEY_POWER`                                                                      |
| Bluetooth (RTL8723BS, UART)                                | **works** | `hci0` up ~30 s after boot at 1 Mbaud, scans and pairs                                               |
| WiFi (RTL8723BS, SDIO)                                     | **works** | `wlan0` associates on the first attempt ~22 s after boot, 802.11n                                    |
| eMMC, HDMI, CPU frequency, thermal, CEC, RTC, watchdog, IR | **works** | stock p212 device tree                                                                               |
| i2c B / HYM8563                                            | disabled  | nothing ACKs on GPIODV_26/27, no RTC fitted on this board                                            |

## Installation

```sh
git clone https://github.com/FuLygon/armbian-em95x-dts.git
cd armbian-em95x-dts
chmod +x install.sh
# run with root privileges, required
sudo ./install.sh

# bluetooth only, optional:
sudo apt install bluez
```

## Design notes

### Device tree

`dts/meson-gxl-s905x-em95x.dts` is `meson-gxl-s905x-p212.dts` with the p212 `compatible` list kept and only `model = "EnyBox EM95X (Amlogic S905X)"` changed, plus the board-specific nodes described below. It is a flat, decompiled-style source: no `#include`, no phandle labels, all values numeric, byte arrays as `/bits/ 8`.

Edit and rebuild it on the box with the image's own `dtc`:

```sh
sudo dtc -I dts -O dtb -o /boot/dtb/amlogic/meson-gxl-s905x-em95x.dtb /root/em95x/dts/meson-gxl-s905x-em95x.dts
```

The shipped source compiles to a byte-identical 42387-byte DTB (md5 `a10d1fc4d9f141ab2f4bedea2bc54d94`); the installer warns if the local DTB does not match, which usually means the copy is corrupt.

### 7-segment display

The upstream `em95-vfd.conf` (GPIODV_21/22/23) does not match this board. The vendor driver drives raw GPIO 148/149/150, which in the vendor's top-down gpiolib numbering (periphs 156, aobus 145) are AO_3/AO_4/AO_5. The `vfd_pins` pinctrl group therefore has to live in the **aobus** pinctrl node (`pinctrl@14`, function `gpio_aobus`, `bias-pull-up`). `diy.conf` and the unit's `modprobe` arguments agree on `clk=1,4,0 dat=1,5,0 stb=1,3,0`.

**GPIODV_25 is a power/kill line.** Driving it low hangs the board. It is left as an input with an internal pull-up and must not be touched.

### `BOOT` text and the handover to the clock

The OpenVFD driver is a module. `em95x-vfd-boot.service` loads it as soon as the pinctrl gpiochip exists and paints `BOOT`; without it the display stays dark until `start_service.sh` starts the clock service:

- `DefaultDependencies=no`, `WantedBy=sysinit.target`, `Before=sysinit.target shutdown.target` — default dependencies would schedule it, after `basic.target` has waited for the BOOT partition (`boot.mount` and fsck), which is irrelevant here.
- It runs `modprobe openvfd …` with the same parameters as `diy.conf`, then `em95x-vfd-boot BOOT --hold`.
- `start_service.sh` stops the unit _before_ `armbian-openvfd 99` starts `vfdservice` and sets `openvfd_restart="no"`; the upstream `rmmod -f` restart cycle would blank the display for a bit.

Driver behaviour that shapes the helper (OpenVFD V1.4.4, `drivers/auxdisplay/openvfd`):

- `write()` to `/dev/openvfd` accepts **exactly one `struct vfd_display_data` (660 bytes)**. Any other length is treated as raw LED codes and fails with `EIO`. `mode = 4` (`DISPLAY_MODE_TITLE`) with `string_main = "BOOT"` is what the driver's own `display_text()` uses; `string_main[0..3]` map to digits 1–4, and the glyph table includes A–Z.
- On success `write()` returns **0**, not the byte count. Never retry on a short write: a shell `printf > /dev/openvfd` loop spins forever and toggles the display power.
- `open()` powers the display on and the **last `close()` powers it off**; segment writes do not re-enable it. Hence `--hold`: the helper keeps the descriptor open for the whole boot. The order of the handover matters — the helper has to close before `vfdservice` opens the device, which is why `start_service.sh` stops the unit first. Reversing that leaves the display dark until the next reboot.

The shipped helper is a static aarch64 binary. Rebuild it only if the text changes:

```sh
gcc -O2 -static -o files/usr/local/bin/em95x-vfd-boot src/em95x-vfd-boot.c
```

### Bluetooth (RTL8723BS)

Two independent problems are solved in the device tree and one firmware blob.

**1. Wrong chip description.** The chip is a Realtek **RTL8723BS**, not a Broadcom part, so its node is `realtek,rtl8723bs-bt` (H5 3-wire protocol, `hci_uart_h5`) rather than `brcm,bcm43438-bt` (H4). The reset line GPIOX_17 must be listed as `enable-gpios`: H5 honours `enable-gpios` only, and `shutdown-gpios` leaves the chip unpowered.

**2. Firmware download fails with `-110`.** `uart_A` takes its clock from the 24 MHz crystal and `meson_uart.c` hard-wires a `/3` divisor, giving an 8 MHz base clock. The resulting baud rate is `8 MHz / (div + 1)`:

| requested | div + 1 | actual  | error  |
| --------- | ------- | ------- | ------ |
| 115200    | 69      | 115942  | +0.6 % |
| 230400    | 35      | 228571  | −0.8 % |
| 921600    | 9       | 888889  | −3.5 % |
| 1000000   | 8       | 1000000 | 0 %    |
| 1500000   | 5       | 1600000 | +6.7 % |
| 2000000   | 4       | 2000000 | 0 %    |

The stock `rtl8723b_config.bin` requests 1.5 Mbit (`0x04928002`), which this UART cannot generate, so the download times out:

```
command 0xfc20 tx timeout
RTL: download fw command failed (-110)
```

The baud rate comes from the firmware configuration blob, **not** from the device tree (`max-speed` is ignored by H5). The fix is a dedicated `/lib/firmware/rtl_bt/rtl8723bs_config.bin` (a plain 68-byte file, replacing the package symlink) with the baud field set to 1 Mbaud and flow control disabled:

```
offset 20..23 : 04 50 00 00   (= 0x00005004; stock is 02 80 92 04 = 1.5 Mbaud)
offset 32     : 5b            (flow control off; stock is 5f)
```

`rtl8723b_config.bin` itself stays stock. 1 Mbaud is 8.7× the 115200 fallback and enough for A2DP; 2 Mbaud (`0x00005002`) is the alternative. The blob has the magic `55 ab 23 87`; the baud `u32` sits after the `00 0c 00 10` marker and the flow-control flag 12 bytes after it. To patch an existing file instead:

```sh
F=/lib/firmware/rtl_bt/rtl8723bs_config.bin
printf '\004\120\000\000' | dd of="$F" bs=1 seek=20 conv=notrunc   # 04 50 00 00
printf '\133'             | dd of="$F" bs=1 seek=32 conv=notrunc   # 5b
od -A d -t x1 "$F"
```

Without this fix the chip still probes and `hci0` appears, then dies at `download fw command failed (-110)` — easy to mistake for a device tree problem.

### Why Bluetooth firmware must not load during WiFi startup

The RTL8723BS is a single die with one antenna and one radio shared by the WiFi and Bluetooth cores. Downloading the BT firmware while the WiFi side initialises leaves the WiFi side unable to get an association response for a few minutes: every attempt times out after (`ASSOC-REJECT status_code=1`), multiples times in a row. It looks like AP-side client steering, but it is not.

Measured boot-to-boot (connect = `Activation: (wifi) Stage 2 of 5 (Device Configure) successful`):

| BT core state during WiFi init          | `wlan0` connect        | `ASSOC-REJECT` |
| --------------------------------------- | ---------------------- | -------------- |
| powered, ROM code only, no firmware     | 22.4 s / 23.1 s        | 0 / 0          |
| BT driver not loaded, enable line idle  | 39 / 73 / 174 s        | 4 / 9 / 22     |
| powered, BT firmware downloaded at boot | 98 / 148 / 217 / 235 s | 15–26          |

The core has to be **out of reset** while the WiFi side calibrates, but must **not** be running firmware yet. Loading the same firmware later, with `wlan0` already associated, is harmless (0 packet loss over 160 s of pings across a forced serdev unbind/bind). A warm `rmmod`/`modprobe` test cannot reproduce the bug, because the AP keeps the client's session for such a short drop — only reboots do.

The fix has two halves:

- `em95x-bt-power.service` (`WantedBy=multi-user.target`, `DefaultDependencies=no`, `Before=NetworkManager.service`) runs `em95x-bt-power.sh`. The script drives GPIOX_17 (periphs-banks line 96, `GPIOX_17`) low for 200 ms and then high via `/sys/class/gpio`, so the BT core always restarts from ROM code, even after a warm reboot that left a firmware running. This is as early as it can be done without kernel changes: the pinctrl gpiochip appears and `r8723bs` probes. The script waits up to 20 s for the gpiochip.
- `/etc/modprobe.d/em95x-bt-delay.conf` blacklists `hci_uart`, which blocks only the udev/alias auto-load (an explicit `modprobe hci_uart` still works). `em95x-bt-load.service` then runs `em95x-bt-load.sh`, which waits for `wlan0` to become `connected`, sleeps 5 s, **unexports the GPIO** (`hci_uart` requests the same line through `enable-gpios` and would fail with `-EBUSY`), and loads the module. If WiFi never comes up, it loads BT after 120 s anyway, so a box with a dead AP still has Bluetooth.

Result: `wlan0` connects at 22.2–23.6 s with 0 `ASSOC-REJECT`, BT core powered at ~10.5 s, `hci0` up at ~30 s (`hci_uart loaded after 8s (wlan0=connected)` in `journalctl -t em95x-bt`). The cost is ~15 s of Bluetooth availability at boot.

### WiFi settings

The image already ships `/etc/modprobe.d/r8723bs.conf` with `options r8723bs rtw_power_mgnt=0 rtw_enusbss=0`, which disables the driver's power management. The board is mains-powered, so power save on this SDIO part would only add latency and occasional dropouts. The installer leaves that file alone.

NetworkManager and netplan are left at their defaults: the WiFi profile comes from Armbian's first-login netplan file, and the installer neither edits nor duplicates it.

### Deviations from stock

Two stock Armbian units are changed outside the EM95X-specific files:

- `armbian-led-state.service` is **masked**. It is unnecessary (the device tree turns the LED on) and broken on this board: `/etc/armbian-leds.conf` contains the `openvfd` LED class, and the restore script aborts on its empty `led_cmd=` line (`Invalid state file, syntax error`) _after_ writing `trigger=none` to `openvfd`, which blanks the 7-segment display at `basic.target`. Masking also survives package upgrades.
- `NetworkManager-wait-online.service` is **disabled**. It only serves `rpc-statd-notify` (NFS) here and does not bring anything up; it blocks `network-online.target` until `nm-online` sees a configured connection (30 s default, the unit sets no `TimeoutStartSec`). With a slow or absent AP that produces a failed unit and delays `rc-local`, which is what hands the display from `BOOT` to the clock. Disabled, `rc-local` runs at ~15 s regardless of the network. Re-enable it if NFS or another boot-time network consumer is added.

## Troubleshooting

### WiFi never associates after a reboot

Check in this order:

```sh
dmesg | grep rtl8723bs          # did the WiFi driver probe? -110 here is an SDIO problem
iw dev wlan0 link               # associated?
journalctl -b | grep -e ASSOC-REJECT -e 'association took too long'
```

`status_code=1` together with `CONN_FAILED` is the Bluetooth/WiFi race described above — confirm that `em95x-bt-power` and `em95x-bt-load` are enabled and that `hci_uart` is blacklisted. `status_code=17` or `15` means a wrong key or the AP refusing the client (client steering, 802.11k/v, band steering, WPA2/WPA3 mixed mode); fix that on the AP.

### Diagnostic reference: `no-secrets` failure

Before the Bluetooth fix, a reboot could leave the box offline until NetworkManager was restarted by hand. Association itself was fine, but the first attempts after boot were rejected (this is the `status_code=1` signature above). NetworkManager turned that into a permanent failure: an association taking longer than 25 s makes it log `association took too long` and ask for the key again, and on the **4th** round it concludes the key is wrong:

```
[47.002] Activation: (wifi) association took too long
[72.004] Activation: (wifi) association took too long
[97.002] Activation: (wifi) association took too long
[97.002] device (wlan0): state change: config -> failed (reason 'no-secrets')
[97.012] Activation: failed for connection 'netplan-wlan0-...'
```

The counter is `connection.auth-retries`, not `autoconnect-retries`: on a supplicant timeout, `nm-device-wifi.c` calls `handle_auth_or_fail()`, ending in `nm_device_auth_retries_try_next()` (`nm-device.c`):

```c
#define NM_DEVICE_AUTH_RETRIES_DEFAULT  3
auth_retries = nm_setting_connection_get_auth_retries (s_con);   /* -1 unless set */
if (auth_retries == 0) auth_retries = NM_DEVICE_AUTH_RETRIES_INFINITY;
else if (auth_retries == -1) auth_retries = NM_DEVICE_AUTH_RETRIES_DEFAULT;   /* 3 */
```

Three rounds, then `NO_SECRETS`; nothing re-arms the activation afterwards. An earlier revision of this repository worked around that with `auth-retries=0` and a watchdog timer, which kept the box reachable by retrying forever instead of fixing the cause. Both are gone; the cause is the Bluetooth firmware race, and with that fixed the stock retry policy never reaches the limit.

Note that a `nmcli con modify` on the netplan-generated profile does not stick: Armbian's first-login writes `/etc/netplan/30-wifis-dhcp.yaml`, netplan's systemd generator regenerates `/run/NetworkManager/system-connections/netplan-wlan0-….nmconnection` at every boot, and that generated copy is what NM loads. Persistent WiFi changes belong in the netplan file (or in a profile that netplan does not manage).

### `hci0` appears but the firmware download fails

`RTL: download fw command failed (-110)` means the baud rate in `/lib/firmware/rtl_bt/rtl8723bs_config.bin` cannot be generated by `uart_A`. Verify the blob is the patched 68-byte file and not the package symlink:

```sh
ls -l /lib/firmware/rtl_bt/rtl8723bs_config.bin   # plain file, 68 bytes
od -A d -t x1 /lib/firmware/rtl_bt/rtl8723bs_config.bin | sed -n '2,3p'
```

### The display stays dark

`em95x-vfd-boot` must close `/dev/openvfd` before `vfdservice` opens it; closing powers the display off and the next open powers it back on. If `start_service.sh` no longer stops the unit first (for example after a package replaced the file), the display stays dark until reboot. Check `systemctl status em95x-vfd-boot` (it should be `inactive` after boot) and the order inside `start_service.sh`.

## Uninstalling

The installer keeps timestamped backups of the two boot configuration files and does not touch anything else outside its own files:

```sh
sudo cp -a /boot/uEnv.txt.bak.<stamp>      /boot/uEnv.txt
sudo cp -a /etc/ophub-release.bak.<stamp>  /etc/ophub-release
sudo systemctl disable em95x-vfd-boot.service em95x-bt-load.service em95x-bt-power.service
sudo rm -f /etc/modprobe.d/em95x-bt-delay.conf \
	/usr/local/bin/em95x-bt-load.sh /usr/local/bin/em95x-bt-power.sh \
	/usr/local/bin/em95x-vfd-boot \
	/etc/systemd/system/em95x-vfd-boot.service \
	/etc/systemd/system/em95x-bt-load.service \
	/etc/systemd/system/em95x-bt-power.service \
	/boot/dtb/amlogic/meson-gxl-s905x-em95x.dtb
sudo systemctl unmask armbian-led-state.service
sudo systemctl enable armbian-led-state.service NetworkManager-wait-online.service
sudo systemctl daemon-reload
sudo reboot
```

`/etc/custom_service/start_service.sh` and `/usr/share/openvfd/conf/diy.conf` are overwritten by the installer; restore them from the image or the package if needed. The stock firmware configuration is a symlink, so the patched blob is reverted with:

```sh
sudo rm -f /lib/firmware/rtl_bt/rtl8723bs_config.bin
sudo ln -s rtl8723b_config.bin /lib/firmware/rtl_bt/rtl8723bs_config.bin
```

## References

- `reference/meson-gxl-s905x-p212.dts` — upstream base, from the image's own DTB sources.
- `reference/vendor-android.dts` — decompiled Android device tree of this box; the authority on GPIO numbers, the VFD wiring and the Bluetooth setup.
- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) — image and kernel with the `openvfd` driver.
