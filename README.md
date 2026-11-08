Arch Linux ARM on the ASUS Chromebook CM1406 (Skywalker / Tarkin)

**Target:** ASUS Chromebook CM1406, board `google,tarkin`, family Skywalker, SoC MediaTek MT8189, eMMC storage.
**Method:** boot from a USB stick through ChromeOS Developer Mode (`Ctrl+U`).
**Internal storage:** never touched. ChromeOS stays installed; without the stick the machine boots ChromeOS.

The installer takes the **stock ChromeOS kernel of your own machine** (it already contains the Tarkin device tree),
re-signs it with the developer keys and boots an Arch Linux ARM userland from the stick. This is **not mainline
Linux**: the kernel stays the ChromeOS 6.6.x one.

> **Experimental.** A boot on a physical CM1406 is not confirmed yet. The same method booted another MT8189
> variant (Obiwan) on the first try; for Tarkin only identification and the kernel repack were verified on a real
> device (see [`notes/tarkin-findings.md`](notes/tarkin-findings.md)). Do not assume anything else works.

## What you get

A base Arch Linux ARM system reachable **over SSH only** (the stock kernel has no console: **the screen stays black**):

- Wi-Fi (MediaTek MT7925, WPA2-PSK) through `wpa_supplicant` + `systemd-networkd`, DHCP on `wlan0`
- SSH by public key only (users `alarm` and `root`), hostname `asus-cm1406`
- No suspend (lid and idle ignored), reboot 10 s after a kernel panic, persistent journal
- A diagnostics report written to `/var/log/tarkin-boot.log` on the stick (90 s after boot, then every 10 min)

Not included or untested: screen output, desktop, GPU, audio, Bluetooth, suspend, WPA3-only / enterprise / hidden Wi-Fi.

## Requirements

- CM1406 in **ChromeOS Developer Mode** (`OS verification is OFF` screen at every boot).
- A USB stick of **8 GB or more**, USB 3.0 from a known brand. **Everything on it is erased.**
- A second device on the same Wi-Fi to SSH from, and an Ed25519 key pair.
- A WPA2-PSK network (a phone hotspot is ideal for the first test). The Chromebook must have working internet.

## Why two terminals

On recent ChromeOS the terminal opened with `Ctrl+Alt+T` (crosh, then `shell`) **cannot use `sudo`** (the kernel flag
`no_new_privs`). The VT2 console can, but it has no copy/paste and a QWERTY keyboard. So:

| Where | Used for |
|---|---|
| **Browser + crosh tab** (`Ctrl+Alt+T`, then `shell`) | Downloads, unpacking, pasting your key. Never needs root. |
| **VT2** (`Ctrl+Alt+Refresh`, login `chronos`) | The few short commands that need `sudo`. Back to the desktop: `Ctrl+Alt+Back`. |

`/var/tmp` is shared by both, so what you prepare in the crosh tab is visible in VT2.

## Installation

### 1. SSH key (on your second device)

```sh
ssh-keygen -t ed25519 -C "cm1406-arch"
cat ~/.ssh/id_ed25519.pub
```

### 2. Download with the ChromeOS browser (it has the network)

Save these into *Downloads*:

- this repository as a zip (GitHub, **Code, Download ZIP**)
- <https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz> (about 0.5-1 GB)
- <https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5>

### 3. Prepare in the crosh tab (`Ctrl+Alt+T`, then `shell`)

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/boot-arch-linux-on-CM1406-asus-main.zip
cp ~/MyFiles/Downloads/ArchLinuxARM-aarch64-latest.tar.gz* /var/tmp/
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5        # must print: ...tar.gz: OK
cat > /var/tmp/key.pub <<'KEY'
ssh-ed25519 AAAA...paste-your-whole-public-key-here
KEY
```

(Rename the zip in the second line to what you downloaded; a name like `... (1).zip` or `-tarkin.zip` is fine too.)

### 4. Preflight, in VT2

Plug the USB stick in, press `Ctrl+Alt+Refresh`, log in as `chronos`, then:

```sh
cd /var/tmp/boot-arch-linux-on-CM1406-asus-main
sudo bash scripts/preflight-tarkin.sh
```

The report is `/var/tmp/pf/report.txt`. It must say `board: OK (google,tarkin)` and `repack: OK`. Stop if a line contains
`MISSING`, `ABSENT` or `FAILED` (an `ABSENT` on an `mt7925` firmware line is fine).

### 5. Install, in VT2

```sh
sudo bash install/go.sh
```

`go.sh` finds your key and the tarball, detects the USB stick, shows it and asks you to type its name to confirm.
Add `--wifi-ssid "NetworkName"` to pick the network yourself (the passphrase is then prompted); by default the
network saved in ChromeOS is used. The installer checks the package mirror **before** erasing anything, verifies the
kernel it wrote by reading it back, and prints `[+] USB written` at the end. Wait for it. Do not unplug the stick.

Manual form, if you prefer (replace `sdX`, never use `/dev/mmcblk0`, the internal disk):

```sh
sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh \
  --alarm /var/tmp/ArchLinuxARM-aarch64-latest.tar.gz --pubkey "$(cat /var/tmp/key.pub)" /dev/sdX
