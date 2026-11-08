# Arch Linux ARM on the ASUS Chromebook CM1406 (Skywalker / Tarkin), local console, no SSH

**Target:** ASUS Chromebook CM1406, board `google,tarkin` (Skywalker family), SoC MediaTek MT8189, eMMC storage.
**Method:** boot from a USB stick through ChromeOS Developer Mode (`Ctrl+U`).
**Internal storage:** never touched. ChromeOS stays installed; without the stick the machine boots ChromeOS.
**No SSH, no second device:** the system draws a terminal on the built-in screen and uses the built-in keyboard.

The installer takes the **stock ChromeOS kernel of your own machine** (it already contains the Tarkin device tree),
re-signs it with the developer keys and boots an Arch Linux ARM userland from the stick. This is **not mainline Linux**.
The stock kernel has no text console, so the system starts a small Wayland kiosk (`cage`) running a terminal
(`foot`) directly on the display controller with software rendering.

> **Experimental, untested on a Tarkin.** Neither the boot nor the on-screen terminal has been confirmed on a
> physical CM1406. The boot method worked on another Skywalker variant (Obiwan); the on-screen terminal is new and
> may not light up the Tarkin panel. Only identification and the kernel repack were verified on a real Tarkin
> (see [`notes/tarkin-findings.md`](notes/tarkin-findings.md)). If the screen stays black, there is no remote
> fallback: use `scripts/check-usb.sh` from ChromeOS to read the boot report (below).

## What you get

- A terminal on the built-in display, logged in as `alarm` automatically (sudo for administration)
- Keyboard layout chosen at install time (`fr` by default, `--keymap us` for QWERTY)
- Wi-Fi (MT7925, WPA2-PSK) through `wpa_supplicant` + `systemd-networkd`; join a network from the terminal with
  `sudo tarkin-wifi "NetworkName"`
- Packages installable with `sudo pacman -S ...` once Wi-Fi is up
- No suspend (lid and idle ignored), reboot 10 s after a kernel panic, persistent journal
- A diagnostics report at `/var/log/tarkin-boot.log` (90 s after boot, then every 10 min)

Not included or untested: GPU acceleration, audio, Bluetooth, suspend, touchpad and touchscreen use in the terminal,
brightness keys, WPA3-only / enterprise / hidden Wi-Fi.

## Requirements

- CM1406 in **ChromeOS Developer Mode** (`OS verification is OFF` screen at every boot).
- A USB stick of **8 GB or more**, USB 3.0 from a known brand. **Everything on it is erased.**
- A WPA2-PSK Wi-Fi network (a phone hotspot is fine). The Chromebook needs working internet **during the install**
  (the terminal and Wi-Fi packages are downloaded then).

## Why two terminals

On recent ChromeOS the terminal opened with `Ctrl+Alt+T` (crosh, then `shell`) **cannot use `sudo`**. The VT2
console can, but it has no copy/paste and a QWERTY keyboard.

| Where | Used for |
|---|---|
| **Browser + crosh tab** (`Ctrl+Alt+T`, then `shell`) | Downloads and unpacking. Never needs root. |
| **VT2** (`Ctrl+Alt+Refresh`, login `chronos`) | The few short commands that need `sudo`. Back to the desktop: `Ctrl+Alt+Back`. |

`/var/tmp` is shared by both.

## Installation

### 1. Download with the ChromeOS browser

Save these into *Downloads*:

- this repository as a zip (GitHub, **Code, Download ZIP**)
- <https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz> (about 0.5-1 GB)
- <https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5>

