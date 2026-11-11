# Arch Linux ARM on the ASUS Chromebook CM1406 

This boots Arch Linux ARM from a USB stick on the ASUS Chromebook CM1406 (board `google,tarkin`, MediaTek MT8189,
eMMC). ChromeOS stays on the internal storage and is never touched. Unplug the stick and the machine boots ChromeOS
like before.

There is no SSH and no second computer involved. The system draws a terminal on the built-in screen and you type on
the built-in keyboard.

How it works: the installer takes the kernel ChromeOS already runs on your machine (it contains the Tarkin device
tree), signs it again with the Developer Mode keys, and puts an Arch Linux ARM root filesystem next to it on the
stick. It is not mainline Linux. That kernel has no text console, so the system starts `cage` (a tiny Wayland
kiosk) with `foot` in it and draws straight on the display with software rendering. There is an optional desktop on
top of that.

## What works

Tested on a real CM1406:

- Booting from USB in Developer Mode
- The on-screen terminal and the built-in keyboard
- Wi-Fi (MT7925) and `pacman`

Written but not tested on the hardware yet: the desktop (`labwc`, `waybar`, `fuzzel`).

Not tested at all: audio, Bluetooth, suspend, touchpad and touchscreen, brightness keys. The GPU is not used (see
the GPU section).

Login is automatic as `alarm`, password `alarm` unless you set another one during the install. Suspend is off, the
machine reboots 10 seconds after a kernel panic, and the journal is kept on the stick.

## You need

- A CM1406 in ChromeOS Developer Mode (the "OS verification is OFF" screen at every boot)
- A USB stick of 8 GB or more, preferably USB 3.0. Everything on it will be erased.
- A WPA2 Wi-Fi network (a phone hotspot works). The Chromebook needs internet while you install, because the
  terminal and Wi-Fi packages are downloaded then.

## Two terminals

On recent ChromeOS, the terminal from `Ctrl+Alt+T` (crosh, then `shell`) cannot run `sudo`. The VT2 console can, but
it has no copy/paste and a QWERTY keyboard. So: use the browser terminal for downloads and unzipping, and VT2
(`Ctrl+Alt+Refresh`, login `chronos`, back with `Ctrl+Alt+Back`) for the few commands that need `sudo`. `/var/tmp`
is shared by both.

## Install

**1. Download** these with the ChromeOS browser into Downloads: this repository as a zip, and
<https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz> plus its `.md5` file next to it.

