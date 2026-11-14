# Tarkin (ASUS CM1406, MT8189) - findings

Source: output collected by the user on their own machine (ChromeOS, developer mode). No identifier (HWID,
partition UUID, serial number, MAC) is reproduced here. "Seen in the DT" means node names only.

## Verified on the device

| Topic | Finding |
|---|---|
| Board | `compatible` = `google,tarkin`, `mediatek,mt8189`; model "Google Tarkin board" |
| SKU | `sku-id` = `0x1005` (4101), in the FIT configuration group `google,tarkin-sku4101/4103/4104/4106` |
| Kernel | 6.6.147 (ChromeOS); active LSMs: capability, landlock, yama, **loadpin**, safesetid, chromiumos, selinux, bpf |
| Storage | **eMMC** `mmcblk0` (116 GB), no active UFS; p1 STATE (encrypted), p2/p4 kernels 32 MB, p3/p5 roots 4 GB, p12 EFI 64 MB |
| Slot | Root on `mmcblk0p5` -> active kernel on `p4` (KERN-B) |
| Stock kernel | ~14 MB FIT containing `mt8189-skywalker-tarkin.dtb` and the overlays `tarkin-touchscreen`, `tarkin-kb-cm1406`, `tarkin-kb-cm1406-backlight`, `tarkin-ca-kb-cm1406`, `tarkin-ca-kb-cm1406-backlight` (and cm1405/cm1505 variants) |
| Repack | `futility vbutil_kernel --repack` with the devkeys: exit 0, "Body verification succeeded", flags 0 (0x1 froze the boot on this board) |
| Panel | EDID manufacturer `CSW`, product `0x143f`; modes 1920x1200 and 1600x1200 |
| Audio | ALSA card `mt8189_rt5650` |
| Input | `cros_ec`, `cros_ec_buttons`, `gpio-keys`, `hid-over-i2c 04F3:31C6 Touchpad`, headset/DP/HDMI jacks; no touchscreen listed |
| Battery | `sbs-10-000f` (address 0x0f); USB-C ports through `ucsi` on the EC (SPI) |
| Wi-Fi / BT | PCIe `14c3:7925` (MT7925) behind a `14c3:8189` bridge; USB `13d3:3602` (probably Bluetooth, unconfirmed) |
| ChromeOS tools | Present: cgpt, futility, bsdtar, dtc, mkfs.ext4, chroot, curl. **Absent: python3, git, dumpimage, mosys** |
| Mounts | `/usr/local` (encrypted stateful) is not `noexec`; `mount` works |

## Seen in the DT (node names only)

- `i2c@11b20000/audio-codec@1a`, `/audio-codec` with `enable-gpios`
- `i2c@11f30000/trackpad@2c` and `trackpad@15` (only one touchpad detected: 04F3:31C6)
- `spi@11010800/ec@0` and `spi@11011800/ec@0`
- `mmc@11230000`, `mmc@11240000`; `ufshci@112b0000` present but eMMC in use
- `pwm@1100e000` + `/backlight`, `edp-tx@11b70000`, `dp-tx@11b60000`, `pcie@112f0000`
- `i2c@11d73000/ite61620@58`, `i2c@11d70000/tpm@50`, `i2c@11d72000/proximity@28`

## Not established

- The exact audio codec and amplifier (only the card name `mt8189_rt5650` is known) and a matching UCM profile.
- Audio, touchpad, suspend and the labwc desktop under Arch Linux ARM.
- GPU integration with the compositor (the Mali libraries pass standalone EGL, framebuffer and DMA-BUF tests only).

## First successful boot (2026-11-10)

- The Tarkin froze silently right after depthcharge printed "jumping to kernel" when the repacked kernel had
  preamble `--flags 0x1`. Re-signing with `--flags 0` (same as the stock kernel) boots: ext4 root mounted r/w,
  PID 1 started, `cage` + `foot` terminal appears on the built-in screen.
