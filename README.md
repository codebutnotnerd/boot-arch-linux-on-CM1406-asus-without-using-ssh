# Arch Linux ARM on the ASUS Chromebook CM1406 (Skywalker / Tarkin), no SSH

**Target:** ASUS Chromebook CM1406, board `google,tarkin` (Skywalker family), SoC MediaTek MT8189, eMMC storage.
**Method:** boot from a USB stick through ChromeOS Developer Mode.
**Internal storage:** never touched. ChromeOS stays installed; without the stick the machine boots ChromeOS.
**No SSH, no second device:** the system draws a terminal on the built-in screen and uses the built-in keyboard.

The installer takes the **stock ChromeOS kernel of your own machine** (it already contains the Tarkin device tree),
re-signs it with the developer keys and boots an Arch Linux ARM userland from the stick. This is **not mainline Linux**.
The stock kernel has no text console, so the system starts a small Wayland kiosk (`cage`) running a terminal (`foot`)
directly on the display controller with software rendering. An optional Windows 11 style desktop is available.

## Status

| Feature | Status |
|---|---|
| Boot from USB through Developer Mode | Verified on a CM1406 |
| On-screen terminal and built-in keyboard | Verified |
| Wi-Fi (MT7925) and `pacman` | Verified |
| Desktop (`labwc`, `waybar`, `fuzzel`) | Written, **not yet tested on hardware** |
| GPU acceleration (Mali-G57) | Experimental, not integrated (see below) |
| Audio, Bluetooth, suspend, touchpad and touchscreen in the terminal, brightness keys | Not tested |

## What you get

- A terminal on the built-in display, logged in automatically as `alarm` (`sudo` for administration)
- Keyboard layout chosen at install time (`fr` by default, `--keymap us` for QWERTY)
- Wi-Fi through `wpa_supplicant` and `systemd-networkd`; join a network with `sudo tarkin-wifi "NetworkName"`
- Packages with `sudo pacman -S ...` once Wi-Fi is up
- No suspend (lid and idle ignored), reboot 10 s after a kernel panic, persistent journal
- A diagnostics report at `/var/log/tarkin-boot.log` (90 s after boot, then every 10 minutes)
- `~/install-desktop.sh` and `tarkin-session` for the optional desktop

Default account: `alarm` / `alarm`, unless you set a password during the install.

## Requirements

