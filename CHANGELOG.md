# Changelog

## v1.60

Not tested on the CM1406 yet; the automated tests are mocks (niri 26.04 `niri validate` was run for real on the
generated configs).

New:

- **No desktop at the first boot, then `tarkin-desktop`**: the first boot installs the Mali GPU stack, sound and the
  Hyprland files (`install-hyprland.sh --no-autostart`) but starts no desktop; it restarts into the terminal, and every
  terminal says how to choose. `tarkin-desktop` (`choose-desktop.sh`) offers niri + Vitrum Plus v10 or Hyprland with
  the base config, also as `--niri`, `--hyprland`, `--none`, `--undo-niri`, `--status`. It can be run again to switch;
  `--undo-niri` takes Vitrum Plus and niri out again. `scripts/install-vitrum-plus-niri-v10.sh` is in the release and
  copied to every stick.
- **niri**: `install-niri.sh` is the script with the EGL fix (`/usr/local/lib/tarkin-gpu/niri/lib/libEGL.so.1`, linked
  with `-Bsymbolic`, returning its own `eglGetProcAddress`) and is copied to every stick. If niri fails, Hyprland
  starts. Undo: `bash ~/install-niri.sh --remove`.
- **`--wm niri|hyprland` (optional)**: no question any more at install time. `sudo bash install.sh --wm niri` (or
  `TARKIN_WM=niri`, or `--wm hyprland`) only preselects the desktop that the first boot sets up and starts. Kept when
  an install is resumed.
- `install-hyprland.sh --no-autostart`: installs everything but leaves the boot on the terminal.
- **Super+Shift+S in niri**: screenshot of a region with niri's own `screenshot` action (clipboard and
  `~/Pictures/Screenshots`). New configs get it. An existing config gets only that line under `binds {`, after
  `niri validate`, with a copy in `config.kdl.before-tarkin-screenshot`; `--screenshot-key` does only this step,
  `--remove` takes it out.
- **4-image Vulkan layer** (`install-gpuapp.sh`): the layer is built with `{ 4, 0 }` instead of `{ 2, 0 }` in
  `wsi/wayland/surface_properties.cpp` and `SOURCE` gets `min_image_count=4`. With 2 images Firefox on the GPU froze
  under niri; the same change by hand fixed it on the CM1406 (2026-11-21). An older layer is rebuilt on the next run
  and kept in `layer/backup-min-images-2`; `--layer-rollback` puts it back byte for byte. A layer already fixed with
  `fix-gpuapp-wsi-images.sh` is kept as is.
- `install-gpuapp.sh` accepts a niri desktop on the GPU, not only Hyprland.

Fixed:

- `mkfs.ext4: /dev/sda2 is apparently in use by the system` on a reused stick. Before writing anything the installer
  now checks what uses the stick: mounts (also in other mount namespaces), swap, device-mapper/LVM/RAID, and programs
  with a file, folder or the device open (read from `/proc`, no `fuser` needed). It lists them (process number and
  name, mount point) and stops with nothing changed. The check runs again before partitioning and before `mkfs.ext4`.
  `umount -l` is no longer used: it hid the program that kept the partition busy. The start of each old partition
  is zeroed before the new table is written, so ChromeOS does not mount the old `ALARM` filesystem again during the
  table reread (`partx -u`, `partprobe` or `blockdev --rereadpt`, then `udevadm settle`). If `mkfs.ext4` still
  refuses, the check runs once more and `mkfs.ext4` is retried once.
- The target is also checked with `tarkin_is_safe_usb_disk` (whole USB disk, not the ChromeOS disk) and refused when
  it holds `/`, `/usr/local`, `/home`, `/var` or the stateful partition.
- Smooth mode that seemed to turn off by itself:
  - under niri nothing was boosted (only `Hyprland` was clamped); niri is clamped now;
  - the GPU floor was written once at start: if the GPU node appeared after the service, or the minimum went back down
    later, it stayed off until the next boot. The service now waits for the node and sets the floor again (the
    journal counts each reset);
  - when the GPU is hot the kernel lowers the maximum and the minimum follows it; the journal and `status` now say so
    instead of looking like smooth mode was off;
  - `tarkin-smooth status` said "on" when the service was enabled but had stopped; it now says what runs.
- `install-hyprland.sh` restarts a running `tarkin-smooth.service` after updating its files.

Faster:

