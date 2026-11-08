# Arch Linux ARM on ASUS Chromebook CM1406

**Target:** ASUS Chromebook CM1406 — Google Tarkin / MediaTek MT8189  
**Boot method:** USB (ChromeOS Developer Mode)  
**Installation type:** External storage only

This project provides an experimental Arch Linux ARM installation for the ASUS CM1406 Chromebook. The system is installed on a USB drive and booted through ChromeOS's Depthcharge bootloader.

The internal eMMC is not repartitioned or formatted. ChromeOS remains installed.

> **Experimental software.** The installation process has been tested in a simulated environment, but a successful boot on the physical CM1406 has not yet been established. Hardware compatibility must not be assumed.

## Hardware and test status

The target device identifies itself as:

| Property | Value |
|---|---|
| Board | `google,tarkin` |
| Platform | Skywalker |
| SoC | MediaTek MT8189 |
| Architecture | AArch64 |
| Storage | eMMC |
| ChromeOS kernel | 6.6.x |
| Active kernel slot | KERN-B (`p4`) |

Machine identification and preflight results are documented in [`notes/tarkin-findings.md`](notes/tarkin-findings.md).

### Test coverage

| Component | Status |
|---|---|
| Device identification | Verified on physical hardware |
| Stock kernel extraction and repacking | Preflight checks passed |
| Kernel signing with `futility` | Preflight checks passed |
| Full installer execution | Simulated successfully |
| USB partitioning | Simulated |
| Root filesystem extraction | Simulated |
| SSH configuration | Simulated |
| Wi-Fi configuration | Simulated, with and without Python |
| File permissions | Audited and corrected |
| Actual USB boot | Not tested |
| Real ARM chroot | Not tested |
| MT7925 Wi-Fi | Not tested |
| Display and GPU | Not tested |
| Audio and touchpad | Not tested |

A successful simulated installation does not establish that the Chromebook will boot the resulting USB drive.

## Before installation

### Requirements

- ASUS CM1406 Chromebook.
- ChromeOS Developer Mode enabled.
- A separate USB drive. All existing data on it will be erased.
- A second device capable of connecting over SSH.
- An Ed25519 SSH key pair.
- Access to the Chromebook's VT2 shell.
- A working Wi-Fi network using WPA2-PSK.
- The project repository and installation dependencies.

### Important limitations

**Display**

The stock ChromeOS kernel does not provide the console environment expected by this installation. The initial boot may therefore produce a black screen. Remote access over SSH is required.

**Desktop environment**

The USB image initially provides a base Arch Linux ARM system with SSH. Omarchy and Hyprland are not guaranteed to be installed. The upstream Omarchy provisioning process is not executed during installation.

**Wi-Fi**

The initial configuration targets WPA2-PSK networks. WPA3-only, enterprise and hidden networks are not covered by the current setup. A WPA2 hotspot can be used for initial testing.

**Hardware configuration**

Some files under `port/quigon/` originate from the related Obiwan hardware variant. They are not all validated for Tarkin.

In particular:

- The audio configuration references RT5682S/RT1019P, whereas the target has been identified with an MT8189 RT5650 configuration.
- The palm-filter configuration expects an Elan touchpad, while the detected device is `04F3:31C6`.
- Other board-specific power, input and peripheral configurations may require changes.

Do not assume audio, touchpad, camera, GPU or power-management support.

## Installation

### 1. Prepare an SSH key

Generate an Ed25519 key pair on the second device:

```sh
ssh-keygen -t ed25519 -C "cm1406-arch"
```

Display the public key:

```sh
cat ~/.ssh/id_ed25519.pub
```

Only the public key is required by the installer. Keep the private key on the SSH client device.

### 2. Copy the public key to ChromeOS

Open the ChromeOS shell:

1. Press `Ctrl + Alt + T`.
2. Enter `shell`.
3. Switch to VT2 using `Ctrl + Alt + Refresh`.

Create the public-key file:

```sh
cat > /var/tmp/key.pub <<'EOF'
ssh-ed25519 AAAA... replace-with-your-public-key
EOF

chmod 600 /var/tmp/key.pub
```

Replace the example with the complete public key.

### 3. Extract the project

Extract the downloaded project archive:

```sh
cd /var/tmp
bsdtar -xf ~/MyFiles/Downloads/asus-cm14-tarkin-ready.zip
```

Enter the repository:

```sh
cd /var/tmp/asus-cm14-chromebook-omarchy
```

### 4. Run the preflight checks

The preflight script performs read-only checks before installation:

```sh
sudo bash scripts/preflight-tarkin.sh
```

Review the report:

```sh
cat /var/tmp/pf/report.txt
```

Do not proceed if the report contains `MANQUANT`, `ABSENT` or `ECHEC`. Resolve the reported problems first.

### 5. Download the Arch Linux ARM root filesystem

Download the AArch64 root filesystem:

```sh
cd /var/tmp

curl -fLO https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

curl -fLO https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
```

Verify the archive:

```sh
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5
```

The checksum must pass before installation.

### 6. Identify the USB drive

Connect the USB drive and list block devices:

```sh
lsblk -o NAME,SIZE,RM,TRAN,FSTYPE,MOUNTPOINT
```

Identify the USB device by its size and transport:

- `RM=1`
- `TRAN=usb`