- Method that found it: write the unmodified stock kernel to the stick (it panics on dm-verity after ~4 s, proving the
  USB path works), then re-sign it step by step with `scripts/set-cmdline.sh` (`--same`, `--probe`, `--normal`). A warm
  reset after a kernel panic keeps `/sys/fs/pstore/console-ramoops-0`; holding Power wipes it.
- Confirmed working afterwards: on-screen terminal, built-in keyboard, Wi-Fi (MT7925) and pacman.

## ALARM mirror status (2026-11-11)

- https://os.archlinuxarm.org and https://mirror.archlinuxarm.org currently serve a certificate whose SAN does not
  match the hostname (curl error 60). http:// works and redirects to a regional mirror chosen by geography
  (fr.mirror.archlinuxarm.org from France, nj/fl.us.mirror.archlinuxarm.org from the US); the latest tarball is
  about 790 MB and its .md5 is served beside it.
- install-usb.sh therefore tries several mirrors in order (https first, then http) and verifies the tarball with
  the .md5; scripts/preflight-tarkin.sh reports the mirror over http when https fails.

## Terminal failure seen once: 216/GROUP (supplementary groups)

- Symptom: black screen; `tarkin-console.service` restarted again and again (about 16 restarts in the journal), then
  the journal ends with `Failed at step GROUP` / `Failed to determine supplementary groups`, status `216/GROUP`.
- Cause: a group listed in `SupplementaryGroups=` of `tarkin-console.service` did not exist in the rootfs
  `/etc/group`; systemd refuses to start the unit, and on a headless board that failure is invisible (black screen).
- Now handled:
  - `scripts/check-usb.sh` checks every group of `SupplementaryGroups=` (plus the `User=`/`Group=` of the unit, and
    the linger file for `alarm`) against the stick's `/etc/group` and prints `[PROBLEM]` naming the missing one.
  - `install/install-usb.sh` creates any missing group (`groupadd -r`) before adding `alarm` to it, and warns if a
    service group still does not exist in the rootfs.
  - `tarkin-console.service` no longer hardcodes UID 1000 (`user@1000.service`, `/run/user/1000` are gone): the
    launcher waits up to 60 s for `/run/user/<uid>` (the installer enables linger for `alarm`, so the user manager
    starts whatever the UID is) and up to 20 s for a `/dev/dri/card*` node. The unit has
    `StartLimitIntervalSec=60` / `StartLimitBurst=5`, so it stops after 5 failed starts in 60 s instead of looping
    forever.


## Confirmed root cause: hung-task panic during a USB-rootfs pacman transaction (2026-11-14)

Symptom: installing a desktop (XFCE) hung at "Updating MIME cache", the machine rebooted, and the next boot was a
black screen with no way in (the ChromeOS kernel has no text console).

Evidence from `/sys/fs/pstore/console-ramoops-0` after the crash:

```
INFO: task pacman:547 blocked for more than 122 seconds.
task:pacman  state:D
  wb_wait_for_completion -> sync_inodes_sb -> sync_inodes_one_sb -> iterate_supers
  -> ksys_sync -> arm64_sys_sync -> ...
Kernel panic - not syncing: hung_task: blocked tasks
CPU: 4 PID: 72 Comm: khungtaskd
Rebooting in 10 seconds..
```

What it means:

- `pacman` reached the end of the transaction, called `sync()`, and waited in `wb_wait_for_completion` for the USB
  stick to flush the dirty pages. The default `vm.dirty_ratio` (20 % of 4 GB ~ 800 MB) lets a whole sysupgrade pile up
  in RAM first.
- The stick could not drain it in time. Measured with `dd oflag=direct conv=fsync`: **3.9 MB/s** (USB 3.0 link, 5000M,
  so the link was not the limit). 122 s x 3.9 MB/s ~ 475 MB: the backlog could never have made it.