- The smooth mode loop starts no program while the desktop runs (v1.50: `pgrep`, `uclampset`, `tr` and `sleep`
  every 15 s, 16 programs a minute).
- `install-hyprland.sh` checks the package list with one `pacman -Qq`, one `pacman -Slq` and one `pacman -Sp`
  instead of up to three `pacman` calls per package (about 40 packages); the old per-package check stays as fallback.
- `install-gpuapp.sh` downloads only the pinned commit of `vulkan-wsi-layer` (`git fetch --depth 1`), with the full
  clone as fallback.
- The boot report written 90 s after boot runs at the lowest CPU and disk priority.

Tests: mocks only (a fake `/sys` and `/proc`, mocked `cgpt`, `mkfs.ext4`, `umount` and the first boot; no real
disk). `tests/test_v150.py` now reads the version from `VERSION`.

## v1.50

Not tested on the CM1406 yet; the automated tests are mocks.

New:

- **Keys** (`install-hyprland.sh`, `scripts/install-desktop.sh`): `F6`/`F7` screen brightness down/up, `F8` keyboard
  backlight on/off (`tarkin-kbd-backlight`, first `*kbd_backlight*` LED, quiet when there is none), next to the
  existing `F13`/`F14` volume keys and `XF86` keys (`XF86KbdLightOnOff` added). New configs get them; an existing
  `hyprland.lua`/`hyprland.conf` gets them appended once unless it already binds F6-F8, loads other files or stops
  verifying (then it is restored).
- **Smooth mode (optional, off by default)**: `sudo tarkin-smooth on|off`, `tarkin-smooth status`. GPU minimum
  526 MHz when listed in `available_frequencies` (factory 390 MHz) and Hyprland clamped to a minimum utilization of
  512 so it stays on the fast cores; kept across reboots by `tarkin-smooth.service`; `off` restores the saved values.
- **First-boot failure report**: `install-hyprland.sh` names its steps; when the first boot fails,
  `/var/lib/tarkin/firstboot.reason` holds the step, the reason and what to type, every new terminal shows it, open
  terminals get a one-line message, and `check-usb.sh` and `tarkin-diag` print it.

Fixed:

- `install-gpuapp.sh`: `pkgconf` is installed and checked (the build stopped with "Could NOT find PkgConfig" on a
  fresh stick).
- Rerunning `install-hyprland.sh` on a stick made before v1.40: it stopped because GDM was enabled, and it replaced
  `tarkin-session` with a short name for `tarkin-display` without installing `tarkin-display`. It now installs
  `tarkin-display`, `display-guard` and the current `tarkin-console.service` from the release tree, disables GDM for
  the next boot when no display owner was ever chosen, and keeps the old `tarkin-session` when `tarkin-display` is
  still missing. `cage` is in the package list.
- The first boot no longer stops on optional parts: missing `hypridle`, `swaylock` or `python3` only skip the screen
  lock; missing GNOME or GDM only matters with `--with-gdm`; when installing all packages at once fails, they are
  retried one by one and the ones that still fail are listed.
- `--dry-run` no longer says it would disable GDM when the real run does not.

Tests: `tests/test_v150.py` (keys, keyboard backlight, smooth mode, older sticks, first-boot report, packages) and one
more display-owner case in `tests/test-display.py`.

## v1.40

Follows the release tagged v1.35 on GitHub. That release already contained everything from the section "Between
v1.39.3 and v1.40" downward, so the GitHub tags do not line up with the section numbers of this file. Nothing is
removed.
Not tested on the CM1406 yet unless stated; the automated tests are mocks (no real device, mount, pacman or display).

New:

- **GPU driver on a fresh stick** (`install-hyprland.sh`): the ChromeOS `libmali` search no longer assumes ext4.
  `ROOT-A`/`ROOT-B` come from `lsblk`, their format from `blkid -p`, and they are mounted read-only in a private mount
  namespace (`ro,noload` for ext3/ext4, `ro` for ext2, EROFS and SquashFS; other formats skipped). Every candidate is
  checked (readable, complete, ELF64 AArch64 shared object) and its size and SHA-256 printed; an invalid
  `--mali-source` stops instead of falling back. The GPU probes stop after 45 s.