- CM1406 in **ChromeOS Developer Mode** (`OS verification is OFF` screen at every boot).
- A USB stick of **8 GB or more**, USB 3.0 from a known brand. **Everything on it is erased.**
- A WPA2-PSK Wi-Fi network (a phone hotspot is fine). The Chromebook needs working internet **during the install**.

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
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5
ls /var/tmp
```

`md5sum` must print `...tar.gz: OK`. Note the name of the unpacked folder.

### 3. Preflight, in VT2

Plug the USB stick in, press `Ctrl+Alt+Refresh`, log in as `chronos`, then:

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
then asks for a password for `alarm` (empty keeps the default; if you set one, root login is locked). It checks the
package mirror **before** erasing anything, reads the kernel back after writing it, and prints `[+] USB written`.
Wait for that line and do not unplug the stick.

Options (after `go.sh`, e.g. `sudo bash install/go.sh --keymap us`):

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
2. At the `OS verification is OFF` screen, press `Ctrl+U`, or use the arrow keys and Enter on
   **Boot from external disk** in the new developer menu.
3. Wait 1-2 minutes. A terminal replaces the firmware logo. If you set no Wi-Fi at install:
   `sudo tarkin-wifi "NetworkName"`.

## Desktop (optional, Windows 11 style)

Needs working Wi-Fi. In the on-screen terminal:

```sh
bash ~/install-desktop.sh
sudo tarkin-session desktop
```

This installs `labwc` (windows), `waybar` (centred taskbar), `fuzzel` (start menu), `mako`, `swaybg`, `foot`,
Papirus icons, the Inter font, `adw-gtk-theme` and `pcmanfm`, and writes dark-theme configuration into `~/.config`.
The display restarts and shows the desktop, now and at every boot.

| Key | Action |
|---|---|
| `Super+d` | Start menu |
| `Super+Enter` | Terminal |
| `Super+e` | File manager |
| `Super+q` | Close window |

- Back to the plain terminal: `sudo tarkin-session terminal`.
- If the desktop exits within 15 seconds of starting, the display falls back to the terminal by itself.
- `bash ~/install-desktop.sh --configs-only` rewrites only the user configuration (old files are kept as `*.bak.*`).
- Rendering is in software: expect a light desktop, not a smooth one.

## GPU Mali-G57: experimental bring-up

Results reported from the owner's machine (Arch Linux ARM, kernel 6.6.147). They are **not** part of the installer
and **not** integrated into the desktop. Neither `labwc` nor Firefox is GPU accelerated.

| Item | Status |
|---|---|
| Mali-G57 detected by the kernel (KBase driver `r54p1-12eac0`, `/dev/mali0`, `/dev/dri/renderD128`) | Verified |
| `libmali.so.0.54.1` (same DDK) extracted read-only from the ChromeOS root partition | Verified |
| `DT_RELR` metadata fixed with LIEF so glibc on Arch loads it | Verified |
| EGL 1.5, OpenGL ES 3.2 | PASS |
| Framebuffer clear and pixel read-back | PASS |
| DMA-BUF render, 10 frames, 0 bad | PASS |
| EGL shim (device discovery), standalone | PASS |
| Integration with `labwc` / wlroots | Not tested |
| Firefox acceleration (WebRender) | Not tested |
| Firefox hardware video decoding | Not tested |

Notes:

- The ChromeOS partition is mounted read-only (`mount -o ro,noload`) and never written to.
- The libraries live in an isolated directory (`~/gpu-test/mali/lib`) and are used only through `LD_LIBRARY_PATH`.
  System Mesa, `libEGL` and `libGLESv2` are not replaced.
- Extra packages used: `libc++`, `libc++abi` (needed by libmali), `gcc` (test programs), `python-pip` and `lief` in a
  virtual environment.
- The probe programs and the EGL shim come from the MT8189 reference project by zoan37
  (<https://github.com/zoan37/lenovo-slim3-chromebook-omarchy>, `bringup/`), which targets Hyprland. It is not shown
  to work with `labwc`; do not preload it into the desktop session.
- Until the compositor integration is validated, Firefox still reports `WebRender (Software)` and `llvmpipe`.

Side notes from the same machine:

- DNS: if names do not resolve while pings to `1.1.1.1` work, `sudo resolvectl dns wlan0 1.1.1.1 8.8.8.8` is a
  temporary fix (it does not survive a reboot).
- Bubblewrap (Thunar, Glycin) can complain `Unexpected capabilities but not setuid`: the process carries
  `CAP_WAKE_ALARM`. Starting a program with `setpriv --inh-caps=-wake_alarm --ambient-caps=-wake_alarm -- <command>`
  drops it. Waybar was restarted this way.

## Troubleshooting

First, boot ChromeOS (no stick, or `Ctrl+D`), plug the stick in and run, in VT2:

```sh
sudo bash scripts/check-usb.sh
```

It checks the firmware flags, the partition table, the kernel signature and the stick contents, and prints the
stick's `tarkin-boot.log` and the crash log of the last failed boot.

| Symptom | Cause and fix |
|---|---|
| `sudo` fails in the `Ctrl+Alt+T` terminal | Expected. Run `sudo` commands in VT2 only. |
| Cannot log in on VT2 | The user is `chronos`. |
| VT2 types wrong characters | VT2 is QWERTY. |
| `go.sh`: no USB stick detected | Replug, wait 5 s, try another port (no hub) or another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 1) and put it in `/var/tmp`. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Use Wi-Fi or a phone hotspot. |
| Warning: packages could NOT be installed | Same cause. Fix the network and run the installer again, otherwise there is no terminal. |
| Firmware says "No valid image detected" | The firmware rejected the stick. `check-usb.sh` says whether partition 1 is not a kernel partition, has priority 0, fails to verify, or `dev_boot_usb` is 0. |
| Boots ChromeOS instead of the stick | The menu choice was missed, or `dev_boot_usb` is 0: `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`. |
| Freezes right after "jumping to kernel" | The kernel preamble flags were not 0. The installer and `set-cmdline.sh` use `--flags 0`; re-run the installer or `set-cmdline.sh --normal`. |
| Reboots to the `OS verification is OFF` screen | The kernel started and died. Boot ChromeOS and run `check-usb.sh`: it prints the previous boot's crash log (pstore). |
| Screen black for 3 minutes | The terminal did not start. Read `tarkin-boot.log` via `check-usb.sh`: `console journal`, `drm` and `input` sections. |
| Wrong characters in the terminal | Edit `/etc/tarkin/console.env` (e.g. `XKB_DEFAULT_LAYOUT=us`), then `sudo systemctl restart tarkin-console`. |
| Text too small or large | Edit `/etc/xdg/foot/foot.ini` (`font=monospace:size=14`). |
| `pacman` cannot retrieve packages | Check the network first: `getent hosts mirror.archlinuxarm.org`, `ping 1.1.1.1`. |
| Desktop does not start | It falls back to the terminal. Read `journalctl -u tarkin-console -b`, or run `sudo tarkin-session terminal`. |

### Debugging the boot with `set-cmdline.sh`

`scripts/set-cmdline.sh` rewrites only the signed kernel of an installed stick, in VT2, without touching the rootfs:

```sh
sudo bash scripts/set-cmdline.sh /dev/sda --probe
```

| Mode | Effect |
|---|---|
| `--probe` | Mounts the root, runs `/bin/false` as init: deliberate panic and warm reset. The whole boot log is then in `/sys/fs/pstore/console-ramoops-0`. |
| `--debug` | `rootdelay=20 panic=5`: panics instead of waiting forever if the root is missing. |
| `--same` | Re-signs the stock kernel with its original command line (expects the stock dm-verity panic after about 4 s). |
| `--normal` | Back to the default command line. |

Only a warm reset keeps the pstore log. Holding Power or Refresh+Power wipes it. Do not run `--probe` or `--debug`
and then hold Power.

To go back to normal: remove the stick and boot ChromeOS (`Ctrl+D`). To restore the firmware flags:
`sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.

