Arch Linux ARM on the ASUS Chromebook CM1406 (Skywalker / Tarkin)

**Target:** ASUS Chromebook CM1406 - board `google,tarkin`, family Skywalker, SoC MediaTek MT8189, eMMC storage.
**Method:** boot from a USB stick through ChromeOS Developer Mode (Depthcharge, `Ctrl+U`).
**Internal storage:** never touched. ChromeOS stays installed.

The installer takes the **stock ChromeOS kernel of your own machine** (which already contains the right Tarkin
device tree), re-signs it with the developer keys, and boots an Arch Linux ARM userland from the stick. Nothing is
built from source and no other Chromebook variant is supported or referenced.

> **Experimental.** A boot on a physical CM1406 has not been confirmed yet. The same method booted a different
> MT8189 variant (Obiwan) on the first try, and the Tarkin-specific steps were checked on a real device up to the
> kernel repack (see [`notes/tarkin-findings.md`](notes/tarkin-findings.md)). Everything after that is untested.

## What you get

A base Arch Linux ARM system that boots on the stock kernel and is reachable **over SSH only**:

- Wi-Fi (MediaTek MT7925, WPA2-PSK) via `wpa_supplicant` + `systemd-networkd`, DHCP on `wlan0`
- SSH by public key only (users `alarm` and `root`), hostname `asus-cm1406`
- Persistent journal, no suspend (lid/idle ignored), reboot 10 s after a kernel panic
- A plain-text diagnostics report at `/var/log/tarkin-boot.log`, refreshed 90 s after boot and every 10 minutes

**Not included / untested:** screen output (the stock kernel has no console: the screen stays black), desktop
environment, GPU, audio (the card is `mt8189_rt5650`), touchpad tuning, Bluetooth, suspend, WPA3-only /
enterprise / hidden networks.

## Requirements

- ASUS CM1406 in **ChromeOS Developer Mode**.
- A USB stick, 8 GB or more. **Everything on it is erased.**
- A second device on the same network to SSH from, and an Ed25519 key pair.
- A WPA2-PSK Wi-Fi network (a phone hotspot is ideal for the first test).
- This repository on the Chromebook.

## Installation

### 1. Create an SSH key (on the second device)

```sh
ssh-keygen -t ed25519 -C "cm1406-arch"
cat ~/.ssh/id_ed25519.pub
```

Only the public key goes to the Chromebook.

### 2. Open a shell on the Chromebook

Press `Ctrl+Alt+T`, type `shell`. (Or use VT2 with `Ctrl+Alt+Refresh`.) All commands below run there.

Save your public key:

```sh
cat > /var/tmp/key.pub <<'KEY'
ssh-ed25519 AAAA... paste-your-whole-public-key-here
KEY
```

### 3. Unpack this repository

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/boot-arch-linux-on-CM1406-asus-main.zip
cd /var/tmp/boot-arch-linux-on-CM1406-asus-main
```

(Adjust the file name to what you downloaded.)

### 4. Preflight (read-only)

```sh
sudo bash scripts/preflight-tarkin.sh
```

The report is `/var/tmp/pf/report.txt`. It must say `board: OK (google,tarkin)` and `repack: OK`. Do not continue
if any line contains `MISSING`, `ABSENT` or `FAILED` - except `ABSENT` on an `mt7925/...` firmware line, which the
installer handles. Clean up afterwards with `sudo rm -rf /var/tmp/pf`.

### 5. Find the USB stick

Plug it in:

```sh
lsblk -o NAME,SIZE,RM,TRAN,MODEL
```

The stick has `RM=1` and `TRAN=usb` (for example `/dev/sda`). **The internal eMMC is `/dev/mmcblk0` - never use
it.** Use the whole device, not a partition.

### 6. Install

```sh
cd /var/tmp/boot-arch-linux-on-CM1406-asus-main
sudo env CONFIRM_ERASE=/dev/sdX \
  bash install/install-usb.sh \
  --pubkey "$(cat /var/tmp/key.pub)" \
  /dev/sdX
```

Replace `/dev/sdX` (twice) with your stick. By default the installer downloads the Arch Linux ARM root filesystem
over HTTPS, verifies its MD5 and uses the Wi-Fi network saved in ChromeOS. To choose the network yourself add
`--wifi-ssid "NetworkName"` (the passphrase is then prompted, never passed on the command line). Options:

| Option / variable | Purpose |
|---|---|
| `--alarm <file\|https-url>` | Use a tarball you already downloaded (its `.md5` file must sit beside it) |
| `--wifi-ssid <name>` | Wi-Fi network instead of the ChromeOS-saved one |
| `WIFI_COUNTRY=FR` | Set the Wi-Fi regulatory domain |
| `ALLOW_NO_WIFI=1` | Install without Wi-Fi (you then need another way in) |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check (not recommended) |

What the installer does, in order: checks the board and the target (removable USB only, never eMMC, never the
running ChromeOS disk) -> downloads and verifies the rootfs -> repacks and verifies the signed kernel -> sets
`dev_boot_usb=1 dev_boot_signed_only=0` -> partitions the stick (p1 kernel, p2 root) -> extracts the rootfs ->
copies the ChromeOS kernel modules and firmware -> configures SSH, Wi-Fi and services -> installs
`wpa_supplicant`, `iw` and `pciutils` in a chroot (`pacman -Syu`, needs the Chromebook to be online) -> writes the
kernel to p1.

### 7. Boot

1. Leave the stick plugged in, power the Chromebook off, then on.
2. At the "OS verification is OFF" screen press **`Ctrl+U`**.
3. **Expect a black screen.** Wait 1-3 minutes, find the new device (`asus-cm1406`) in your router, then:

```sh
ssh -i ~/.ssh/id_ed25519 alarm@<ip-address>
```

(`root@<ip-address>` works too, with the same key.)

## If it does not work

- Hold the power button to turn off, unplug the stick and press `Ctrl+D` at the developer screen: ChromeOS boots
  as before.
- Read what happened: boot ChromeOS, plug the stick in, mount its second partition
  (`sudo mkdir /mnt/s && sudo mount /dev/sdX2 /mnt/s`) and read `/mnt/s/var/log/tarkin-boot.log` (written only if
  the system got far enough to start). A kernel panic is also kept in `/sys/fs/pstore` on ChromeOS after the
  reboot.
- Wi-Fi is the most likely failure point (MT7925, untested on this board). Retry with a plain WPA2 hotspot.
- To undo the firmware flags: `sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.

## Repository layout

| Path | Purpose |
|---|---|
| `install/install-usb.sh` | The installer |
| `scripts/preflight-tarkin.sh` | Read-only checks before installing |
| `scripts/identify-device.sh` | Optional: collects a redacted hardware report (no HWID, serial number or MAC) |
| `rootfs/` | Files copied onto the stick: SSH policy, no-suspend, panic reboot, boot diagnostics |
| `notes/tarkin-findings.md` | What is verified on the device and what is not |

## Security

- Use a spare USB stick and never target `/dev/mmcblk0`.
- sshd accepts keys only; keep the private key on your client device.
- Do not publish HWIDs, serial numbers, MAC addresses, partition UUIDs or Wi-Fi credentials in bug reports.
- Developer Mode and `dev_boot_signed_only=0` weaken the Chromebook's boot verification; restore the flags (above)
  when you no longer need USB boot.

## Credits and license

Derived from the Omarchy/Arch Linux ARM Chromebook CM14 project by zoan37 and contributors, reduced here to the
Tarkin USB boot path. MIT license, see [`LICENSE`](LICENSE).
   