- `kernel.hung_task_panic=1` (kernel default here) turns the stall into a panic; `kernel.panic=10` from
  `rootfs/etc/sysctl.d/90-tarkin-panic.conf` reboots 10 s later, in the middle of the transaction.
- Unsynchronised writes are lost: `pacman.log` ended as 36864 bytes with 1988 NUL bytes, the classic signature of a
  file extended but never flushed. `db.lck` survived, so the package database and the file tree disagreed, `cage`/
  `foot` ended up half-upgraded, and `tarkin-console.service` failed 5 times -> black screen.

Fixes now in the repository:

- `rootfs/etc/sysctl.d/90-tarkin-panic.conf`: `kernel.hung_task_panic=0`, plus `vm.dirty_bytes=32 MB` /
  `vm.dirty_background_bytes=8 MB`.
- `scripts/install-desktop.sh` no longer runs a full `pacman -Syu`; it installs the desktop with `-S --needed`,
  throttles writeback, checks free space and refuses to run with a display manager enabled.
- `scripts/upgrade-stick.sh`: the deliberate, guarded way to sysupgrade.
- `scripts/repair-pacman-from-host.sh`: finishes an interrupted transaction from an x86_64 PC via qemu + chroot.
- `install/install-usb.sh` disables the `sshd.service` the ARM image leaves enabled.

The stick itself is healthy (57 GB, 7 % used, 50 GB free); the failure was I/O scheduling plus the panic policy, not
disk space and not OOM (`Memory Limit: none`).

## Console modes: `graphical` and `dm` (tty removed)

Two installer options, recorded in `/etc/tarkin/console-mode`:

- `graphical` (default): `tarkin-console` (`cage` + `foot`) owns the DRM node. `getty@tty1` is explicitly disabled so
  it cannot draw over the compositor.
- `dm`: SDDM (X11 greeter) owns the console, with XFCE as the default session and i3 in the session menu. Installed by
  the installer itself (see below).

`--console tty` existed for a while and has been **removed**. Reason, confirmed on the hardware: this kernel cannot show
a text console at all -- the install-time guard (fbcon + `/dev/fb0` + `/dev/tty0`) fired on the real CM1406. A getty on
`tty1` would run and draw nothing, so the mode could only ever produce a black panel. Removed files:
`rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf`,
`rootfs/etc/systemd/system/tarkin-tty-fallback.service`, `rootfs/usr/local/libexec/tarkin/tty-fallback`.

### VT check pitfall: /dev/tty0 is not visible in every shell

The installer originally refused `--console dm` whenever `/dev/tty0` was not a character device, and printed "this
kernel has no VT layer". That was wrong in the shells people actually use: ChromeOS's crosh `shell` and the Linux
container do not expose `/dev/tty0`, while the kernel has a complete VT layer (VT2 itself works). The check now looks at
`/sys/class/tty/tty0` (kernel-provided, visible from any namespace) and only refuses when **both** it and `/dev/tty0`
are missing; otherwise it warns and continues. It no longer refuses `--console dm` in any case: if the kernel really has no
VT, SDDM fails and `tarkin-dm-fallback` lands on `tarkin-console`, so the wrong answer cannot brick the stick. `tarkin-vtcheck`
and `preflight-tarkin.sh` report the two separately and say when the shell is the problem.

## VTs exist, but nothing can draw on them

Why SDDM used to say `Could not start display server on vt -1`, and why a text console is not an option:

- `VT_OPENQRY` / `/dev/ttyN` prove the *VT layer* exists (that is what `vt -1` is about). It does exist here: ChromeOS
  itself runs on VT2 on this machine, and the VT devices are present.
- Text on a VT additionally needs `fbcon` registered **and** a framebuffer device (`/dev/fb0`). ChromeOS kernels
  normally build out DRM fbdev emulation (`CONFIG_DRM_FBDEV_EMULATION`), because ChromeOS never displays a kernel text
  console on the panel.
