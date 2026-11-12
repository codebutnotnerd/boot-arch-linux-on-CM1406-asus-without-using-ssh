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

