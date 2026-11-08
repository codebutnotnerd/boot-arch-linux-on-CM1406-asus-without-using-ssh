#!/bin/bash
# install-usb.sh - Arch Linux ARM on a USB stick for the ASUS Chromebook CM1406 (Google Tarkin, MT8189).
#
# Run on the Chromebook itself, in ChromeOS Developer Mode (VT2 / crosh shell), as root.
# The stock ChromeOS kernel of the running slot is re-signed with the developer keys and written to the stick,
# so the board's own device tree is used. The internal eMMC is never written.
set -euo pipefail

DEV=""
ALARM_SOURCE="${ALARM_ARCHIVE:-https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
PUBKEY="${PUBKEY:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNT="/usr/local/tarkin_alarm_root"          # stateful partition: / and /tmp on ChromeOS are too small
WORK="/var/tmp"
ARCHIVE_TMP=""
KERNEL_TMP_DIR=""

# The kernel command line is the contract between this installer and the stock kernel:
#   console=            no console (the stock kernel has no VT/fbcon, the screen stays black)
#   root=...PARTNROFF=1 root is the partition right after the kernel partition (p1 -> p2)
#   net.ifnames=0       keep the interface name wlan0
#   lsm=...             drop LoadPin (pins module/firmware loading to the verity root), the chromiumos LSM and
#                       SELinux (no policy in Arch); keep landlock/yama/bpf
CMDLINE='console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1'

cleanup() {
  for d in tmp dev sys proc; do
    mountpoint -q "$MNT/$d" 2>/dev/null && umount "$MNT/$d" 2>/dev/null || true
  done
  if mountpoint -q "$MNT" 2>/dev/null; then
    umount "$MNT" || true
  fi
  rmdir "$MNT" 2>/dev/null || true
  [[ -z "$ARCHIVE_TMP" ]] || rm -rf "$ARCHIVE_TMP"
  [[ -z "$KERNEL_TMP_DIR" ]] || rm -rf "$KERNEL_TMP_DIR"
}
trap cleanup EXIT

die() { echo "[-] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alarm|-a)     ALARM_SOURCE="${2:?missing value for $1}"; shift 2 ;;
    --pubkey|-p)    PUBKEY="${2:?missing value for $1}"; shift 2 ;;
    --wifi-ssid|-s) WIFI_SSID="${2:?missing value for $1}"; shift 2 ;;
    --wifi-pass|-w) die "Do not pass Wi-Fi passwords on the command line; the installer prompts for it." ;;
    -h|--help)
      cat <<'USAGE'
Usage: sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh [options] /dev/sdX
Options:
  --alarm,   -a <file|https-url>  ArchLinuxARM-aarch64 tarball (a matching .md5 file must sit next to it)
  --wifi-ssid, -s <ssid>          Wi-Fi network (WPA2-PSK); the passphrase is prompted. Default: the network
                                  saved in ChromeOS, if any.
  --pubkey,  -p <ssh-public-key>  SSH public key for root and alarm (required: sshd is key-only)
Environment:
  CONFIRM_ERASE=/dev/sdX  required, must equal the target device
  ALLOW_NO_WIFI=1         allow an install without any Wi-Fi configuration
  WIFI_COUNTRY=FR         optional two-letter regulatory domain written to wpa_supplicant
  FORCE_BOARD=1           skip the "this is a google,tarkin board" check
USAGE
      exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *)  [[ -z "$DEV" ]] || die "Unknown argument: $1"; DEV="$1"; shift ;;
  esac
done

[[ -n "$DEV" ]]       || die "Usage: sudo $0 [options] /dev/sdX"
[[ "$EUID" -eq 0 ]]   || die "Run this script as root."
[[ -b "$DEV" ]]       || die "Target is not a block device: $DEV"
[[ -n "$PUBKEY" ]]    || die "--pubkey is required: sshd is key-only and the screen stays black, so without an SSH key the booted system cannot be reached."
case "$PUBKEY" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) die "--pubkey does not look like an SSH public key line." ;;
esac
[[ "$PUBKEY" != *$'\n'* ]] || die "--pubkey must be a single line."

echo "=== Target: ASUS Chromebook CM1406 (Google Tarkin, MT8189) ==="

# This installer only works from ChromeOS: it repacks the running stock kernel.
command -v rootdev >/dev/null 2>&1 || die "rootdev not found: run this on the Chromebook, in ChromeOS Developer Mode."