## Repository layout

| Path | Purpose |
|---|---|
| `install/go.sh` | Guided launcher for VT2 (finds the tarball and the stick) |
| `install/install-usb.sh` | The installer |
| `scripts/preflight-tarkin.sh` | Read-only checks before installing |
| `scripts/check-usb.sh` | Diagnoses a stick and the last failed boot |
| `scripts/set-cmdline.sh` | Rewrites the kernel command line of an installed stick |
| `scripts/install-desktop.sh` | Optional desktop installer, copied to `/home/alarm` by the installer |
| `scripts/identify-device.sh` | Optional redacted hardware report (no HWID, serial or MAC) |
| `rootfs/` | Files copied onto the stick: console service and launcher, `tarkin-wifi`, `tarkin-session`, seatd no-VT setting, no-suspend, panic reboot, boot report |
| `notes/tarkin-findings.md` | What is verified on the device and what is not |

## Security

- Use a spare stick; never target `/dev/mmcblk0`. The installer refuses non-USB and non-removable disks and the running disk.
- There is no network login: nothing listens for SSH. Set a password at install.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification; restore the flags when you stop using USB boot.
- Use it only on a device you own or are allowed to modify (a school-managed Chromebook may forbid Developer Mode).
- Never publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits and license

Derived from the Omarchy/Arch Linux ARM Chromebook CM14 project by zoan37 and contributors, reduced to the Tarkin USB
boot path. The no-VT seatd approach follows that project's work on another Skywalker variant. MIT license, see
[`LICENSE`](LICENSE).