- **Bluetooth and light lock** (`install-hyprland.sh`): `bluez`, `bluez-utils`, `blueman`, `pavucontrol`, `hypridle`,
  `swaylock`; `bluetooth.service` enabled. `Super+L` locks, 300 s idle locks, the screen turns off at 330 s once the
  lock is confirmed, no suspend (`tarkin-lock`, `tarkin-dpms`, `tarkin-comfort-start`, `/etc/xdg/tarkin/`). Existing
  Hyprland, hypridle and swaylock configs are kept. The jack watcher keeps a selected Bluetooth output or microphone.
  A Bluetooth failure (blocked radio, service or tools missing) is reported but does not stop the first boot.
- **`sudo tarkin-update`**: full `pacman -Syu` keeping back every package that owns kernel, module or header files.
  `scripts/upgrade-stick.sh` now runs it (old sticks without it keep the previous `pacman -Syu --noconfirm --ignore ...`).
- **Optional XFCE + SDDM** (experimental): `bash ~/install-xfce.sh`, then `sudo tarkin-display xfce` and reboot.
  Hyprland stays the default and SDDM is never enabled by the installer.
- **`sudo tarkin-display hyprland|xfce|terminal`**: one display owner, for the next boot, with checks and rollback.
  `tarkin-console.service` refuses to start while a display manager owns the screen (`display-guard`).
