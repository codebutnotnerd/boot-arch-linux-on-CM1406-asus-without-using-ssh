# Arch Linux ARM on the ASUS Chromebook CM1406 

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

Written but not tested on the hardware yet: the desktop in software rendering (`hyprland`, `waybar`, `fuzzel`). The
GPU part of `install-hyprland.sh` is tested on the machine (see the GPU section); the full "Hyprland (Mali GPU)"
session still needs a live test.

Reported working by testers: Bluetooth with audio, and the keyboard backlight LEDs. The touchpad is detected; it is tuned
only in the Hyprland desktop (see [Touchpad](#touchpad)). Not tested at all: suspend, touchscreen. The GPU is unused
by default; `install-hyprland.sh` makes Hyprland render on the Mali-G57 (see the GPU section).

Login is automatic as `alarm`, password `alarm` unless you set another one during the install. Change that password
at the first boot with `passwd`: the installer removes the `sshd.service` that the Arch Linux ARM image enables by default, but anyone holding the
machine can log in until you change it. Check with `systemctl is-enabled sshd`.
Suspend is off, the machine reboots 10 seconds after a kernel panic, and the journal is kept on the stick.

## You need

- A CM1406 in ChromeOS Developer Mode (the "OS verification is OFF" screen at every boot)
- A USB stick or external USB SSD of 8 GB or more, preferably USB 3.0. Everything on it will be erased. A stick that reports itself as an SSD (NAND chip, not flagged removable) is accepted; internal disks are not.
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

The installer tries this release first: <https://github.com/codebutnotnerd/boot-arch-linux-on-CM1406-asus-without-using-ssh/releases/download/rootfs-2026.08/ArchLinuxARM-aarch64-latest.tar.gz> (with the `.md5` and `.sig` next to it), then the official mirrors. This mirror is accepted when the GPG signature cannot be checked (the `.md5` still has to match; a signature that is checked and fails is still refused). Any other host that is not archlinuxarm.org needs a verifiable signature, or `ALLOW_UNSIGNED_MIRROR=1`.

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
| `--wifi-ssid <name>` | Use this Wi-Fi instead of the one saved in ChromeOS (it asks for the passphrase). |
| `--alarm <file or url>` | Rootfs tarball, with its `.md5` next to it (a `.sig` beside it is verified against the Arch Linux ARM key when `gpg` and a keyserver are available; a signature that does not verify stops the install). |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain (environment variable). |
| `ALLOW_NO_WIFI=1` | Ignore the Wi-Fi network saved in ChromeOS (configure it later with `sudo tarkin-wifi "Name"`). |
| `ALLOW_INSECURE_HTTP=1` | Accept a rootfs that came over plain http without a verifiable GPG signature. Refused by default. |
| `ALLOW_NO_PKGS=1` | Skip the network check and the packages. The stick will have no terminal. |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check. Not recommended. |

**5. Boot.** Leave the stick in, power off, power on. At the "OS verification is OFF" screen press `Ctrl+U`, or
use the arrow keys and Enter on "Boot from external disk" if you get the newer menu. After a minute or two a terminal
replaces the logo. If you did not set Wi-Fi during the install, run `sudo tarkin-wifi "NetworkName"`.

## Desktop

Needs Wi-Fi. Hyprland 0.57 and later read only `~/.config/hypr/hyprland.lua` (the old `hyprland.conf` is ignored), so the script writes both files. In the on-screen terminal:

```sh
bash ~/install-desktop.sh
sudo tarkin-session desktop
```

Then, for the Mali-G57 GPU (same Wi-Fi requirement, plus the packages `libc++`, `libc++abi`, `libdrm`, `python-pip`):

```sh
bash ~/install-hyprland.sh
```

It locates the ChromeOS `libmali` (read-only mount of the ChromeOS partitions, or `--mali-source /path/to/libmali.so`),
patches it for Arch's glibc (`GLIBC_ABI_DT_RELR`, automated with LIEF), compiles the EGL shim, runs the GPU probes
(10 DMA-BUF frames) and stops without installing anything if a probe fails (`--skip-gpu-test` to force). It installs
the stack under `/usr/local/lib/tarkin-gpu`, the launcher `/usr/local/bin/hyprland-mali`, the "Hyprland (Mali GPU)"
session, and updates the on-screen console. By default (v1.39) GDM is disabled and `tarkin-console` starts
Hyprland (Mali GPU) by itself at boot, because the GDM greeter goes black on the CM1406 as soon as a key is pressed.
GNOME stays installed; `--with-gdm` brings the GDM login screen back (gear: GNOME or Hyprland). `--dry-run` previews everything,
`--remove` takes the GPU session out, `--config-only` only writes `~/.config/hypr/hyprland.lua`: an existing config
that passes `Hyprland --verify-config` is kept, `--reset-config` rewrites it.

The script installs `hyprland`, `waybar`, `fuzzel`, `mako`, `swaybg`, `foot`, Papirus icons, the Inter font,
`adw-gtk-theme`, `pcmanfm` and `brightnessctl`, and writes a dark Windows-11-like setup into `~/.config` (taskbar centred at the
bottom, start menu on `fuzzel`). The screen restarts and shows the desktop, and keeps doing so at every boot.

Keys: `Super+d` start menu, `Super+Enter` terminal, `Super+e` files, `Super+q` close window, `Super+f` fullscreen, `Super+Shift+e` quit Hyprland. The brightness and volume keys work (`brightnessctl`, `wpctl`).

To go back to the plain terminal: `sudo tarkin-session terminal`. The console tries, in this order: `hyprland-mali`
(GPU), default Hyprland, Hyprland with software rendering, then the terminal; a try that dies within 15 s hands over to
the next one. `TARKIN_HYPR_RENDER=gpu|default|software` in `/etc/tarkin/console.env` pins one mode (anything else, and
the default, means `auto`). The software settings come from the Mesa and Hyprland documentation and have not been
confirmed on this machine. `bash ~/install-desktop.sh --configs-only` only rewrites the config files: an existing
`hyprland.lua` that verifies is kept (old copies are `*.bak.*`), `--reset-config` rewrites it. Rendering is in software
unless the GPU stack is installed.

## Tools on the stick

| Command | What it does |
|---|---|
| `sudo tarkin-diag` | One report file in your home folder: system, console log, Hyprland log and crash report, GPU, touchpad, Wi-Fi, Bluetooth, audio, battery, pacman. Wi-Fi names, passwords and MAC addresses are masked. Send it when something fails. |
| `tarkin-gpu-check` | GPU nodes, kernel driver, the installed GPU stack (`TARKIN_GPU_ROOT` overrides the path), the `GLIBC_ABI_DT_RELR` check on libmali, and the two GPU probes (`mali-probe`, `shim-probe`) with a timeout, then how to read the result. |
| `sudo tarkin-dns [--keep]` | When names do not resolve but `ping 1.1.1.1` works: Cloudflare then Quad9 on `wlan0`. `--keep` makes it permanent and ignores the router's DNS. |
| `sudo tarkin-touchpad` | Touchpad diagnosis (see below). |
| `sudo bash ~/upgrade-stick.sh` | Safe full upgrade (no kernel packages, writeback throttled). The installer copies `scripts/upgrade-stick.sh` to `/home/alarm`. |

## Touchpad

The trackpad is an Elan I2C-HID device, `04F3:31C6`. `hid-multitouch` is loaded after `hid-generic` has already claimed
it, so `tarkin-touchpad.service` rebinds it to `hid-multitouch` at every boot (`journalctl -u tarkin-touchpad -b`). If
the kernel has no `hid-multitouch`, it leaves the touchpad untouched. Diagnose with:

```sh
sudo tarkin-touchpad
```

The Hyprland desktop sets tap-to-click, tap-and-drag, two-finger right click, natural scrolling at 0.6 speed and
disable-while-typing. The plain terminal
(`cage` + `foot`) has no libinput settings at all.

`/etc/libinput/local-overrides.quirks` sets the pressure thresholds of this touchpad to 15:10. With libinput's
default for this device (25:30) a light touch, such as the tip of the finger, is ignored and the pointer freezes while
libinput still reports motion. Check the active values with `grep pressure-based` in the Hyprland log.

## Audio

The sound card is `mt8189_rt5650`. PipeWire only exposes the `off` and `pro-audio` profiles for it, so the use case
profile is applied by hand: `rootfs/usr/share/alsa/ucm2/mt8189_rt5650/` holds the ChromeOS profile
(`mt8189_rt5650.tarkin`) and `tarkin-audio.service` (user unit, enabled by `install-hyprland.sh` and `install-desktop.sh`, which install PipeWire) selects `pro-audio`, enables the speaker route with
`alsaucm`, sets the hardware speaker volume to 22 and makes `pro-output-0` the default sink.

`/etc/wireplumber/wireplumber.conf.d/51-tarkin-audio.conf` forces 16-bit 48 kHz: the card sounds distorted with the
24-bit format PipeWire picks by default.

The ChromeOS speaker chain (80 Hz high-pass, equalizer, compressor in `/etc/cras/tarkin.*/dsp.ini`) is not
reproduced, so do not raise `Speaker Playback Volume` above about 22 without listening carefully. F13 and F14 lower
and raise the software volume.

Tested by hand on the owner's machine: the speakers play. Headphones, microphones and HDMI were not tested.

## GPU (Mali-G57)

`install-hyprland.sh` makes the desktop render on the GPU instead of the CPU. What is tested, on the machine, by the
installer itself before it touches anything:

| Item | Status |
|---|---|
| Kernel detects the Mali-G57 (KBase driver `r54p1-12eac0`, `/dev/mali0`, `/dev/dri/renderD128`) | Checked |
| `libmali.so.0.54.1` (same DDK) located and copied read-only from the ChromeOS partitions (or `--mali-source`) | Checked |
| `DT_RELR` metadata patched with LIEF so Arch's glibc loads it (automated; verified with `readelf -V`) | Pass |
| EGL 1.5 and OpenGL ES 3.2 (`GL_RENDERER=Mali-G57`) | Pass |
| Framebuffer clear and pixel read-back | Pass |
| DMA-BUF render into a DRM dumb buffer, 10 frames, 0 bad | Pass |
| EGL shim (EGL_EXT_device_*, platform_device) probe | Pass |
| Probes re-run from the installed paths; launcher reaches Hyprland (`-- --version`) | Pass |
| "Hyprland (Mali GPU)" session running live under GDM | GDM greeter goes black on a keypress (`gdm-password: conversation failed`); GDM is off by default since v1.39 |
| Firefox acceleration and video decoding | Not tried |

The whole install can be staged without touching the system:
`TARKIN_PREFIX=/some/dir bash install-hyprland.sh --gpu-only --mali-source /path/to/libmali.so` — it skips pacman,
systemctl and the ChromeOS mounts. Without `--skip-gpu-test` a failed probe stops the script before anything is
installed. The ChromeOS partition is mounted with `mount -o ro,noload` and never written to. The Mali libraries live
in `/usr/local/lib/tarkin-gpu/mali/lib` and are picked up through `LD_LIBRARY_PATH` only by the `hyprland-mali`
launcher; system Mesa, `libEGL` and `libGLESv2` are left alone, so GNOME keeps working exactly as before. Extra
packages used: `libc++`, `libc++abi`, `gcc`, `libdrm`, `python-pip` with `lief` in a virtualenv. The probe programs and
the EGL shim come from zoan37's MT8189 project
(<https://github.com/zoan37/lenovo-slim3-chromebook-omarchy>, `bringup/`), which is built for Hyprland.

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
| Kernel panic `hung_task: blocked tasks` with `task pacman ... blocked for more than 122 seconds` in the crash log | The ChromeOS kernel panics when a task waits more than 2 minutes, and `pacman` does exactly that when it syncs a big install to a slow USB stick. Fixed in new installs (`kernel.hung_task_panic = 0`). On an existing stick, before installing anything big, run `sudo sysctl -w kernel.hung_task_panic=0` and add that line to `/etc/sysctl.d/90-tarkin-panic.conf`. |
| Hyprland: `CBackend::create() failed` right after the logo | Hyprland found no usable display/GPU backend. Don't start it from inside the terminal (`cage` already owns the display): use `sudo tarkin-session desktop`. This kernel exposes the Mali GPU through the proprietary KBase driver (there is no `panfrost` module), so Hyprland needs either the Mali userspace from the GPU section below or Mesa software rendering. Send `~/.cache/hyprland/hyprlandCrashReport*.txt` and the `hyprland.log` it names. |
| Black screen or kernel panic after installing another desktop or display manager | Not supported: they fight for the display and need a VT the ChromeOS kernel does not have. Stick to `install-desktop.sh` (Hyprland) plus `install-hyprland.sh` (GPU): they keep GDM and `tarkin-console` from running at the same time. To repair without reflashing, boot ChromeOS, mount the stick's second partition, check the `etc/systemd/system/display-manager.service` link (`scripts/repair-pacman-from-host.sh` only removes it when it dangles) and run `sudo bash scripts/check-usb.sh`. |
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
- `scripts/install-desktop.sh`: the optional desktop (the installer copies it to `/home/alarm`)
- `install-hyprland.sh`: the Mali-G57 GPU stack, the "Hyprland (Mali GPU)" session in GDM and the GPU-aware console
- `scripts/upgrade-stick.sh`: safe system upgrade on the stick (no kernel packages, writeback throttled; the installer copies it to `/home/alarm`)
- `scripts/repair-pacman-from-host.sh`: repairs a stick whose pacman transaction was interrupted, from ChromeOS
- `rootfs/usr/local/bin/tarkin-diag`, `tarkin-gpu-check`, `tarkin-dns`, `tarkin-touchpad`: the tools above
- `scripts/identify-device.sh`: optional hardware report with HWID, serial and MAC removed
- `rootfs/`: files copied onto the stick (console service and launcher, `tarkin-wifi`, `tarkin-session`, seatd without
  VT, no suspend, panic reboot, boot report)
- `notes/tarkin-findings.md`: what has and hasn't been checked on the device

## Safety

- Use a spare stick. Never point the installer at `/dev/mmcblk0`; it refuses anything that is not a USB device, and the running disk.
- The default account is `alarm` / `alarm` with automatic login and nothing listening for SSH. Set a real password
  during the install, or run `passwd` right after the first boot.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification. Put the flags back when you stop using USB boot.
- Only do this on a machine you own or may modify. A school-managed Chromebook may forbid Developer Mode.
- Don't publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits

Based on zoan37's Omarchy / Arch Linux ARM Chromebook CM14 project, cut down to the Tarkin USB boot. The seatd
without VT idea comes from that project's work on another Skywalker variant. MIT license, see [`LICENSE`](LICENSE).

## Changes in v1.39

- `install-hyprland.sh` no longer makes GDM the display manager. On the CM1406 the GDM greeter shows, then turns
  black on the first keypress; the journal shows `gdm-password: pam_unix conversation failed` (the greeter dies while
  asking for the password). The script now disables `gdm.service`, enables `tarkin-console.service` (which starts
  `hyprland-mali`, then Hyprland, software rendering, then the terminal) and sets `multi-user.target`. GNOME stays
  installed. `--with-gdm` keeps the old behaviour. Without a `tarkin-console` unit it still falls back to GDM.
- v1.39.1: it also sets `TARKIN_SESSION=desktop` in `/etc/tarkin/console.env`. The USB installer writes `terminal`
  there, so v1.39 booted straight to the bare terminal instead of Hyprland. On a stick already installed:
  `sudo tarkin-session desktop`.
- v1.39.2: it also installs the sound stack (`pipewire`, `wireplumber`, `pipewire-pulse`, `libpulse`, `alsa-utils`,
  `alsa-ucm-conf`), enables PipeWire in the user session and enables `tarkin-audio.service`. Only `install-desktop.sh`
  did this before, so a stick set up with `install-hyprland.sh` played no sound (browsers included). On a stick
  already installed: `sudo pacman -S --needed pipewire wireplumber pipewire-pulse libpulse alsa-utils alsa-ucm-conf`,
  `systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service`,
  `sudo systemctl --global enable tarkin-audio.service`, `systemctl --user restart tarkin-audio.service`, then restart
  the browser. If `pulseaudio` is installed the script skips `pipewire-pulse` (pacman would abort on the conflict).
- v1.39.3: the use case profile is also linked as `conf.d/mt8189_rt5650/HiFi.conf`, which `alsaucm` needs to turn the
  speaker route on (without it `alsaucm` failed with error -2 and the route was lost after a reboot). `install-hyprland.sh`
  no longer reports a failure when `tarkin-audio.service` is already enabled. The USB installer refuses a rootfs
  downloaded from a host other than archlinuxarm.org (and other than the project's own mirror) unless its GPG signature verifies against the Arch Linux ARM key
  (`ALLOW_UNSIGNED_MIRROR=1` overrides). On a stick already installed:
  `sudo ln -sf ../../mt8189_rt5650/HiFi.conf /usr/share/alsa/ucm2/conf.d/mt8189_rt5650/HiFi.conf`.
- Fixing a stick stuck on the black GDM screen without reinstalling: boot ChromeOS, mount the stick's root partition
  on `/tmp/stick`, then `rm -f /tmp/stick/etc/systemd/system/display-manager.service`,
  `ln -sf /usr/lib/systemd/system/multi-user.target /tmp/stick/etc/systemd/system/default.target` and
  `ln -sf /etc/systemd/system/tarkin-console.service /tmp/stick/etc/systemd/system/multi-user.target.wants/`.
  ChromeOS has no `journalctl`: read the stick's journal after booting Arch (`journalctl -u gdm`).

## Changes in v1.38

- `install-hyprland.sh` run with `sudo` wrote the Hyprland config to `/root` and then failed with "The generated
  config does not verify". It now refuses to run as root (run it as your user: `bash install-hyprland.sh`, it calls
  sudo itself), and when the config check fails it prints Hyprland's errors.

## Changes in v1.37

- `install-hyprland.sh` failed with `unable to satisfy dependency 'libsoup' / 'webkit2gtk'`: it installed the whole
  `gnome` group, and on Arch Linux ARM `gnome-books` and `gnome-boxes` depend on `webkit2gtk`/`libsoup` (removed from
  the repos), so pacman cancelled the entire install. It now installs only the GNOME desktop (gnome-shell, gdm,
  gnome-session, control center, nautilus, console, text editor, ...). Each package is first checked to see whether
  pacman can resolve its dependencies, and a broken one is skipped with a warning instead of failing the whole install. No more
  63-package selection or qemu prompt either.

## Changes in v1.36

- Black screen at boot (the terminal never appeared, or only after a long wait): the console launcher started
  `cage` without the settings the earlier working release used. `cage` is wlroots, and without
  `WLR_RENDERER=pixman` it tries GLES2 through Mesa, and there is no working EGL for this display on the ChromeOS kernel. It now starts the
  terminal with `WLR_RENDERER=pixman`, `WLR_NO_HARDWARE_CURSORS=1` and `WLR_DRM_DEVICES=<MediaTek card>`, in all three
  copies of the launcher (`rootfs/usr/local/libexec/tarkin/console`, `install-hyprland.sh`, `scripts/install-desktop.sh`).
  The Hyprland modes are unchanged: they still unset `WLR_RENDERER`.
- The launcher exports `DBUS_SESSION_BUS_ADDRESS` again (it is a system service, so apps started from it could not
  reach the user D-Bus).
- `/etc/sysctl.d/90-tarkin-panic.conf`: the dirty-page limits are back (`vm.dirty_background_bytes=8 MiB`,
  `vm.dirty_bytes=32 MiB`, `kernel.hung_task_timeout_secs=120`). Without them a big pacman transaction on a slow stick
  can stall for minutes.

Repair a v1.35 stick without reflashing (from ChromeOS, stick plugged in, `sdX` = the stick):

```
sudo mkdir -p /tmp/stick && sudo mount /dev/sdX2 /tmp/stick
sudo install -m 755 rootfs/usr/local/libexec/tarkin/console /tmp/stick/usr/local/libexec/tarkin/console
sudo install -m 644 rootfs/etc/sysctl.d/90-tarkin-panic.conf /tmp/stick/etc/sysctl.d/90-tarkin-panic.conf
sudo umount /tmp/stick
```

## Changes in v1.35

- `install/install-usb.sh`: with `ALLOW_NO_PKGS=1` (or when the package step failed and `sudo` is not installed) the
  installer aborted on the missing `/etc/sudoers.d` before writing the kernel; the directory is now created.
- `install/install-usb.sh`: a `.sig` that cannot be checked (no `gpg`, no keyserver) is no longer reported as a bad
  signature and no longer aborts an https or local install; a plain-http download without a verified signature is
  still refused unless `ALLOW_INSECURE_HTTP=1`. A signature that really fails still aborts.
- `install/install-usb.sh`: the Wi-Fi passphrase read from ChromeOS now comes from the same saved network as the name.
- `install/install-usb.sh`: `upgrade-stick.sh` is copied to `/home/alarm` (the README listed it as a tool on the stick,
  but it was never copied).
- `install-hyprland.sh`: finding libmali on the ChromeOS partitions failed every time (the file was copied after the
  partition had been unmounted, and a status line ended up inside the returned path). It is now copied while mounted.
- `install-hyprland.sh`: the default run no longer stops on a missing `gcc`, `readelf` or EGL/DRM headers before the
  package step that installs them; they are checked right after it. `--config-only` and `--remove` no longer need them.
- `install-hyprland.sh`: `--gpu-only` no longer enables GDM or disables `tarkin-console` (the help says it does not
  touch GDM); `TARKIN_PREFIX` staging no longer runs `pacman` without `--gpu-only`.
- `scripts/install-desktop.sh`: a failed `pacman -Syu` now stops the package step (before, `set -e` was ignored in that
  subshell and the packages were installed on a half-upgraded system). It also enables `tarkin-audio.service`, which
  nothing enabled before, so the speakers were never routed.
- `tarkin-session`: refuses to restart `tarkin-console` while GDM owns the display, and says how to switch.
- `tarkin-wifi`: writes the new config to a temporary file first (a failure no longer leaves an empty config) and
  keeps the `country=` line.
- `tarkin-touchpad`: an unbound touchpad is reported as "no driver bound" instead of driver "driver".
- `scripts/check-usb.sh`: the fstab/PARTUUID check no longer prints a shell arithmetic error when they don't match.
- `scripts/repair-pacman-from-host.sh`: works from ChromeOS (aarch64 host: no qemu, no `pacman` on the host), stops with
  instructions if the stick is mounted `noexec`, and no longer masks the `systemd-sysusers` hook.
