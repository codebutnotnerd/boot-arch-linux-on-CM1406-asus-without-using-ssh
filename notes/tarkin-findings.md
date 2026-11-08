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
| Repack | `futility vbutil_kernel --repack` with the devkeys: exit 0, "Body verification succeeded", flags 0x1 |
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

- An actual boot from the USB stick (the installer reuses the stock kernel and its own device tree).
- The exact audio codec and amplifier (only the card name `mt8189_rt5650` is known) and a matching UCM profile.
- Display, GPU, audio, touchpad and suspend under Arch Linux ARM.
