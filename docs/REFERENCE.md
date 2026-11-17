# Reference (v1.50.2)

Full details. The short version is in [README.md](../README.md).

## What works

Tested on a real CM1406:

- Booting from USB in Developer Mode
- The on-screen terminal and the built-in keyboard
- Wi-Fi (MT7925) and `pacman`

- Hyprland on the Mali-G57 GPU, started by itself at boot through `tarkin-console` (since v1.39)

Written but not tested on the hardware yet: the desktop in software rendering, the v1.50 first-boot setup, the
v1.50 sound routing (speakers / headphones / microphones, see [Audio](#audio)) and `scripts/repair-boot.sh`.

Reported working by testers: Bluetooth with audio, and the keyboard backlight LEDs. The touchpad is detected; it is tuned
only in the Hyprland desktop (see [Touchpad](#touchpad)). Not tested at all: suspend, touchscreen. The GPU is unused
by default; `install-hyprland.sh` makes Hyprland render on the Mali-G57 (see the GPU section).

Login is automatic as `alarm` (the on-screen terminal and Hyprland start without a login screen). Since v1.50 the
installer requires a password for `alarm` (used by `sudo`) and locks the `root` account: the image defaults
`alarm`/`alarm` and `root`/`root` are never kept. The installer also removes the `sshd.service` that the Arch Linux
ARM image enables by default (check with `systemctl is-enabled sshd`). Anyone holding the unlocked machine still
gets the auto-logged-in terminal; the password protects `sudo`.
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

The one command is `sudo bash install.sh`, in VT2 (steps 2 and 4). Everything else is preparation or checks.

**1. Download** this repository as a zip with the ChromeOS browser into Downloads. The rootfs is downloaded by the
installer (about 800 MB; an interrupted download continues on the next run). You may also download
<https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz> plus its `.md5` file next to it with the browser;
the installer then uses that copy. Prefer the browser and https: a `.md5` fetched over plain http from the same
server does not prove the file is genuine.

The installer tries this release first: <https://github.com/codebutnotnerd/boot-arch-linux-on-CM1406-asus-without-using-ssh/releases/download/rootfs-2026.08/ArchLinuxARM-aarch64-latest.tar.gz> (with the `.md5` and `.sig` next to it), then the official mirrors. This mirror is accepted when the GPG signature cannot be checked (the `.md5` still has to match; a signature that is checked and fails is still refused). Any other host that is not archlinuxarm.org needs a verifiable signature, or `ALLOW_UNSIGNED_MIRROR=1`.

**2. Unpack** in the crosh tab (`Ctrl+Alt+T`, then `shell`):

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/<repository-zip-name>.zip
ls /var/tmp
```

Note the name of the unpacked folder. If you downloaded the rootfs with the browser too:
`cp ~/MyFiles/Downloads/ArchLinuxARM-aarch64-latest.tar.gz* /var/tmp/` then
`md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5` (must say `OK`).

**3. Preflight.** Plug in the stick, switch to VT2 and run:

```sh
cd /var/tmp/<unpacked-folder>
sudo bash scripts/preflight-tarkin.sh
```

The report goes to `/var/tmp/pf/report.txt`. You want `board: OK (google,tarkin)` and `repack: OK`. If any line says
`MISSING`, `ABSENT` or `FAILED`, stop and look at it. An `ABSENT` on an `mt7925` firmware line is harmless.

**4. Install**, still in VT2 — the one command:

```sh
sudo bash install.sh
```

(`sudo bash install/go.sh` is the same thing.) It finds the rootfs and the stick, shows you the device and makes you
type its name before erasing anything. It checks that the package mirror answers before it erases anything, and it
reads the kernel back after writing it. Wait for `[+] USB written` before you unplug. `sudo bash install.sh --dry-run`
runs the checks and prints the plan without downloading, writing or changing anything.

**Password (required).** It asks twice for the password of `alarm` (used by `sudo` on the stick): at least 8
characters, not containing `alarm`. The default `alarm` is never kept, and `root` is locked once `sudo` is checked to
work (if `sudo` could not be installed, `root` gets the same password instead of its default `root`).
VT2 types as a US QWERTY keyboard while the stick uses your layout (`fr` by default), so with any layout other than
`us` the password may only use the letters `b c d e f g h i j k l n o p r s t u v x` (upper or lower case): their keys
are the same on QWERTY, AZERTY and QWERTZ, so you type the same keys later on the stick. `TARKIN_PASSWORD_ANY_CHARS=1`
lifts that rule. For a run without a keyboard, put the password on the first line of a root-only file and set
`TARKIN_PASSWORD_FILE=/path/to/file`; without it a non-interactive run stops before writing anything.

**Interrupted?** Progress is kept in `/var/tmp/tarkin-install/state`, the download in `/var/tmp/tarkin-install/download`,
the log in `/var/tmp/tarkin-install.log` (all survive a reboot). Run `sudo bash install.sh` again with the same stick
plugged in: it finds the stick of the interrupted install and offers to resume. Finished steps are skipped (download,
partitioning, rootfs extraction, kernel modules, packages, password, Wi-Fi); the kernel is signed and written again
each time. `--fresh` ignores the interrupted install and starts over.

Options go after `install.sh`, for example `sudo bash install.sh --keymap us`:

| Option | Meaning |
|---|---|
| `--dry-run` | Checks and plan only; nothing is downloaded, written or changed. |
| `--fresh` | Ignore an interrupted install and start over (the stick is erased again). |
| `--no-desktop` | Terminal only: no first-boot Hyprland / GPU / sound setup. |
| `--keymap <layout>` | Keyboard layout of the terminal (`fr`, `us`, `de`, ...). Default `fr`. |
| `--wifi-ssid <name>` | Use this Wi-Fi instead of the one saved in ChromeOS (it asks for the passphrase). |
| `--alarm <file or url>` | Rootfs tarball, with its `.md5` next to it (a `.sig` beside it is verified against the Arch Linux ARM key when `gpg` and a keyserver are available; a signature that does not verify stops the install). |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain (environment variable). |
| `ALLOW_NO_WIFI=1` | Ignore the Wi-Fi network saved in ChromeOS (configure it later with `sudo tarkin-wifi "Name"`). |
| `ALLOW_INSECURE_HTTP=1` | Accept a rootfs that came over plain http without a verifiable GPG signature. Refused by default. |
| `ALLOW_NO_PKGS=1` | Skip the network check and the packages. The stick will have no terminal. |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check. Not recommended. |
| `ALLOW_UNSIGNED_MIRROR=1` | Accept a rootfs from a host other than archlinuxarm.org (and other than this project's GitHub mirror) without a verifiable GPG signature. Refused by default. |
| `TARKIN_PASSWORD_FILE=/path` | Non-interactive runs: password of `alarm` on the first line of this root-only file. |

**5. Boot.** Leave the stick in, power off, power on. At the "OS verification is OFF" screen press `Ctrl+U`, or
use the arrow keys and Enter on "Boot from external disk" if you get the newer menu. After a minute or two a terminal
replaces the logo. If you did not set Wi-Fi during the install, run `sudo tarkin-wifi "NetworkName"`.

**6. First boot (automatic).** `tarkin-firstboot.service` waits for the network, then runs `~/install-hyprland.sh` as
`alarm` (never as root): Hyprland, the Mali GPU stack, the GNOME packages and the PipeWire sound stack. It takes 20 to
60 minutes; every terminal shows a notice while it runs, and the progress is in `/var/log/tarkin-firstboot.log`
(`tail -f /var/log/tarkin-firstboot.log`). Do not power off. When it is done the machine restarts once and Hyprland
starts by itself. If it fails, the next boot tries again (3 times at most); the log says why, and
`bash ~/install-hyprland.sh` (as `alarm`, without `sudo`) does the same by hand. During the run only, a temporary sudo
rule lets `alarm` use `sudo` without a password (the script needs it); it is removed when the run ends, by the
service's stop step, and at every boot by `/etc/tmpfiles.d/tarkin-firstboot.conf`. Extra `install-hyprland.sh`
options (for example `--with-gdm`) go in `/etc/tarkin/firstboot.conf` as `FIRSTBOOT_ARGS="--with-gdm"`;
`FIRSTBOOT_REBOOT=0` restarts the display instead of the machine.

## Desktop

Since v1.50 the first boot does this by itself (see Install, step 6); this section is for doing it by hand, on a stick
made with `--no-desktop` or before v1.50. Needs Wi-Fi. Hyprland 0.57 and later read only `~/.config/hypr/hyprland.lua` (the old `hyprland.conf` is ignored), so the script writes both files. In the on-screen terminal:

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
| `tarkin-audio-test` | Sound check, as `alarm` without `sudo`: card, use case profile, every mixer control of the profile, PipeWire sinks and sources, jack state, then plays a test sound on the speakers and the headphones and records the microphones (loopback). Ends with a one-screen summary: take one photo of it. `--status` only prints the state. |
| `journalctl -u tarkin-bootcheck -b` | Boot check (v1.50): warns, in the journal and in every new terminal, when the stick's kernel partition is not marked successful or the kernel modules are missing. Read-only. |

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

The sound card is `mt8189_rt5650` (Realtek RT5650 codec). The use case profile is the ChromeOS one,
`rootfs/usr/share/alsa/ucm2/mt8189_rt5650/HiFi.conf` (also linked under `conf.d/mt8189_rt5650/`, which `alsaucm`
needs). It has a `Speaker` device on PCM 0, `Headphone` on PCM 1, `Internal Mic` on PCM 2 and the headset `Mic` on PCM 3.

`tarkin-audio.service` (user unit, `/usr/local/libexec/tarkin/audio-profile`, settings in `/etc/tarkin/audio.conf`):

- keeps PipeWire on the `pro-audio` profile (one PipeWire node per PCM) and switches the routes of the use case
  profile itself with `alsaucm`;
- speakers by default; when the headset jack reports headphones it turns the `Speaker` device off (speakers muted),
  the `Headphone` device on, and makes the headphone node (`pro-output-1`) the default sink; unplugged, the other way
  round. The microphone follows the same way (built-in mic, or the headset mic when the jack reports one);
- the jack is read by `/usr/local/libexec/tarkin/audio-jack` (Python, standard library) from the input device named in
  the profile (`JackDev "mt8189_rt5650 Headset Jack"`, switches 2 = headphone and 4 = microphone, as in `JackSwitch`);
- first volume: 60 % on the speakers and 40 % on the headphones (`TARKIN_SPEAKER_VOLUME`, `TARKIN_HEADPHONE_VOLUME`),
  then your last volume is kept across reboots. 100 % (1.0) is the full digital level: it does not clip by itself, but
  the ChromeOS speaker processing (high-pass, equalizer, compressor in `/etc/cras/tarkin.*/dsp.ini`) is not reproduced,
  so loud content at full level distorts the small speakers, and headphones at full level can be very loud;
- the hardware speaker gain `Speaker Playback Volume` stays at 22 as before (only if the card has that control: it is
  not part of the profile). Do not raise it without listening carefully.

Why not let WirePlumber use the profile itself: WirePlumber switches outputs from the jack only through a
`JackControl` value (an ALSA control name). The ChromeOS profile has none, only `JackDev`/`JackSwitch`, which only
ChromeOS reads, and this project does not invent control names. `TARKIN_AUDIO_PROFILE=hifi` in
`/etc/tarkin/audio.conf` lets PipeWire use the profile directly anyway (experimental, no automatic switching), `off`
disables `tarkin-audio`. After a change: `systemctl --user restart tarkin-audio.service`.

`/etc/wireplumber/wireplumber.conf.d/51-tarkin-audio.conf` forces 16-bit 48 kHz: the card sounds distorted with the
24-bit format PipeWire picks by default.

Keys (Hyprland): the volume keys (`XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute`) and F13/F14 change
the default sink with `wpctl` (raise is capped at 100 %), so they follow the switch to the headphones;
`XF86AudioMicMute` (v1.50) mutes the default microphone. These are written into a new config only: an existing
`~/.config/hypr/hyprland.lua` that verifies is kept (`bash ~/install-hyprland.sh --config-only --reset-config`
rewrites it, keeping a backup). Which keysyms the CM1406 top row sends is not checked yet (`wev`). Commands: `wpctl status`,
`/usr/local/libexec/tarkin/audio-profile info`, `.../audio-profile route 1 0` (headphones) or `route 0 0` (speakers).

Checked on the machine: with v1.39.3 (by hand) the speakers play. Not yet checked: the v1.50 headphone switching, the
microphones, HDMI. Run `tarkin-audio-test` and send the photo of its summary.

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

## After a ChromeOS update or powerwash

What can stop the Chromebook from booting the stick, and what `sudo bash scripts/repair-boot.sh` (ChromeOS, VT2)
does about it. It checks first, prints what is wrong, and repairs only after you confirm (`--check` only checks):

| What | Check | Repair |
|---|---|---|
| Developer Mode was turned off (pressing Space at the warning screen, or a recovery) | `crossystem devsw_boot` = 1, `mainfw_type` = developer | Cannot be done by a script. Turn it on again (Esc+Refresh+Power, then Ctrl+D). This erases the ChromeOS user data, not the stick. Download this repository again, then run `repair-boot.sh`. |
| USB boot flag reset (firmware update, Developer Mode turned off and on) | `dev_boot_external` (newer firmware) or `dev_boot_usb` (older), whichever the firmware knows, must be 1; `dev_boot_signed_only` must be 0 | `crossystem <flag>=1 dev_boot_signed_only=0`, then read back |
| The stick's kernel partition marked bad (priority 0, or not "successful" so every boot uses up a try) | `cgpt show -i 1 -P/-T/-S` on the stick | `cgpt add -i 1 -P 15 -T 1 -S 1` on the stick only (never on the internal eMMC; the script checks it is a USB disk with partition 2 labelled ALARM) |
| The stick is missing or not recognised | a USB disk with a ChromeOS kernel partition 1 and an ALARM partition 2 | plug it in directly (no hub) and run again |
| The kernel on the stick does not verify | `futility vbutil_kernel --verify` | not repaired: make the stick again |

A ChromeOS update does not change the stick: it keeps the kernel it was made with, together with that kernel's
modules. `scripts/set-cmdline.sh --normal/--debug` would write the *current* ChromeOS kernel, so since v1.50 it refuses
when the stick has no modules for it. On the stick, `tarkin-bootcheck.service` warns at boot when the kernel partition
is not marked successful.

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
| ChromeOS reboots by itself during the install | Fixed: the package step now runs in an isolated chroot (own mount/pid namespace, read-only `/proc/sys`), risky pacman hooks are masked, and the host's panic/vm settings are restored. Since v1.50, run `sudo bash install.sh` again after the reboot: it resumes. The full log is in `/var/tmp/tarkin-install.log`; if it keeps happening, send that file plus `ls /sys/fs/pstore`. |
| The first-boot setup (Hyprland, GPU, sound) failed | Every terminal says so. Read `tail -n 40 /var/log/tarkin-firstboot.log`, fix the cause (often the network), then `sudo systemctl restart tarkin-firstboot` or `bash ~/install-hyprland.sh` (as `alarm`, without `sudo`). From ChromeOS, `check-usb.sh` prints the end of that log. |
| No sound, or sound on the wrong output | Run `tarkin-audio-test` (as `alarm`) and send the photo of its summary. |
| `install.sh` finds no USB stick | Replug, wait 5 s, try another port (no hub) or another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 1) and put it in `/var/tmp`. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Try a phone hotspot. |
| `The rootfs came over plain http and no verifiable GPG signature is available` | The https mirrors failed and the http fallback cannot be authenticated. Download the tarball and its `.md5` with the ChromeOS browser (https) into `/var/tmp` and run the installer again; the installer then uses it. `ALLOW_INSECURE_HTTP=1` accepts the risk. |
| Warning that packages could not be installed | Same cause. Fix the network and run the installer again, or there will be no terminal. |
| "No valid image detected" | The firmware rejected the stick. `check-usb.sh` tells you why: wrong partition type, priority 0, bad signature, or `dev_boot_usb` at 0. |
| It boots ChromeOS instead | You missed the menu, or USB boot is off (after a ChromeOS update?): `sudo bash scripts/repair-boot.sh`. |
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
`sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1` (on newer firmware the flag is called `dev_boot_external`;
`scripts/preflight-tarkin.sh` shows which one yours knows).

## What's in the repository

- `install.sh`: THE install command (`sudo bash install.sh`); starts `install/go.sh`
- `install/go.sh`: guided launcher for VT2, finds the tarball and the stick, offers to resume an interrupted install
- `install/install-usb.sh`: the installer (resumable; logs to `/var/tmp/tarkin-install.log`, progress in `/var/tmp/tarkin-install/`)
- `scripts/repair-boot.sh`: checks and repairs what lets the Chromebook boot the stick (after a ChromeOS update)
- `scripts/lib-chromeos.sh`: helpers shared by the ChromeOS-side scripts (USB boot flag name, stick detection)
- `rootfs/usr/local/libexec/tarkin/firstboot` + `tarkin-firstboot.service`: the first-boot Hyprland / GPU / sound setup
- `rootfs/usr/local/libexec/tarkin/audio-profile`, `audio-jack`, `rootfs/etc/tarkin/audio.conf`, `tarkin-audio-test`: sound
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
- The account `alarm` logs in automatically and nothing listens for SSH. Its password (required at install since v1.50)
  protects `sudo`; `root` is locked. On a stick made before v1.50, run `passwd` (and `sudo passwd -l root`).
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification. Put the flags back when you stop using USB boot.
- Only do this on a machine you own or may modify. A school-managed Chromebook may forbid Developer Mode.
- Don't publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits

Based on zoan37's Omarchy / Arch Linux ARM Chromebook CM14 project, cut down to the Tarkin USB boot. The seatd
without VT idea comes from that project's work on another Skywalker variant. MIT license, see [`LICENSE`](../LICENSE).

