# Arch Linux ARM on the ASUS Chromebook CM1406 (no SSH)

This boots Arch Linux ARM from a USB stick on the ASUS Chromebook CM1406 (board `google,tarkin`, MediaTek MT8189,
eMMC). ChromeOS stays on the internal storage and is never touched. Unplug the stick and the machine boots ChromeOS
like before.

Cut down from [zoan37's Omarchy / Arch Linux ARM Chromebook CM14 project](https://github.com/zoan37/lenovo-slim3-chromebook-omarchy),
which boots a full Omarchy desktop on this same generation of MediaTek Chromebooks.

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

Written but not tested on the hardware as a whole: the `labwc` desktop (`waybar`, `fuzzel`) and the XFCE/i3 sessions behind
SDDM. The **X11 SDDM greeter itself has been seen working** on this machine (in a build where `tarkin-console` was not
running), so the greeter can draw on this panel; `--console dm` just makes that state deliberate.

Not tested at all: audio, Bluetooth, suspend, touchscreen and brightness keys. The GPU is not used (see
the GPU section).

The touchpad (Elan I2C-HID `04F3:31C6`) is detected and usable, but it is not tuned: it runs on stock `libinput`, not
ChromeOS's gesture library, so taps, scroll speed and palm rejection feel different. See [Touchpad](#touchpad).

Login is automatic as `alarm`, password `alarm` unless you set another one during the install. Change that password
at the first boot with `passwd`: the installer removes the `sshd.service` that the Arch Linux ARM image enables by
default (`alarm`/`alarm` on an open port would otherwise be reachable over Wi-Fi), but anyone holding the machine can
log in until you change it. Check with `systemctl is-enabled sshd`.
Suspend is off, the machine reboots 10 seconds after a kernel panic, and the journal is kept on the stick. A *hung
task* no longer panics: a slow USB flush must not reboot the machine in the middle of a package transaction.

## You need

- A CM1406 in ChromeOS Developer Mode (the "OS verification is OFF" screen at every boot)
- A USB stick or external USB SSD of 8 GB or more, preferably USB 3.0. Everything on it will be erased.
- A WPA2 Wi-Fi network (a phone hotspot works). The Chromebook needs internet while you install, because the
  terminal and Wi-Fi packages are downloaded then.

## Two terminals

On recent ChromeOS, the terminal from `Ctrl+Alt+T` (crosh, then `shell`) cannot run `sudo`. The VT2 console can, but
it has no copy/paste and a QWERTY keyboard. So: use the browser terminal for downloads and unzipping, and VT2
(`Ctrl+Alt+Refresh`, login `chronos`, back with `Ctrl+Alt+Back`) for the few commands that need `sudo`. `/var/tmp`
is shared by both.

## Install

**1. Download** these with the ChromeOS browser into Downloads: this repository as a zip, and
<https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz> plus its `.md5` file next to it. Prefer the
browser and https: a `.md5` fetched over plain http from the same server does not prove the file is genuine.

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
asks for a password for `alarm` (leave it empty to keep the default `alarm` / `alarm`; if you set one, root login is
locked — and change the default with `passwd` right after the first boot). It checks that the package mirror answers
before it erases anything, and it reads the kernel back after writing it. Wait for `[+] USB written` before you
unplug.

Options go after `go.sh`, for example `sudo bash install/go.sh --keymap us`:

| Option | Meaning |
|---|---|
| `--keymap <layout>` | Keyboard layout of the terminal (`fr`, `us`, `de`, ...). Default `fr`. |
| `--console dm` | One-shot SDDM + XFCE + i3: the installer adds the whole graphical stack, the greeter owns the console, and `tarkin-dm-fallback` returns to a terminal if it fails. See [XFCE + i3 + SDDM](#xfce--i3--sddm---console-dm). |
| `--wifi-ssid <name>` | Use this Wi-Fi instead of the one saved in ChromeOS (it asks for the passphrase). |
| `--alarm <file or url>` | Rootfs tarball, with its `.md5` next to it (a `.sig` beside it is verified against the Arch Linux ARM key). |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain (environment variable). |
| `ALLOW_NO_WIFI=1` | Ignore the Wi-Fi network saved in ChromeOS (configure it later with `sudo tarkin-wifi "Name"`). |
| `ALLOW_INSECURE_HTTP=1` | Accept a rootfs that came over plain http without a verifiable GPG signature. Refused by default. |
| `ALLOW_NO_PKGS=1` | Skip the network check and the packages. The stick will have no terminal. |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check. Not recommended. |

**5. Boot.** Leave the stick in, power off, power on. At the "OS verification is OFF" screen press `Ctrl+U`, or
use the arrow keys and Enter on "Boot from external disk" if you get the newer menu. After a minute or two a terminal
replaces the logo. If you did not set Wi-Fi during the install, run `sudo tarkin-wifi "NetworkName"`.

## Console modes

What draws on the panel at boot is decided at install time (`--console`), and can be changed later.

| Mode | Boots to | VT needed | Notes |
|---|---|---|---|
| `graphical` (default) | `tarkin-console`: `cage` + `foot` on the DRM node | no | a display manager cannot share the DRM node: its failure is a black screen |
| `dm` | the SDDM greeter, with **XFCE** (default) and **i3** sessions | yes | **yes**, and the installer installs all of it |

The mode is stored in `/etc/tarkin/console-mode`.

**There is no `tty` mode.** This kernel cannot show a text console: `fbcon` is not registered and there is no
`/dev/fb0`, so `getty` on `tty1` would run and draw nothing. That was confirmed on the device — the old `tty` guard
refused the install. A VT *does* exist (`VT_OPENQRY` succeeds, ChromeOS itself uses VT2), but only a program that
does its own modesetting can put pixels on this panel: `cage`, Xorg, SDDM. Nothing that relies on the kernel's text
console can.

**Verify the VT layer** (this is what actually decides whether a display manager works):

```sh
sudo tarkin-vtcheck
```

It checks that the VT driver exists (`/sys/class/tty/tty0`), whether this shell can see `/dev/tty0`, how many VTs there
are, which one is active, and — the important one — calls `VT_OPENQRY`, the exact ioctl SDDM uses.

Run it from **VT2** (`Ctrl+Alt+Refresh`). ChromeOS's crosh `shell` and its Linux container do not expose `/dev/tty0`
even though the kernel has VTs (your own VT2 proves it). The installer uses the same rule now: it only refuses
`--console dm` when **both** `/dev/tty0` and `/sys/class/tty/tty0` are missing, and prints a note when it is merely the
shell that cannot see the device. It never refuses `--console dm` for this: the failure is safe (the fallback returns to
`tarkin-console`), so a wrong guess about the shell cannot block the install.

`[ok] VT_OPENQRY says VT2 is free` means SDDM has somewhere to go; `FAIL` means it will say `vt -1` no matter what you
install. On the stick the binary is `tarkin-vtcheck`; from the repository (or from ChromeOS, which runs the same signed
kernel) it is `sudo bash scripts/verify-vt.sh`.

**A VT can exist and still be invisible.** A display manager gets a VT number from the kernel, but nothing on that VT
is readable unless `fbcon` and a framebuffer are there. They are not on this kernel, and that is the one real risk of
`dm` mode: if the greeter starts and cannot draw, the panel is black and there is no on-screen error to read. Check it
yourself:

```sh
grep -il 'frame buffer' /sys/class/vtconsole/vtcon*/name; ls -l /sys/class/graphics/fb0
sudo tarkin-vtcheck      # "VT text console (fbcon)" section and a verdict
```

`sudo tarkin-vtcheck --activate tty2` is the only test that proves a VT reaches the panel: it switches the screen to
`tty2` for 3 seconds and back. It is opt-in because on this kernel the screen can stay black and you would have to
power-cycle.

### XFCE + i3 + SDDM (`--console dm`)

One command, one pass — the graphical stack is installed by the same installer:

```sh
sudo bash install/go.sh --console dm
```

It adds Xorg, SDDM, the `xfce4` and `xfce4-goodies` groups and `i3` (plus `dmenu`, `i3status`, `i3lock`, `xterm`) to the
rootfs in the same chroot transaction as the terminal packages, and then:

- configures SDDM for the **X11** greeter (the Wayland greeter needs EGL, which this machine lacks). This selects the
  login screen only — it does not force sessions to X11; a Wayland session installed in `/usr/share/wayland-sessions`
  would still appear in the menu,
- makes **XFCE the default session** (`/home/alarm/.dmrc`) and leaves **i3 in the session menu** as the fallback,
- writes a usable `/home/alarm/.config/i3/config`,
- enables `display-manager.service` (SDDM) and disables `tarkin-console`, and enables `tarkin-dm-fallback.service`
  as the safety net.

The first boot therefore goes straight to the SDDM greeter. Log in as `alarm` (password `alarm` until you run
`passwd`); pick *Xfce Session* or *i3*.

If the graphical transaction fails (Wi-Fi dropped mid-install), the installer says so and the stick still boots to
`tarkin-console`, with the same install available from inside the running system:

```sh
bash ~/install-xfce.sh
sudo reboot
```

That script is also the repair path if you later want to redo the desktop half.

Read this before you do it:

- The greeter has already been seen drawing on this machine, but there is **no text console on this kernel**: if SDDM
  fails to start, the panel is black and there is nothing to read or type on. `tarkin-dm-fallback` covers the common
  case (no display manager running after ~50 s → the terminal comes back), not a greeter that runs but draws nothing.
- Rendering is software (`llvmpipe`). XFCE at 1920x1200 is usable but visibly slow; i3 is lighter, which is why it is
  the fallback.
- The screenshots-vs-reality rule: `journalctl -u sddm -b` and `~/.local/share/sddm/*.log` are your only diagnostics if
  the greeter fails, and reading them means mounting the stick from ChromeOS.

Undo (from ChromeOS, stick mounted):

```sh
sudo rm -f <mnt>/etc/systemd/system/display-manager.service
sudo ln -sfn /etc/systemd/system/tarkin-console.service \
  <mnt>/etc/systemd/system/multi-user.target.wants/tarkin-console.service
echo graphical | sudo tee <mnt>/etc/tarkin/console-mode
```

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

In `--console dm` mode `tarkin-session` says so and exits: the greeter owns the display, and the sessions are picked
there (Xfce / i3). Going back to `graphical` is described in [Console modes](#console-modes).

Two rules for this stick, because in the default mode the only display is `tarkin-console` and the ChromeOS kernel has
no text console:

- **Do not run a full `pacman -Syu` from the desktop session.** A sysupgrade rewrites glibc, systemd and wlroots and
  needs a very large flush; on a slow stick that used to end in `Kernel panic - not syncing: hung_task: blocked tasks`
  and a reboot in the middle of the transaction, leaving a black screen and no way in. `install-desktop.sh` therefore
  installs the desktop without a full upgrade; to upgrade deliberately use `sudo bash scripts/upgrade-stick.sh`,
  which throttles writeback and keeps `kernel.hung_task_panic=0`.
- **Do not install or enable a display manager in `graphical` mode** (gdm, sddm, lightdm): it takes `/dev/dri/card0`
  and the seat away from `seatd`/`tarkin-console`, and there is no working EGL (the renderer is `pixman`). The supported
  desktop here is the `labwc` one above. For a real login screen, reinstall with `--console dm`
  (see [Console modes](#console-modes)): SDDM and XFCE/i3 are then installed by the installer and the greeter is the
  only thing on the console.

## Touchpad

The trackpad is an Elan I2C-HID device, `04F3:31C6`. It works, but nothing is tuned for it: ChromeOS uses its own
gesture library, Arch uses `libinput` with generic defaults. That is the difference between "works" and "works well".

Diagnose it first — this decides whether it is a driver problem or a config problem:

```sh
sudo tarkin-touchpad
```

- If it says **`hid-multitouch`** owns the device, the hardware and driver are fine: tune `libinput` in
  `~/.config/labwc/rc.xml` (the `<libinput>` block written by `install-desktop.sh` enables tap-to-click, two-finger
  drag, palm rejection and a slower pointer).
- If it says **`hid-generic`**, the kernel is treating the touchpad as a clumsy absolute mouse (no multitouch, no
  two-finger scroll, jumpy pointer). The module is loaded after the device was already claimed by `hid-generic`,
  so `modules-load.d` alone does not help: `tarkin-touchpad.service` rebinds it to `hid-multitouch` at every boot
  (`journalctl -u tarkin-touchpad -b`). If the kernel has no `hid-multitouch`, it leaves the touchpad untouched.
- If events look crisp in `sudo libinput debug-events` but the pointer still feels laggy, the touchpad is innocent:
  the whole screen is software-rendered at 1920x1200.

The plain terminal (`cage` + `foot`) has no libinput settings at all; the tuning only applies to the `labwc` desktop.

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
| Freezes at "Updating MIME cache", then reboots / black screen | This is the known killer: pacman's final `sync()` waited >120 s for the USB stick, the hung-task watchdog panicked, and the machine rebooted mid-transaction. `sudo cat /sys/fs/pstore/console-ramoops-0` shows `task:pacman blocked` / `ksys_sync` / `hung_task: blocked tasks`. The sysctl file now sets `kernel.hung_task_panic=0` and throttles dirty writeback. If it already happened: boot ChromeOS, then from a PC `sudo bash scripts/repair-pacman-from-host.sh` (finishes the transaction under qemu), or re-run the installer. |
| Black screen after installing a desktop | Two causes: (1) a display manager was enabled and took the DRM node from `seatd`/`tarkin-console`; (2) the transaction above was interrupted and `cage`/`foot` are half-upgraded. Run `scripts/check-usb.sh`; it now reports a missing `kernel.hung_task_panic=0`, an enabled `sshd`/display-manager, and the last boot's console journal. |
| Touchpad is jumpy, no two-finger scroll, taps do nothing | `sudo tarkin-touchpad` (see [Touchpad](#touchpad)). If `hid-generic` owns it, rebind to `hid-multitouch`; if `hid-multitouch` owns it, it is a libinput tuning issue. |
| "I want a real desktop, XFCE/GNOME/KDE" | Don't. X11 DEs fight `tarkin-console` and there is no working EGL. Use the provided `labwc` desktop. |
| `sddm: Could not start display server on vt -1` | SDDM could not get a virtual terminal. In `graphical` mode that is expected: `tarkin-console` owns the display. Run `sudo tarkin-vtcheck`; if `VT_OPENQRY` is OK, reinstall with `--console dm` (see [Console modes](#console-modes)). If `VT_OPENQRY` fails, this kernel has no usable VT and no display manager can work: keep `tarkin-console`. |
| SDDM greeter never appears, panel black after installing XFCE | Nothing on this kernel can show a console, so there is no in-band diagnosis. Wait ~60 s: `tarkin-dm-fallback` starts `tarkin-console` when no display manager is running. If that does not come back, power-cycle and read `journalctl -u sddm -b` from the stick mounted in ChromeOS (`journalctl --directory=<mnt>/var/log/journal`). Undo with the commands in [XFCE + i3 + SDDM](#xfce--i3--sddm---console-dm). |
| `--console dm` boots to a black panel | The greeter started but cannot draw, or SDDM never got the VT. Check with `sudo tarkin-vtcheck` / `scripts/verify-vt.sh` (from ChromeOS, same kernel). There is no text console here, so this is a one-way door unless `tarkin-dm-fallback` brings `tarkin-console` back after ~50 s; otherwise use the undo commands in [Console modes](#console-modes). |
| `go.sh` finds no USB stick | Replug, wait 5 s, try another port (no hub) or another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 1) and put it in `/var/tmp`. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Try a phone hotspot. |
| `The rootfs came over plain http and no verifiable GPG signature is available` | The https mirrors failed and the http fallback cannot be authenticated. Download the tarball and its `.md5` with the ChromeOS browser (https) into `/var/tmp` and run the installer again; the installer then uses it. `ALLOW_INSECURE_HTTP=1` accepts the risk. |
| Warning that packages could not be installed | Same cause. Fix the network and run the installer again, or there will be no terminal. |
| "No valid image detected" | The firmware rejected the stick. `check-usb.sh` tells you why: wrong partition type, priority 0, bad signature, or `dev_boot_usb` at 0. |
| It boots ChromeOS instead | You missed the menu, or `dev_boot_usb` is 0: `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`. |
| Freezes right after "jumping to kernel" | The kernel preamble flags were not 0. The installer and `set-cmdline.sh` use `--flags 0`, so run the installer again or `set-cmdline.sh --normal`. |
| Back to the "OS verification is OFF" screen | The kernel started and died. Boot ChromeOS and run `check-usb.sh`, it prints the crash log. |
| Black screen for 3 minutes | The terminal didn't start. Look at the `console journal`, `drm` and `input` sections of `tarkin-boot.log`. |
| Wrong characters in the terminal | Edit `/etc/tarkin/console.env` (`XKB_DEFAULT_LAYOUT=us`), then `sudo systemctl restart tarkin-console`. |
| Text too small or too big | Edit `/etc/xdg/foot/foot.ini` (`font=monospace:size=14`). |
| `pacman` can't download | Check the network first: `getent hosts mirror.archlinuxarm.org`, `ping 1.1.1.1`. |
| Black screen, `journalctl -u tarkin-console -b` shows `216/GROUP` or `Failed to determine supplementary groups` | A group of the console service is missing from the stick's `/etc/group`. See [216/GROUP](#black-screen-with-216group-supplementary-groups) below. |
| The desktop doesn't start | It falls back to the terminal. See `journalctl -u tarkin-console -b`, or run `sudo tarkin-session terminal`. |

### Black screen with 216/GROUP (supplementary groups)

Symptom: the boot reaches userspace but the screen stays black. `journalctl -u tarkin-console -b` (or the
`console journal` part of `tarkin-boot.log`, printed by `check-usb.sh`) ends with
`tarkin-console.service: Failed to determine supplementary groups`, exit status `216/GROUP`, and the unit restarts
until the start limit (5 starts in 60 s) stops it.

Cause: `tarkin-console.service` declares `SupplementaryGroups=video input render audio seat`. If one of those groups
is missing from the stick's `/etc/group`, systemd cannot resolve it and refuses to start the service at all. On a
headless board that failure is invisible: just a black screen. This is what happened with seatd once — a group was
listed in the service but absent from the system.

Correction: boot ChromeOS and run `sudo bash scripts/check-usb.sh` — it checks every group of
`SupplementaryGroups=` against the stick's `/etc/group` and prints a `[PROBLEM]` line naming the missing one.
Fix by re-running the installer (it now creates any missing group before adding `alarm` to it), or by hand: mount the
stick's root partition read-write and run `groupadd -r <group>` inside it, then reboot.

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
- `scripts/check-usb.sh`: diagnoses a stick and the last failed boot (it also verifies that every group of the
  console service exists in the stick's `/etc/group`)
- `scripts/set-cmdline.sh`: rewrites the kernel command line of an installed stick
- `scripts/install-desktop.sh`: the optional desktop (the installer copies it to `/home/alarm`); it no longer runs a
  full `-Syu`, and it writes the touchpad/libinput config
- `scripts/install-xfce.sh`: XFCE + i3 + SDDM (also copied to `/home/alarm`), the repair path for the `dm` mode
- `scripts/upgrade-stick.sh`: the *safe* full upgrade (throttles writeback, keeps `hung_task_panic=0`, ignores the
  Arch kernel packages)
- `scripts/repair-pacman-from-host.sh`: finishes a transaction interrupted by a panic, from an x86_64 Arch PC
  (qemu-user-static + chroot)
- `scripts/verify-vt.sh`: wrapper for `tarkin-vtcheck` (VT layer check; also works from ChromeOS, same kernel)
- `scripts/identify-device.sh`: optional hardware report with HWID, serial and MAC removed
- `rootfs/`: files copied onto the stick (console service and launcher, `tarkin-wifi`, `tarkin-session`,
  `tarkin-touchpad`, `tarkin-vtcheck`, `tarkin-input.conf`, the dm fallback unit,
  seatd without VT, no suspend, panic/hung-task policy, boot report)
- `notes/tarkin-findings.md`: what has and hasn't been checked on the device, including the confirmed hung-task panic

## Safety

- Use a spare stick. Never point the installer at `/dev/mmcblk0`; it refuses non-removable disks and the running disk.
- The default account is `alarm` / `alarm` with automatic login. The installer disables the `sshd.service` that the
  Arch Linux ARM image enables by default, but check it (`systemctl is-enabled sshd`) if you move the stick to a
  network. Set a real password during the install, or run `passwd` right after the first boot.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification. Put the flags back when you stop using USB boot.
- Only do this on a machine you own or may modify. A school-managed Chromebook may forbid Developer Mode.
- Don't publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits

Based on zoan37's Omarchy / Arch Linux ARM Chromebook CM14 project, cut down to the Tarkin USB boot. The seatd
without VT idea comes from that project's work on another Skywalker variant. MIT license, see [`LICENSE`](LICENSE).