# Board check.
if [[ "${FORCE_BOARD:-0}" != 1 ]]; then
  compat="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
  [[ "$compat" == *google,tarkin* ]] \
    || die "This is not a google,tarkin board (compatible: ${compat:-unreadable}). Set FORCE_BOARD=1 to override."
fi

# Target safety: removable USB device, never the disk ChromeOS is running from, never eMMC.
name="$(basename "$DEV")"
[[ "$DEV" =~ mmcblk ]] && die "$DEV looks like internal eMMC. This installer only targets USB drives."
[[ -d "/sys/block/$name" ]] || die "$DEV is not a whole disk. Pass the device (e.g. /dev/sda), not a partition."
[[ "$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)" == 1 ]] \
  || die "$DEV is marked non-removable. Aborting to protect the internal drive."
[[ "$(readlink -f "/sys/class/block/$name")" == *"/usb"* ]] \
  || die "$DEV is not identified as a USB device by sysfs."
[[ "$(rootdev -s -d 2>/dev/null || true)" != "$DEV" ]] \
  || die "$DEV is the disk ChromeOS is running from."

for c in cgpt futility blockdev mkfs.ext4 bsdtar md5sum blkid dd findmnt mountpoint chroot crossystem curl; do
  command -v "$c" >/dev/null 2>&1 || die "Required command is missing: $c"
done
KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
[[ -f "$KB" && -f "$SK" ]] || die "ChromeOS developer signing keys are missing ($KB, $SK)."

# Stock kernel of the running slot: root on p3 -> kernel p2 (KERN-A), root on p5 -> kernel p4 (KERN-B).
running_disk="$(rootdev -s -d)"
running_root="$(rootdev -s)"
root_num="${running_root##*[!0-9]}"
[[ "$root_num" == 3 || "$root_num" == 5 ]] || die "Unexpected ChromeOS root partition: $running_root (expected p3 or p5)."
kern_num=$((root_num - 1))
if [[ "$running_disk" =~ [0-9]$ ]]; then part_kern="${running_disk}p${kern_num}"; else part_kern="${running_disk}${kern_num}"; fi
[[ -b "$part_kern" ]] || die "Active ChromeOS kernel partition not found: $part_kern"

KVER="$(uname -r)"
[[ -d "/lib/modules/$KVER" ]] || die "ChromeOS kernel modules not found in /lib/modules/$KVER."
[[ -d /lib/firmware ]]        || die "ChromeOS firmware directory /lib/firmware not found."