### 2. Prepare in the crosh tab (`Ctrl+Alt+T`, then `shell`)

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/<name-of-the-repository-zip>.zip
cp ~/MyFiles/Downloads/ArchLinuxARM-aarch64-latest.tar.gz* /var/tmp/
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5        # must print: ...tar.gz: OK
ls /var/tmp                                              # note the name of the unpacked folder
```

### 3. Preflight, in VT2

Plug the USB stick in, press `Ctrl+Alt+Refresh`, log in as `chronos`, then (VT2 is QWERTY):

```sh
cd /var/tmp/<unpacked-folder>
sudo bash scripts/preflight-tarkin.sh
```

The report is `/var/tmp/pf/report.txt`. It must say `board: OK (google,tarkin)` and `repack: OK`. Stop if a line
contains `MISSING`, `ABSENT` or `FAILED` (an `ABSENT` on an `mt7925` firmware line is fine).

### 4. Install, in VT2

```sh
sudo bash install/go.sh
```

`go.sh` finds the tarball, detects the USB stick, shows it and asks you to type its name to confirm. The installer
then asks for a password for the `alarm` user (empty keeps the default `alarm`; if you set one, root login is
locked). It checks the package mirror **before** erasing anything, verifies the kernel it wrote by reading it back,
and prints `[+] USB written` at the end. Wait for it and do not unplug the stick.

Options (add them after `go.sh`, e.g. `sudo bash install/go.sh --keymap us`):

| Option / variable | Purpose |
|---|---|
| `--keymap <layout>` | Keyboard layout of the terminal (xkb name: `fr`, `us`, `de`, ...). Default `fr` |
| `--wifi-ssid <name>` | Wi-Fi network instead of the ChromeOS-saved one (passphrase prompted) |
| `--alarm <file\|https-url>` | Rootfs tarball (its `.md5` beside it) |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain |
| `ALLOW_NO_PKGS=1` | Skip the network check and the packages (the stick then has no terminal) |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check (not recommended) |

### 5. Boot

1. Leave the stick plugged in, power the Chromebook off, then on.
2. The `OS verification is OFF` screen may be very short: **tap `Ctrl+U` about once per second from power-on**.
3. Wait 1-2 minutes. A terminal should replace the firmware logo. If you set no Wi-Fi at install:
   `sudo tarkin-wifi "NetworkName"`.

## Troubleshooting

First, always: boot ChromeOS (no stick, or `Ctrl+D`), plug the stick in and run, in VT2:

```sh
sudo bash scripts/check-usb.sh
```

It checks the firmware flags, the partition table, the kernel signature and the stick's contents, and prints the
stick's `tarkin-boot.log` (which includes the terminal's journal and the display and input devices the kernel saw)
and the crash log of the last failed boot. Keep its output for a bug report.

| Symptom | Cause and fix |
|---|---|
| `sudo` fails in the `Ctrl+Alt+T` terminal | Expected. Run `sudo` commands in VT2 only. |
| Cannot log in on VT2 | User is `chronos`. If it asks for a password you never set, note the exact message. |
| VT2 types wrong characters | VT2 is QWERTY. |
| `go.sh`: no USB stick detected | Replug, wait 5 s, try another port (no hub, no adapter) or another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 1) and put it in `/var/tmp`. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Connect to Wi-Fi in ChromeOS or use a phone hotspot. |
| Warning: packages could NOT be installed | Same cause. Fix the network and run the installer again, otherwise there is no terminal. |
| Firmware says "No valid image detected" | The firmware rejected the stick. `check-usb.sh` says whether partition 1 is not a kernel partition, has priority 0, fails to verify, or `dev_boot_usb` is 0. If the installer stopped before `[+] USB written`, run it again. |
| Reboots straight back to the `OS verification is OFF` screen | The kernel started and died, or was rejected. Boot ChromeOS and run `check-usb.sh`: its last section prints the previous boot's crash log (pstore). |
| Boots ChromeOS instead of the stick | `Ctrl+U` was not caught (tap it repeatedly), or `dev_boot_usb` is 0: `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`. |
| Screen stays black or on the logo for 3 minutes | The terminal did not start (panel not driven, or a missing package). Read `tarkin-boot.log` via `check-usb.sh`: the sections `console journal`, `drm` and `input` show why. |
| Terminal appears but the keyboard types wrong characters | Wrong layout: edit `/etc/tarkin/console.env` (e.g. `XKB_DEFAULT_LAYOUT=us`) and `sudo systemctl restart tarkin-console`, or re-run the installer with `--keymap`. |
| Terminal text too small or large | Edit `/etc/xdg/foot/foot.ini` (`font=monospace:size=14`). |

To go back to normal: remove the stick and boot (`Ctrl+D`). To restore the firmware flags:
`sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.

## Repository layout

| Path | Purpose |
|---|---|
| `install/go.sh` | Guided launcher for VT2 (finds the tarball and the stick) |
| `install/install-usb.sh` | The installer |
| `scripts/preflight-tarkin.sh` | Read-only checks before installing |
| `scripts/check-usb.sh` | Diagnoses a stick and the last failed boot |
| `scripts/identify-device.sh` | Optional redacted hardware report (no HWID, serial or MAC) |
| `rootfs/` | Files copied onto the stick: console service and launcher, `tarkin-wifi`, seatd no-VT setting, no-suspend, panic reboot, boot report |
| `notes/tarkin-findings.md` | What is verified on the device and what is not |

## Security

- Use a spare stick; never target `/dev/mmcblk0`. The installer refuses non-USB, non-removable and the running disk.
- There is no network login: nothing listens for SSH. The only way in is the keyboard. Set a password at install.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification; restore the flags when you stop using USB boot.
- Use it only on a device you own or are allowed to modify (a school-managed Chromebook may forbid Developer Mode).
- Never publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits and license

Derived from the Omarchy/Arch Linux ARM Chromebook CM14 project by zoan37 and contributors, reduced to the Tarkin
USB boot path. The no-VT seatd approach follows that project's work on another Skywalker variant. MIT license, see
[`LICENSE`](LICENSE).