For example, the device might be `/dev/sda`.

**The internal eMMC is `/dev/mmcblk0`. Never select it.**

Use the whole USB device, not one of its partitions.

### 7. Install Arch Linux ARM

Run the installer from VT2.

Replace `/dev/sdX` with the actual USB device and `NomWifi` with the WPA2 network name:

```sh
cd /var/tmp/asus-cm14-chromebook-omarchy

sudo env CONFIRM_ERASE=/dev/sdX \
  bash install/install-usb.sh \
  --alarm /var/tmp/ArchLinuxARM-aarch64-latest.tar.gz \
  --wifi-ssid "NomWifi" \
  --pubkey "$(cat /var/tmp/key.pub)" \
  /dev/sdX
```

The Wi-Fi password is requested interactively and is not supplied as a command-line argument.

The installer:

1. Checks the target device.
2. Verifies the Arch Linux ARM archive.
3. Prepares the ChromeOS-compatible kernel image.
4. Creates the USB partition table.
5. Formats the root partition as ext4.
6. Extracts Arch Linux ARM.
7. Installs system configuration and SSH access.
8. Configures networking and first-boot services.
9. Writes the signed kernel to the USB drive.

**Warning:** All data on the selected USB device will be destroyed. The installer requires an exact confirmation through `CONFIRM_ERASE`.

### 8. Boot from USB

Leave the USB drive connected.

1. Shut down the Chromebook.
2. Power it on.
3. At the `OS verification is OFF` screen, press `Ctrl + U`.
4. Wait for the system to initialize.

The screen may remain black. This is expected by the current installation design; it does not confirm that the system has booted successfully.

### 9. Connect over SSH

After allowing time for startup, locate the Chromebook's IP address through the router's connected-device list.

The configured hostname is:

```text
asus-cm14
```

Connect from the second device:

```sh
ssh -i ~/.ssh/id_ed25519 alarm@<IP_ADDRESS>
```

Replace `<IP_ADDRESS>` with the address assigned by the router.

If the device does not appear after 2–3 minutes, power it off using the side button. Remove the USB drive and restart ChromeOS.

## Recovery and rollback

The internal eMMC is not repartitioned or formatted by this USB installation method.

Without the USB drive, ChromeOS remains the normal boot environment. On the Developer Mode screen, `Ctrl + D` starts ChromeOS.

The installer also modifies ChromeOS boot configuration flags:

```sh
sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0
```

To restore the original flag values:

```sh
sudo crossystem dev_boot_usb=0 dev_boot_signed_only=1
```

The preflight working directory can be removed:

```sh
sudo rm -rf /var/tmp/pf
```

The disabled internal-storage scripts are retained in the repository with `.DISABLED` extensions:

- `install/flash-internal.sh.DISABLED`
- `install/restore-chromeos.sh.DISABLED`

They are not part of the USB installation procedure.

## Repository changes

The current Tarkin preparation includes the following changes:

| Path | Description |
|---|---|
| `install/install-usb.sh` | USB installer with active kernel-slot detection, stock-kernel repacking and SSH configuration |
| `scripts/preflight-tarkin.sh` | Read-only hardware and installation checks |
| `scripts/identify-device.sh` | Device and active-slot identification with sensitive identifiers removed |
| `scripts/build-usb.sh` | Alternative USB build path; currently depends on a LAN bridge |
| `port/quigon/root/` | Reused system configuration, with Tarkin compatibility limitations |
| `port/quigon/user/` | Hyprland user configuration |
| `notes/tarkin-findings.md` | Hardware identification and device-tree findings |
| `notes/README-obiwan-original.md` | Original Obiwan documentation |

The installer is the recommended entry point for this USB installation path. `scripts/build-usb.sh` is an alternative workflow and has additional dependencies.

## Mainline kernel and device-tree work

A dedicated Tarkin mainline device tree is not currently provided as `mt8189-tarkin.dts`.

A proper port would require transferring and adapting the relevant nodes from the ChromeOS 6.6 device tree to the mainline kernel. The required work and currently identified nodes are described in:

- [`notes/tarkin-findings.md`](notes/tarkin-findings.md)
- [`port/quigon/patches/`](port/quigon/patches/)

The existence of MT8189-related patches does not establish complete Tarkin hardware support.

## Security considerations

- Use a separate USB drive for installation.
- Never target `/dev/mmcblk0`.
- Do not publish raw hardware-identification output, partition UUIDs, serial numbers, MAC addresses or Wi-Fi credentials.
- Keep the SSH private key on the client device.
- The installer refuses non-removable and non-USB targets, internal eMMC devices and installations without explicit erase confirmation.
- Verify the root filesystem archive before writing the USB drive.

## Contributing and issue reports

Useful bug reports should include:

- Chromebook board and SoC.
- ChromeOS kernel version.
- Preflight report, with identifying information removed.
- USB device type and capacity.
- Whether the device displayed anything during boot.
- SSH connectivity results.
- Relevant system logs, once access is available.

Do not include private keys, Wi-Fi passwords, serial numbers, MAC addresses, HWIDs or partition UUIDs.

---

**Project status:** Experimental. USB installation logic has been exercised in a simulated environment. Physical boot and peripheral support on the ASUS CM1406 Tarkin remain unverified.