```

| Option / variable | Purpose |
|---|---|
| `--alarm <file\|https-url>` | Rootfs tarball (its `.md5` beside it) |
| `--wifi-ssid <name>` | Wi-Fi network instead of the ChromeOS-saved one |
| `WIFI_COUNTRY=FR` | Wi-Fi regulatory domain |
| `ALLOW_NO_PKGS=1` | Skip the network check and the Wi-Fi tools (stick then unreachable over SSH) |
| `ALLOW_NO_WIFI=1` | Install without any Wi-Fi configuration |
| `FORCE_BOARD=1` | Skip the `google,tarkin` check (not recommended) |

### 6. Boot

1. Leave the stick plugged in, power the Chromebook off, then on.
2. The `OS verification is OFF` screen may be very short: **tap `Ctrl+U` about once per second from power-on**.
3. **Expect a black screen.** Wait 1-3 minutes, find `asus-cm1406` in your router's device list, then:

```sh
ssh -i ~/.ssh/id_ed25519 alarm@<ip-address>
```

(`root@<ip-address>` works too.)

## Troubleshooting

First, always: boot ChromeOS (no stick, or `Ctrl+D`), plug the stick in and run, in VT2:

```sh
sudo bash scripts/check-usb.sh
```

It checks the firmware flags, the partition table, the kernel signature and the stick's contents, and prints the
crash log of the last failed boot. Send its whole output when asking for help.

| Symptom | Cause and fix |
|---|---|
| `sudo` fails in the `Ctrl+Alt+T` terminal | Expected (`no_new_privs`). Run `sudo` commands in VT2 only. |
| Cannot log in on VT2 | User is `chronos`. If it asks for a password you never set, tell me the exact message before trying anything else. |
| VT2 keyboard types wrong characters | VT2 is QWERTY. The commands above avoid special keys on purpose. |
| `go.sh`: no USB stick detected | Replug, wait 5 s, try another port (no hub, no adapter), try another stick. `dmesg \| tail` should show `sd 0:0:0:0: [sda]`. |
| `curl` hangs on the rootfs | Download it with the browser (step 2) and use `--alarm`. The installer itself now aborts on stalled downloads. |
| `Cannot reach mirror.archlinuxarm.org` | ChromeOS has no internet, or the network filters it. Connect to Wi-Fi in ChromeOS, or use a phone hotspot. |
| Warning: `wpa_supplicant could NOT be installed` | Same cause. Fix the network and run the installer again, otherwise the stick cannot be reached over SSH. |
| Firmware says "No valid image detected" | The firmware rejected the stick. Run `check-usb.sh`: it tells you if partition 1 is not a kernel partition, has priority 0, fails to verify, or if `dev_boot_usb` is 0. If the installer stopped before `[+] USB written`, run it again. |
| Reboots straight back to the `OS verification is OFF` screen | The kernel was started and died, or was rejected. After the reboot, boot ChromeOS and run `check-usb.sh`: its last section prints the previous boot's crash log (pstore). |
| Boots ChromeOS instead of the stick | `Ctrl+U` was not caught (tap it repeatedly), or `dev_boot_usb` is 0: `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`. |
| Black screen, nothing on the network after 3 min | Expected screen, but no Wi-Fi. Run `check-usb.sh` and read `tarkin-boot.log` if it exists. Retry with a plain WPA2 hotspot. |

To go back to normal: remove the stick and boot (`Ctrl+D`). To restore the firmware flags:
`sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1`.

## Repository layout

| Path | Purpose |
|---|---|
| `install/go.sh` | Guided launcher for VT2 (finds key, tarball and stick) |
| `install/install-usb.sh` | The installer |
| `scripts/preflight-tarkin.sh` | Read-only checks before installing |
| `scripts/check-usb.sh` | Diagnoses a stick and the last failed boot |
| `scripts/identify-device.sh` | Optional redacted hardware report (no HWID, serial or MAC) |
| `rootfs/` | Files copied onto the stick (SSH policy, no suspend, panic reboot, boot report) |
| `notes/tarkin-findings.md` | What is verified on the device and what is not |

## Security

- Use a spare stick; never target `/dev/mmcblk0`. The installer refuses non-USB, non-removable and the running disk.
- sshd accepts keys only; keep the private key on your client device.
- Developer Mode and `dev_boot_signed_only=0` weaken boot verification; restore the flags when you stop using USB boot.
- Use it only on a device you own or are allowed to modify (a school-managed Chromebook may forbid Developer Mode).
- Never publish HWIDs, serial numbers, MAC addresses, partition UUIDs, Wi-Fi credentials or GitHub tokens.

## Credits and license

<<<<<<< HEAD
Derived from the Omarchy/Arch Linux ARM Chromebook CM14 project by zoan37 and contributors, reduced here to the
Tarkin USB boot path. MIT license, see [`LICENSE`](LICENSE).
   
=======
Derived from the Omarchy/Arch Linux ARM Chromebook CM14 project by zoan37 and contributors, reduced to the Tarkin
USB boot path. MIT license, see [`LICENSE`](LICENSE).
>>>>>>> cb2af0b (v2: VT2 workflow, go.sh launcher, check-usb diagnostics, safer installer)