**2. Unpack** in the crosh tab (`Ctrl+Alt+T`, then `shell`):

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/<repository-zip-name>.zip
cp ~/MyFiles/Downloads/ArchLinuxARM-aarch64-latest.tar.gz* /var/tmp/
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5
ls /var/tmp
```

`md5sum` must say `OK`. Note the name of the unpacked folder.

**3. Preflight.** Plug in the stick, switch to VT2 and run:

```sh
cd /var/tmp/<unpacked-folder>
sudo bash scripts/preflight-tarkin.sh
```

The report goes to `/var/tmp/pf/report.txt`. You want `board: OK (google,tarkin)` and `repack: OK`. If any line says
`MISSING`, `ABSENT` or `FAILED`, stop and look at it. An `ABSENT` on an `mt7925` firmware line is harmless.

**4. Install**, still in VT2:

```sh
sudo bash install/go.sh
```

It finds the tarball and the stick, shows you the device and makes you type its name before erasing anything. It then
asks for a password for `alarm` (leave it empty to keep the default; if you set one, root login is locked). It
checks that the package mirror answers before it erases anything, and it reads the kernel back after writing it.
Wait for `[+] USB written` before you unplug.

Options go after `go.sh`, for example `sudo bash install/go.sh --keymap us`:

| Option | Meaning |
|---|---|
| `--keymap <layout>` | Keyboard layout of the terminal (`fr`, `us`, `de`, ...). Default `fr`. |
| `--wifi-ssid <name>` | Use this Wi-Fi instead of the one saved in ChromeOS (it asks for the passphrase). |
| `--alarm <file or https url>` | Rootfs tarball, with its `.md5` next to it. |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain (environment variable). |
| `ALLOW_NO_PKGS=1` | Skip the network check and the packages. The stick will have no terminal. |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check. Not recommended. |

**5. Boot.** Leave the stick in, power off, power on. At the "OS verification is OFF" screen press `Ctrl+U`, or
use the arrow keys and Enter on "Boot from external disk" if you get the newer menu. After a minute or two a terminal
replaces the logo. If you did not set Wi-Fi during the install, run `sudo tarkin-wifi "NetworkName"`.

## Desktop

Needs Wi-Fi. In the on-screen terminal:

```sh
bash ~/install-desktop.sh
sudo tarkin-session desktop
```

The script installs `labwc`, `waybar`, `fuzzel`, `mako`, `swaybg`, `foot`, Papirus icons, the Inter font,
`adw-gtk-theme` and `pcmanfm`, and writes a dark Windows-11-like setup into `~/.config` (taskbar centred at the
bottom, start menu on `fuzzel`). The screen restarts and shows the desktop, and keeps doing so at every boot.

Keys: `Super+d` start menu, `Super+Enter` terminal, `Super+e` files, `Super+q` close window.

To go back to the plain terminal: `sudo tarkin-session terminal`. If the desktop dies within 15 seconds of
starting, the screen falls back to the terminal on its own. `bash ~/install-desktop.sh --configs-only` only rewrites
the config files (the old ones are kept as `*.bak.*`). Rendering is in software, so don't expect it to be smooth.

## GPU (Mali-G57), experimental

This is what was done by hand on the owner's machine. It is not in the installer and not used by the desktop. Neither
`labwc` nor Firefox is accelerated.

| Item | Status |
|---|---|
| Kernel detects the Mali-G57 (KBase driver `r54p1-12eac0`, `/dev/mali0`, `/dev/dri/renderD128`) | Checked |
| `libmali.so.0.54.1` (same DDK) copied read-only from the ChromeOS root partition | Checked |
| `DT_RELR` metadata patched with LIEF so Arch's glibc loads it | Checked |
| EGL 1.5 and OpenGL ES 3.2 | Pass |
| Framebuffer clear and pixel read-back | Pass |
| DMA-BUF render, 10 frames, 0 bad | Pass |
| EGL shim, standalone | Pass |
| `labwc` / wlroots using it | Not tried |
| Firefox acceleration and video decoding | Not tried |

The ChromeOS partition is mounted with `mount -o ro,noload` and never written to. The Mali libraries live in
`~/gpu-test/mali/lib` and are only picked up through `LD_LIBRARY_PATH`; system Mesa, `libEGL` and `libGLESv2` are left
alone. Extra packages used: `libc++`, `libc++abi`, `gcc`, and `python-pip` with `lief` in a virtualenv. The probe
programs and the EGL shim come from zoan37's MT8189 project
(<https://github.com/zoan37/lenovo-slim3-chromebook-omarchy>, `bringup/`), which is built for Hyprland. Nobody has
shown that it works with `labwc`, so don't preload it into the desktop session. Firefox still reports
`WebRender (Software)` and `llvmpipe`.

Two things that came up on the way:

- If names don't resolve but `ping 1.1.1.1` works, `sudo resolvectl dns wlan0 1.1.1.1 8.8.8.8` fixes it until the next
  reboot.
- Bubblewrap (Thunar, Glycin) can fail with `Unexpected capabilities but not setuid` because the process carries
  `CAP_WAKE_ALARM`. Starting it as `setpriv --inh-caps=-wake_alarm --ambient-caps=-wake_alarm -- <command>` drops it.
  That is how Waybar was restarted.

## When it doesn't work

Boot ChromeOS (no stick, or `Ctrl+D`), plug the stick back in and run this in VT2:

```sh
sudo bash scripts/check-usb.sh
```

It checks the firmware flags, the partition table, the kernel signature and the stick's contents, and prints
`tarkin-boot.log` from the stick plus the crash log of the last failed boot.

| Problem | What to do |
|---|---|
| `sudo` fails in the `Ctrl+Alt+T` terminal | Normal. Use VT2. |
| Can't log in on VT2 | The user is `chronos`. |
| Wrong characters in VT2 | VT2 is QWERTY. |
| ChromeOS reboots by itself during `go.sh` | Fixed: the package step now runs in an isolated chroot (own mount/pid namespace, read-only `/proc/sys`), risky pacman hooks are masked, and the host's panic/vm settings are restored. The full log is in `/var/tmp/tarkin-install.log`; if it still happens, boot ChromeOS again and send that file plus `ls /sys/fs/pstore`. |
| `go.sh` finds no USB stick | Replug, wait 5 s, try another port (no hub) or another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 1) and put it in `/var/tmp`. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Try a phone hotspot. |
| Warning that packages could not be installed | Same cause. Fix the network and run the installer again, or there will be no terminal. |
| "No valid image detected" | The firmware rejected the stick. `check-usb.sh` tells you why: wrong partition type, priority 0, bad signature, or `dev_boot_usb` at 0. |
| It boots ChromeOS instead | You missed the menu, or `dev_boot_usb` is 0: `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`. |
| Freezes right after "jumping to kernel" | The kernel preamble flags were not 0. The installer and `set-cmdline.sh` use `--flags 0`, so run the installer again or `set-cmdline.sh --normal`. |
| Back to the "OS verification is OFF" screen | The kernel started and died. Boot ChromeOS and run `check-usb.sh`, it prints the crash log. |
| Black screen for 3 minutes | The terminal didn't start. Look at the `console journal`, `drm` and `input` sections of `tarkin-boot.log`. |
| Wrong characters in the terminal | Edit `/etc/tarkin/console.env` (`XKB_DEFAULT_LAYOUT=us`), then `sudo systemctl restart tarkin-console`. |
| Text too small or too big | Edit `/etc/xdg/foot/foot.ini` (`font=monospace:size=14`). |
| `pacman` can't download | Check the network first: `getent hosts mirror.archlinuxarm.org`, `ping 1.1.1.1`. |
| The desktop doesn't start | It falls back to the terminal. See `journalctl -u tarkin-console -b`, or run `sudo tarkin-session terminal`. |

### Debugging the kernel command line

`scripts/set-cmdline.sh` rewrites only the signed kernel on an installed stick, from VT2, and leaves the rootfs alone:

```sh
sudo bash scripts/set-cmdline.sh /dev/sda --probe
```

- `--probe` mounts the root and runs `/bin/false` as init, so the kernel panics on purpose and resets. The whole boot
  log is then in `/sys/fs/pstore/console-ramoops-0`.
- `--debug` uses `rootdelay=20 panic=5`: it panics instead of waiting forever if the root is missing.
- `--same` signs the stock kernel again with its own command line. You should get the stock dm-verity panic after
  about 4 seconds.
- `--normal` goes back to the default command line.

Only a warm reset keeps the pstore log. Holding Power or Refresh+Power wipes it, so after `--probe` or `--debug`
don't hold the power button.

To undo everything: remove the stick and boot ChromeOS (`Ctrl+D`). To put the firmware flags back:
`sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.