- **Applications on the GPU (optional)**: `bash ~/install-gpuapp.sh` installs `gpuapp <program>` (Mesa Zink on the
  Vulkan driver of libmali, per program; nothing system-wide, `--remove` undoes it). Run on the CM1406 on
  2026-11-18: the script installed and `gpuapp --check` answered
  `apps on the GPU: yes (zink Vulkan 1.4(Mali-G57 (ARM_PROPRIETARY)))`; `vkcube`, `eglgears_wayland` and Firefox
  (WebRender) rendered on the Mali-G57. `--remove`, `--measure` and the udev rule across a reboot are not checked
  there, and no benchmark was taken. That run found one bug, fixed before release: the `vk_icd` check used
  `grep -q` under `set -o pipefail`, so `readelf` was killed by SIGPIPE on the real libmali and the script refused
  a good driver. See [docs/REFERENCE.md](docs/REFERENCE.md#applications-on-the-gpu-optional).
- **Offline display recovery** from ChromeOS: `scripts/recover-display.sh`, see `docs/DISPLAY-RECOVERY.md`.
- **Firefox DRM (optional)**: `tarkin-firefox-widevine` configures a `widevine` package you built yourself
  (`MOZ_GMP_PATH` in `/etc/environment`, copies into the Firefox profiles). The manual steps made Spotify play on the
  CM1406; the helper itself is not tested there. `tarkin-console` exports that `MOZ_GMP_PATH` to Hyprland when the
  helper's line and the `/opt/WidevineCdm` files check out (it never runs `/etc/environment`). See
  `docs/FIREFOX-WIDEVINE.md`.

Changed:

- `tarkin-session desktop|terminal` is now `tarkin-display hyprland|terminal`: it takes effect at the next boot and no
  longer restarts the running screen.
- `install-hyprland.sh` keeps a `hyprland.lua` that does not verify and stops (it used to replace it), keeps an
  existing `hyprland.conf` when there is no `hyprland.lua`, no longer falls back to GDM when `tarkin-console.service`
  is missing, and refuses `--with-gdm` (or the console) while SDDM/XFCE or an unknown display manager owns the next boot.
- `install/install-usb.sh` also copies `install-xfce.sh` and `install-gpuapp.sh` to `/home/alarm`.
- Comments were removed from the scripts, the units and the configuration files; the code is otherwise unchanged.
  Shebangs, `shellcheck` directives and the third-party notices stay. What the comments explained is in
  [docs/REFERENCE.md](docs/REFERENCE.md).
- Messages and documents no longer use the working numbers of the versions between v1.39.3 and v1.40; the three
  sections concerned are kept below under one heading.
- README rewritten. `LICENSE` now names zoan37's repository correctly (`lenovo-slim3-chromebook-omarchy`); the
  license text is unchanged.

Tests (mocked): `python3 -m unittest discover -s tests` (update, gpuapp and Widevine environment; the latter needs
root in a throwaway container), `python3 tests/test-comfort.py`, and as root in a throwaway container only
`python3 tests/test-display.py`. The gpuapp tests include the `readelf` case above, with a symbol table large
enough to trigger it.

## Between v1.39.3 and v1.40 (already in the release tagged v1.35 on GitHub)

### Password question fix

Bug fix in the password question of `install/install-usb.sh` (nothing else changed):

- "The two passwords differ" came back every time, even when only Enter was pressed. VT2 keeps every key pressed
  while the installer is busy (the long download, the signature check, the network check), for example a key
  pressed to wake the screen. That hidden text was glued in front of the first entry, so it never matched the
  second one. Keys pressed before the question are now thrown away, and each typed character shows as `*` so
  the two entries can be compared by eye. When they still differ, the installer says how many characters each
  had and asks again (5 tries) instead of stopping. Backspace erases one character, Ctrl+U the whole entry, arrow
  and function keys are ignored. The Wi-Fi passphrase question works the same way now.

### Rootfs download fixes

Bug fixes in the rootfs download of `install/install-usb.sh` (nothing else changed):

- A network cut during the download threw the partial file away: the installer then went through the other
  mirrors, and each unreachable one deleted it, so the next run started again from zero. The partial file is now
  only given up once another mirror really answers, and the next run continues it.
- After the https mirrors had failed once, a rootfs fetched over plain http (refused without a verifiable
  signature) was reused by every later run and refused again, even with the https mirrors back. Such a download
  is no longer reused: the next run tries the mirrors in their normal order (https first). With
  `ALLOW_INSECURE_HTTP=1` it is still reused.
- A rootfs whose signature does not verify was kept and checked again on every run, so the install could never
  get past it. It is now deleted, and the next run downloads it again.
- `--dry-run` could delete an earlier download (one from a mirror no longer in the list, or a damaged one) and
  wrote to the progress file. It now only says what a real run would do.
- A message said "rerunning the installer continues it" when moving to the next mirror, which was not true.

### One-command installer, first boot, sound, password

New:

- **One command**: `sudo bash install.sh` (top of the repository; `install/go.sh` is the same). It resumes an
  interrupted install: progress in `/var/tmp/tarkin-install/state`, the rootfs download continues where it stopped
  (`curl -C -`) and is kept for the next stick, finished steps are skipped (partitioning, extraction, kernel modules,
  packages, password, Wi-Fi), a stale pacman lock on the stick is removed, and every failure ends with the command to
  run again. `--dry-run` checks and prints the plan without changing anything; `--fresh` starts over; `--no-desktop`
  makes a terminal-only stick.
- **First boot**: `tarkin-firstboot.service` runs `install-hyprland.sh` as `alarm` once the network is up (Hyprland,
  Mali GPU, sound), then disables itself and restarts into Hyprland. Notice in every terminal, log in
  `/var/log/tarkin-firstboot.log`, 3 attempts at most. `install-hyprland.sh` still works on its own.
- **Sound**: `tarkin-audio.service` now follows the headset jack (speakers muted and headphones on when they are
  plugged in, built-in or headset microphone), sets a first volume of 60 % (speakers) / 40 % (headphones) and then keeps
  yours. New `tarkin-audio-test` (one-photo summary), bigger audio section in `tarkin-diag`, settings in
  `/etc/tarkin/audio.conf`. See [Audio](docs/REFERENCE.md#audio).
- **After a ChromeOS update**: `sudo bash scripts/repair-boot.sh` checks Developer Mode, the USB boot flag
  (`dev_boot_external` or `dev_boot_usb`, whichever the firmware knows, read back after setting), `dev_boot_signed_only`,
  the stick and its kernel partition attributes, and repairs what it can after a confirmation. On the stick,
  `tarkin-bootcheck.service` warns when the kernel partition is not marked successful.
- **Password**: required at install (twice, 8 characters or more, must not contain `alarm`; with a non-US layout only
  the letters whose keys are the same on QWERTY/AZERTY/QWERTZ, because VT2 types in QWERTY). `root` is locked once
  `sudo` is checked (sudo installed, `alarm` in `wheel`, `visudo -c` passes). Non-interactive runs need
  `TARKIN_PASSWORD_FILE`. `alarm`/`alarm` and `root`/`root` are never kept.

Fixed on the way:

- `install-usb.sh`: when the package step failed, it still ended with `[+] USB written` and exit code 0; it now stops
  with an error after writing the kernel and the next run retries only the packages.
- `install-usb.sh`: with no password, `root` kept the image password `root` (and `alarm` kept `alarm`).
- `install-usb.sh`: a checksum mismatch on one mirror aborted the whole install instead of trying the next mirror, and
  any interruption threw the 800 MB download away (it lived in a temporary directory).
- `install-usb.sh`: the Wi-Fi SSID is written in hex (no quoting problem whatever its characters), and the passphrase
  is still hashed on a resumed run whose first package step had failed.
- `install-usb.sh`, `check-usb.sh`, `preflight-tarkin.sh`: only `dev_boot_usb` was known; newer firmware calls the flag
  `dev_boot_external`. Both are now detected.
- `set-cmdline.sh --normal/--debug` wrote the current ChromeOS kernel even when the stick only has modules for the
  kernel it was made with (after a ChromeOS update): the stick would boot without Wi-Fi or sound. It now refuses
  (`ALLOW_MODULE_MISMATCH=1` overrides).
- `audio-profile`: `amixer -c 0` assumed the sound card is card 0; the card is now found by its id. It reset the volume
  to 100 % at every login; it now keeps the last volume. `Speaker Playback Volume` (not part of the use case profile)
  is only set when the card has it.
- `install-desktop.sh`: did not enable the PipeWire sockets, and warned "Could not enable tarkin-audio.service" when it
  was already enabled (the same false alarm v1.39.3 removed from `install-hyprland.sh`); it now also installs
  `libpulse` (pactl) and `python` explicitly.
- `upgrade-stick.sh` said the installers leave GDM enabled; since v1.39 it is the other way round.
- `install-hyprland.sh`, `install-usb.sh`, `preflight-tarkin.sh`: a missing `/proc/device-tree/compatible` printed a
  shell error (the `2>/dev/null` came after the redirection).

### Updating an older stick (made before the one-command installer)

Making the stick again is simplest (`sudo bash install.sh`). To update the sound and boot-check files only, from
ChromeOS (VT2) with the stick plugged in (`sdX` = the stick), in the unpacked release folder:

```sh
sudo mkdir -p /usr/local/stick && sudo mount /dev/sdX2 /usr/local/stick
for f in audio-profile audio-jack bootcheck shell-notice; do sudo install -m 755 rootfs/usr/local/libexec/tarkin/$f /usr/local/stick/usr/local/libexec/tarkin/$f; done
sudo install -m 755 rootfs/usr/local/bin/tarkin-audio-test rootfs/usr/local/bin/tarkin-diag /usr/local/stick/usr/local/bin/
sudo install -m 644 rootfs/etc/systemd/user/tarkin-audio.service /usr/local/stick/etc/systemd/user/tarkin-audio.service
sudo install -m 644 rootfs/etc/tarkin/audio.conf /usr/local/stick/etc/tarkin/audio.conf
sudo install -m 644 rootfs/etc/systemd/system/tarkin-bootcheck.service /usr/local/stick/etc/systemd/system/
sudo ln -sf /etc/systemd/system/tarkin-bootcheck.service /usr/local/stick/etc/systemd/system/multi-user.target.wants/
sudo install -m 755 -o 1000 -g 1000 install-hyprland.sh /usr/local/stick/home/alarm/install-hyprland.sh
sudo umount /usr/local/stick
```

Then on the stick: `sudo pacman -S --needed python`, `systemctl --user daemon-reload`,
`systemctl --user restart tarkin-audio.service`, and `tarkin-audio-test`. Set a real password with `passwd` and lock
root with `sudo passwd -l root` if you have not done so.

## v1.39

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

## v1.38

- `install-hyprland.sh` run with `sudo` wrote the Hyprland config to `/root` and then failed with "The generated
  config does not verify". It now refuses to run as root (run it as your user: `bash install-hyprland.sh`, it calls
  sudo itself), and when the config check fails it prints Hyprland's errors.

## v1.37

- `install-hyprland.sh` failed with `unable to satisfy dependency 'libsoup' / 'webkit2gtk'`: it installed the whole
  `gnome` group, and on Arch Linux ARM `gnome-books` and `gnome-boxes` depend on `webkit2gtk`/`libsoup` (removed from
  the repos), so pacman cancelled the entire install. It now installs only the GNOME desktop (gnome-shell, gdm,
  gnome-session, control center, nautilus, console, text editor, ...). Each package is first checked to see whether
  pacman can resolve its dependencies, and a broken one is skipped with a warning instead of failing the whole install. No more
  63-package selection or qemu prompt either.

## v1.36

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

## v1.35

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