- `cage`, Xorg and SDDM do their own KMS modesetting, which is why the graphical console (and a potential greeter) can
  work on exactly the same kernel while a getty cannot.

`tarkin-vtcheck` (`scripts/verify-vt.sh` from the repo) reports: `/dev/tty0`, number of VTs, `console/active`,
`tty0/active`, whether `tarkin-console`/`getty@tty1`/`seatd` are enabled, who holds `/dev/tty[0-9]`, and the decisive
`VT_OPENQRY` ioctl (0x5600) with a writable int, which is exactly what SDDM calls. `--activate ttyN` is opt-in: it
switches the panel to that VT for 3 s and back, which is the only way to prove a VT console reaches the display; on a
kernel without a VT console the panel can stay black, hence opt-in.

Checked locally on the development host: 64 VT devices, `VT_OPENQRY` returns a free VT, `fgconsole` fails when not
attached to a console (as expected). Non-root: the script refuses to run, since `/dev/tty0` needs root.

Consequence for `dm`: a failed greeter leaves a black panel with no on-screen error. That is the one risk this mode
carries, and it is why `graphical` remains the default.

## `--console dm`: XFCE + i3 + SDDM in one pass

Design, given that nothing can be shown or typed outside a display manager:

Confirmed by the owner: on an earlier build SDDM did work, because `tarkin-console` was not working and SDDM had been
enabled in systemd. So the earlier success is explained: the console stack was dead (`cage`/`foot` half-installed after
the interrupted `-Syu`), nothing held the display, and `systemctl enable sddm` gave the greeter the console. That also
proves the X11 greeter can draw on this panel. `--console dm` reproduces the state deliberately: `tarkin-console` is
disabled and SDDM owns the display.

- `--console dm` (installer) requires a VT layer only (a display manager needs a VT; it does NOT need fbcon because it
  draws through DRM). If there is no fbcon it warns that a failed greeter is unrecoverable on screen.
- The installer now installs the graphical stack **in the same chroot transaction** as the terminal packages:
  `xorg-server`, `xorg-xinit`, `xorg-xauth`, `xf86-input-libinput`, `mesa`, `sddm`, the `xfce4` and
  `xfce4-goodies` groups, and
  `i3-wm`/`i3status`/`i3lock`/`dmenu`/`xterm`. Xorg/SDDM failing is non-fatal: the stick then boots to
  `tarkin-console` and the summary says to run `bash ~/install-xfce.sh`.
- Configuration is written by `scripts/install-xfce.sh --configs-only` against the mounted rootfs, so the installer and
  the in-system repair path use the same code: `/etc/sddm.conf.d/10-tarkin.conf` with `DisplayServer=x11` (the Wayland
  greeter needs EGL), `Session=xfce` in `/home/alarm/.dmrc`, and an i3 config if the user has none.
- `display-manager.service` is created as the sddm alias; `tarkin-console` is disabled; `tarkin-dm-fallback.service` is
  enabled. The fallback's job: after ~50 s, if `display-manager.service` is not active (or was never configured), start
  `tarkin-console`. So a greeter that crashes or exits usually returns the terminal instead of leaving a black panel.
- `scripts/install-xfce.sh` is the same install from inside the running system (repair path), with the same writeback
  throttling and hung-task policy as `install-desktop.sh`, and no `-Syu`. It deliberately does not start SDDM from
  inside the running compositor (two things would draw on the panel): reboot is the hand-over.
- `tarkin-session` refuses to switch console sessions in dm mode and says how to go back to `graphical`.

Known now: the X11 greeter draws on this panel (the owner's earlier build). Still untested: whether XFCE and i3 behave
under software rendering at 1920x1200, and whether the greeter is stable across boots. If it misbehaves, the recovery is
ChromeOS + mount + `rm display-manager.service` (or wait for `tarkin-dm-fallback`). The mode stays opt-in and `graphical`
remains the default.