## What's in the repository

- `install/go.sh`: guided launcher for VT2, finds the tarball and the stick
- `install/install-usb.sh`: the installer (logs to `/var/tmp/tarkin-install.log`)
- `scripts/preflight-tarkin.sh`: read-only checks before installing
- `scripts/check-usb.sh`: diagnoses a stick and the last failed boot
- `scripts/set-cmdline.sh`: rewrites the kernel command line of an installed stick
- `scripts/install-desktop.sh`: the optional desktop (the installer copies it to `/home/alarm`)
- `scripts/identify-device.sh`: optional hardware report with HWID, serial and MAC removed
- `rootfs/`: files copied onto the stick (console service and launcher, `tarkin-wifi`, `tarkin-session`, seatd without
  VT, no suspend, panic reboot, boot report)
- `notes/tarkin-findings.md`: what has and hasn't been checked on the device

## Safety

- Use a spare stick. Never point the installer at `/dev/mmcblk0`; it refuses non-removable disks and the running disk.
- Nothing listens for SSH. The only way in is the keyboard, so set a password during the install.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification. Put the flags back when you stop using USB boot.
- Only do this on a machine you own or may modify. A school-managed Chromebook may forbid Developer Mode.
- Don't publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits

Based on zoan37's Omarchy / Arch Linux ARM Chromebook CM14 project, cut down to the Tarkin USB boot. The seatd
without VT idea comes from that project's work on another Skywalker variant. MIT license, see [`LICENSE`](LICENSE).