# Root filesystem archive (verified before anything is erased).
ARCHIVE="$ALARM_SOURCE"
if [[ "$ALARM_SOURCE" =~ ^https:// ]]; then
  ARCHIVE_TMP="$(mktemp -d "$WORK/alarm-dl.XXXXXX")"
  ARCHIVE="$ARCHIVE_TMP/ArchLinuxARM-aarch64-latest.tar.gz"
  curl --fail --location --show-error "$ALARM_SOURCE" -o "$ARCHIVE"
  curl --fail --location --show-error "${ALARM_SOURCE}.md5" -o "$ARCHIVE.md5"
elif [[ "$ALARM_SOURCE" =~ ^http:// ]]; then
  die "Rootfs download URLs must use HTTPS."
elif [[ ! -f "$ARCHIVE" ]]; then
  die "Arch Linux ARM archive not found: $ARCHIVE"
fi
[[ -f "$ARCHIVE.md5" ]] || die "Missing checksum file: $ARCHIVE.md5"
expected_md5="$(awk 'NR == 1 { print $1 }' "$ARCHIVE.md5" | tr '[:upper:]' '[:lower:]')"
[[ "$expected_md5" =~ ^[0-9a-f]{32}$ ]] || die "Invalid MD5 checksum format in $ARCHIVE.md5"
actual_md5="$(md5sum "$ARCHIVE" | awk '{ print $1 }')"
[[ "$actual_md5" == "$expected_md5" ]] || die "Rootfs checksum mismatch; refusing to erase the USB drive."

# Wi-Fi: use the network saved in ChromeOS unless one is given.
if [[ -z "$WIFI_SSID" && -f /var/cache/shill/default.profile ]]; then
  echo "== Reading the saved Wi-Fi network from ChromeOS..."
  prof=/var/cache/shill/default.profile
  WIFI_SSID="$(sed -n '/^\[wifi_/,/^\[/{s/^Name=//p}' "$prof" | head -1)"
  psk="$(sed -n '/^\[wifi_/,/^\[/{s/^WiFi.Passphrase=//p}' "$prof" | head -1)"
  case "$psk" in rot47:*) psk="$(printf '%s' "${psk#rot47:}" | tr '!-~' 'P-~!-O')";; esac
  WIFI_PASS="$psk"
fi
if [[ -n "$WIFI_SSID" && -z "$WIFI_PASS" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Wi-Fi passphrase for '$WIFI_SSID' (hidden): " WIFI_PASS
    echo ""
  fi
  [[ -n "$WIFI_PASS" ]] || die "No Wi-Fi passphrase provided; omit --wifi-ssid or rerun interactively."
fi
if [[ -z "$WIFI_SSID" && "${ALLOW_NO_WIFI:-0}" != 1 ]]; then
  die "No Wi-Fi network: pass --wifi-ssid <name> (or ALLOW_NO_WIFI=1 if you have another way in)."
fi
if [[ -n "$WIFI_SSID" ]]; then
  [[ "$WIFI_SSID" != *$'\n'* && "$WIFI_SSID" != *$'\r'* ]] || die "SSIDs containing line breaks are not supported."
  (( ${#WIFI_PASS} >= 8 && ${#WIFI_PASS} <= 63 )) || die "Only WPA2-PSK passphrases (8-63 characters) are supported."
  [[ -z "${WIFI_COUNTRY:-}" || "$WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be two capital letters, e.g. FR."
fi

echo "Target USB device : $DEV"
echo "Stock kernel      : $part_kern ($KVER)"
echo "WARNING: all data on $DEV will be erased."
if [[ "${CONFIRM_ERASE:-}" != "$DEV" ]]; then
  [[ -t 0 ]] || die "Non-interactive run refused. Set CONFIRM_ERASE='$DEV' to confirm."
  read -r -p "Type '$DEV' to continue: " confirmation
  [[ "$confirmation" == "$DEV" ]] || die "Confirmation did not match; aborting."
fi

# Build and verify the signed kernel BEFORE touching the stick.
echo "== Repacking the stock kernel with the developer keys..."
KERNEL_TMP_DIR="$(mktemp -d "$WORK/tarkin-kernel.XXXXXX")"
dd if="$part_kern" of="$KERNEL_TMP_DIR/stock.bin" bs=1M status=none
printf '%s\n' "$CMDLINE" > "$KERNEL_TMP_DIR/cmdline"
futility vbutil_kernel --repack "$KERNEL_TMP_DIR/kernel.bin" --oldblob "$KERNEL_TMP_DIR/stock.bin" \
  --keyblock "$KB" --signprivate "$SK" --config "$KERNEL_TMP_DIR/cmdline" --flags 0x1
futility vbutil_kernel --verify "$KERNEL_TMP_DIR/kernel.bin"
(( $(stat -c %s "$KERNEL_TMP_DIR/kernel.bin") <= 64 * 1024 * 1024 )) || die "Signed kernel exceeds the 64 MiB kernel partition."

echo "== Enabling developer-mode USB boot..."
crossystem dev_boot_usb=1 dev_boot_signed_only=0
[[ "$(crossystem dev_boot_usb)" == 1 && "$(crossystem dev_boot_signed_only)" == 0 ]] \
  || die "crossystem did not enable USB boot of developer-signed kernels."

echo "== Unmounting existing partitions on $DEV..."
for p in "$DEV"?*; do
  [[ -b "$p" ]] || continue
  findmnt -rn -S "$p" >/dev/null 2>&1 && umount "$p"
done

echo "== Partitioning $DEV (ChromeOS GPT: p1 kernel, p2 root)..."
total_sectors="$(blockdev --getsz "$DEV")"
(( total_sectors > 139264 + 2097152 )) || die "USB device is too small (need at least ~1 GiB for the root partition; 8 GiB+ recommended)."
cgpt create "$DEV"
cgpt boot -p "$DEV"
cgpt add -i 1 -t kernel -b 8192 -s 131072 -l KERN-A -S 1 -T 1 -P 15 "$DEV"
cgpt add -i 2 -t data -b 139264 -s $((total_sectors - 139264 - 2048)) -l ALARM "$DEV"
blockdev --rereadpt "$DEV" || { echo "[!] Partition table reread failed; waiting."; sleep 3; }
udevadm settle 2>/dev/null || sleep 2
cgpt show "$DEV"

part1="${DEV}1"; part2="${DEV}2"
[[ "$DEV" =~ [0-9]$ ]] && { part1="${DEV}p1"; part2="${DEV}p2"; }
[[ -b "$part1" && -b "$part2" ]] || die "Partition device nodes did not appear for $DEV."

echo "== Formatting $part2 as ext4 (label ALARM)..."
mkfs.ext4 -F -L ALARM "$part2"
mkdir -p "$MNT"
mount "$part2" "$MNT"

echo "== Extracting the Arch Linux ARM rootfs..."
bsdtar -xpf "$ARCHIVE" -C "$MNT"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$part2")"
[[ -n "$ROOT_PARTUUID" ]] || die "Could not read PARTUUID for $part2."
sync

echo "== Installing Tarkin configuration..."
printf 'PARTUUID=%s / ext4 defaults,noatime 0 1\n' "$ROOT_PARTUUID" > "$MNT/etc/fstab"
echo "asus-cm1406" > "$MNT/etc/hostname"
cp -R --no-preserve=ownership "$REPO_ROOT/rootfs/." "$MNT/"
chown -R 0:0 "$MNT/etc/ssh/sshd_config.d" "$MNT/etc/systemd/logind.conf.d" "$MNT/etc/sysctl.d" \
             "$MNT/etc/systemd/system/tarkin-bootlog.service" "$MNT/etc/systemd/system/tarkin-bootlog.timer" \
             "$MNT/usr/local/libexec/tarkin"
chmod 644 "$MNT"/etc/ssh/sshd_config.d/10-tarkin-keys-only.conf "$MNT"/etc/systemd/logind.conf.d/10-tarkin-no-suspend.conf \
          "$MNT"/etc/sysctl.d/90-tarkin-panic.conf "$MNT"/etc/systemd/system/tarkin-bootlog.service \
          "$MNT"/etc/systemd/system/tarkin-bootlog.timer
chmod 755 "$MNT/usr/local/libexec/tarkin" "$MNT/usr/local/libexec/tarkin/bootlog"

# Persistent journal.
mkdir -p "$MNT/var/log/journal"

# Kernel modules and firmware come from ChromeOS: they match the stock kernel that will boot.
echo "== Copying ChromeOS kernel modules ($KVER) and firmware..."
mkdir -p "$MNT/usr/lib/modules" "$MNT/usr/lib/firmware/updates"
cp -a "/lib/modules/$KVER" "$MNT/usr/lib/modules/"
cp -a /lib/firmware/. "$MNT/usr/lib/firmware/updates/"

# MT7925 (PCIe 14c3:7925) Wi-Fi/Bluetooth firmware: present in ChromeOS normally; fetch what is missing.
FW_DIR="$MNT/usr/lib/firmware/updates/mediatek/mt7925"
mkdir -p "$FW_DIR"
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
for blob in WIFI_MT7925_PATCH_MCU_1_1_hdr.bin WIFI_RAM_CODE_MT7925_1_1.bin BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  if [[ ! -s "$FW_DIR/$blob" ]]; then
    echo "   [!] $blob missing from ChromeOS, downloading..."
    curl --fail --location --show-error --max-time 60 "$FW_URL/$blob" -o "$FW_DIR/$blob" \
      || { rm -f "$FW_DIR/$blob"; echo "   [!] $blob unavailable: Wi-Fi may not come up." >&2; }
  fi
done

# SSH keys for root and alarm (the ALARM tarball already has the alarm user, uid 1000).
install -d -m 700 "$MNT/root/.ssh" "$MNT/home/alarm/.ssh"
printf '%s\n' "$PUBKEY" > "$MNT/root/.ssh/authorized_keys"
printf '%s\n' "$PUBKEY" > "$MNT/home/alarm/.ssh/authorized_keys"
chmod 600 "$MNT/root/.ssh/authorized_keys" "$MNT/home/alarm/.ssh/authorized_keys"
chown -R 1000:1000 "$MNT/home/alarm/.ssh"

# Networking: systemd-networkd + wpa_supplicant.
mkdir -p "$MNT/etc/systemd/network"
cat > "$MNT/etc/systemd/network/wlan.network" <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF

WPA_CONF="$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
if [[ -n "$WIFI_SSID" ]]; then
  echo "== Configuring Wi-Fi for '$WIFI_SSID'..."
  SSID_ESC="${WIFI_SSID//\\/\\\\}"; SSID_ESC="${SSID_ESC//\"/\\\"}"
  PASS_ESC="${WIFI_PASS//\\/\\\\}"; PASS_ESC="${PASS_ESC//\"/\\\"}"
  mkdir -p "$MNT/etc/wpa_supplicant"
  {
    echo "ctrl_interface=/run/wpa_supplicant"
    echo "update_config=1"
    [[ -z "${WIFI_COUNTRY:-}" ]] || echo "country=$WIFI_COUNTRY"
    echo "network={"
    echo "  ssid=\"$SSID_ESC\""
    echo "  psk=\"$PASS_ESC\""
    echo "  key_mgmt=WPA-PSK"
    echo "}"
  } > "$WPA_CONF"
  chmod 600 "$WPA_CONF"
fi

# The Arch Linux ARM tarball has no Wi-Fi tools: install them in a chroot (same architecture, runs natively).
echo "== Installing wpa_supplicant, iw and pciutils in the new rootfs (chroot, needs network)..."
mount --bind /proc "$MNT/proc"; mount --bind /sys "$MNT/sys"; mount --bind /dev "$MNT/dev"
mount -t tmpfs tmpfs "$MNT/tmp"
resolv_saved=0
if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
  mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.orig"; resolv_saved=1
fi
cp /etc/resolv.conf "$MNT/etc/resolv.conf" || true
chroot "$MNT" /bin/bash -c 'pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1 && pacman -Syu --noconfirm --needed wpa_supplicant iw pciutils' \
  || echo "[!] Package install failed (no network from ChromeOS?). Wi-Fi will need manual setup." >&2

# Replace the cleartext passphrase by a hashed PSK (ChromeOS has no python3, wpa_passphrase comes from the chroot).
if [[ -n "$WIFI_SSID" && -x "$MNT/usr/bin/wpa_passphrase" ]]; then
  hashed="$(printf '%s\n' "$WIFI_PASS" | chroot "$MNT" /usr/bin/wpa_passphrase "$WIFI_SSID" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')" || hashed=""
  if [[ "$hashed" =~ ^[0-9a-f]{64}$ ]]; then
    sed -i "s/^  psk=.*/  psk=$hashed/" "$WPA_CONF"
    echo "   Passphrase stored as a hashed PSK."
  else
    echo "   [!] Could not hash the passphrase; it stays in the root-only (0600) config file."
  fi
fi

chroot "$MNT" gpgconf --kill all 2>/dev/null || true
for p in /proc/[0-9]*; do
  [[ "$(readlink "$p/root" 2>/dev/null)" == "$MNT" ]] && kill "${p#/proc/}" 2>/dev/null || true
done
sleep 1
rm -f "$MNT/etc/resolv.conf"
[[ "$resolv_saved" == 1 ]] && rm -f "$MNT/etc/resolv.conf.orig" || true
ln -sfn /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
for d in tmp dev sys proc; do
  mountpoint -q "$MNT/$d" && umount "$MNT/$d" || true
done

# Enable services offline.
WANTS="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS" "$MNT/etc/systemd/system/timers.target.wants"
enable_unit() {   # enable_unit <unit-file-in-rootfs> <wants-dir> [link-name]
  local unit="$1" dir="$2" link="${3:-$(basename "$1")}"
  if [[ -f "$MNT$unit" ]]; then ln -sfn "$unit" "$dir/$link"; else echo "[!] Unit unavailable in the rootfs: $unit" >&2; fi
}
enable_unit /usr/lib/systemd/system/systemd-networkd.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-resolved.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-timesyncd.service "$WANTS"
enable_unit /usr/lib/systemd/system/sshd.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-bootlog.timer "$MNT/etc/systemd/system/timers.target.wants"
if [[ -n "$WIFI_SSID" ]]; then
  enable_unit /usr/lib/systemd/system/wpa_supplicant@.service "$WANTS" wpa_supplicant@wlan0.service
fi

echo "== Writing the signed kernel to $part1..."
dd if="$KERNEL_TMP_DIR/kernel.bin" of="$part1" bs=1M conv=fsync status=progress
sync

cat <<EOF
==========================================================
[+] USB written: $DEV

Boot it:
 1. Leave the stick plugged in and power the Chromebook off, then on.
 2. At the 'OS verification is OFF' screen press Ctrl+U.
 3. EXPECT A BLACK SCREEN (stock kernel, no console). Wait 1-3 minutes, find the IP address
    in your router and connect:   ssh -i <private-key> alarm@<ip>   (or root@<ip>)

If it never appears on the network: power off, unplug the stick, press Ctrl+D to boot ChromeOS.
To read what happened, mount the stick's partition 2 in ChromeOS and look at /var/log/tarkin-boot.log.
==========================================================
EOF
