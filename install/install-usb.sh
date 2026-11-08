#!/bin/bash
set -euo pipefail

DEV=""
KERNEL_SRC="${KERNEL_FIT:-}"
ALARM_SOURCE="${ALARM_ARCHIVE:-https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
PUBKEY="${PUBKEY:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNT="/usr/local/asus_cm14_alarm_root"
ARCHIVE_TMP=""
TMP_KERN=""
KERNEL_TMP_DIR=""
KERNEL_SOURCE_TMP=""
KERNEL_CONFIG_TMP=""
cleanup() {
  for d in tmp dev sys proc; do
    mountpoint -q "$MNT/$d" 2>/dev/null && umount "$MNT/$d" 2>/dev/null || true
  done
  if mountpoint -q "$MNT"; then
    umount "$MNT"
  fi
  rmdir "$MNT" 2>/dev/null || true
  if [[ -n "$ARCHIVE_TMP" ]]; then
    rm -rf "$ARCHIVE_TMP"
  fi
  [[ -z "$KERNEL_TMP_DIR" ]] || rm -rf "$KERNEL_TMP_DIR"
  [[ -z "$KERNEL_SOURCE_TMP" ]] || rm -f "$KERNEL_SOURCE_TMP"
  [[ -z "$KERNEL_CONFIG_TMP" ]] || rm -f "$KERNEL_CONFIG_TMP"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel|-k)
      KERNEL_SRC="$2"
      shift 2
      ;;
    --alarm|-a)
      ALARM_SOURCE="$2"
      shift 2
      ;;
    --pubkey|-p)
      PUBKEY="$2"
      shift 2
      ;;
    --wifi-ssid|-s)
      WIFI_SSID="$2"
      shift 2
      ;;
    --wifi-pass|-w)
      echo "[-] Do not pass Wi-Fi passwords on the command line; the installer prompts securely." >&2
      exit 2
      ;;
    -h|--help)
      echo "Usage: sudo $0 [options] /dev/sdX"
      echo "Options:"
      echo "  --kernel, -k <path>     Path to kernel.fit image"
      echo "  --alarm, -a <archive>   Path or URL to ArchLinuxARM aarch64 tarball"
      echo "  --wifi-ssid, -s <ssid>  Wi-Fi SSID for auto-connect at boot"
      echo "  --wifi-pass is prompted securely when --wifi-ssid is supplied without a saved ChromeOS profile"
      echo "  --pubkey, -p <key>      SSH public key for root & alarm"
      exit 0
      ;;
    *)
      if [[ "$1" == -* ]]; then
        echo "Unknown option: $1" >&2
        exit 2
      fi
      if [[ -z "$DEV" ]]; then
        DEV="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$DEV" ]]; then
  echo "Usage: sudo $0 [--kernel <kernel.fit>] /dev/sdX"
  echo "Example: sudo $0 --kernel artifacts/kernel.fit /dev/sdb"
  exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
  echo "[-] Error: run this script as root." >&2
  exit 1
fi
if [[ ! -b "$DEV" ]]; then
  echo "[-] Error: target is not a block device: $DEV" >&2
  exit 1
fi
if [[ -z "$PUBKEY" ]]; then
  echo "[-] --pubkey is required: sshd is key-only (port/quigon/root/etc/ssh/sshd_config.d) and the stock ChromeOS" >&2
  echo "    kernel has no console, so without an SSH key the booted system cannot be reached." >&2
  exit 1
fi
case "$PUBKEY" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) echo "[-] --pubkey does not look like an SSH public key line." >&2; exit 1 ;;
esac

echo "=== Target: ASUS Chromebook CM14 (CM1406CM4A) ==="
echo "Target USB device: $DEV"

name=$(basename "$DEV")
if [[ -f "/sys/block/$name/removable" && "$(cat "/sys/block/$name/removable")" != "1" ]]; then
  echo "[-] Error: $DEV is marked non-removable. Aborting to protect internal drive!" >&2
  exit 1
fi
sys_block_path="$(readlink -f "/sys/class/block/$name")"
if [[ "$sys_block_path" != *"/usb"* ]]; then
  echo "[-] Error: $DEV is not identified as a USB device by sysfs." >&2
  exit 1
fi

if command -v rootdev >/dev/null 2>&1; then
  if [[ "$(rootdev -s -d 2>/dev/null || true)" == "$DEV" ]]; then
    echo "[-] Error: $DEV is the currently running ChromeOS root device! Aborting!" >&2
    exit 1
  fi
fi

if [[ "$DEV" =~ mmcblk ]]; then
  echo "[-] Error: $DEV appears to be internal eMMC. install-usb.sh only targets USB drives!" >&2
  exit 1
fi

KERNEL_FIT_PATH=""
SIGNED_KERNEL_PATH=""

if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]]; then
  KERNEL_FIT_PATH="$KERNEL_SRC"
elif [[ -f "$REPO_ROOT/artifacts/kernel.fit" ]]; then
  KERNEL_FIT_PATH="$REPO_ROOT/artifacts/kernel.fit"
elif [[ -f "$REPO_ROOT/artifacts/kern-usb-signed.bin" ]]; then
  SIGNED_KERNEL_PATH="$REPO_ROOT/artifacts/kern-usb-signed.bin"
fi
if [[ -n "$SIGNED_KERNEL_PATH" ]] && (( $(stat -c %s "$SIGNED_KERNEL_PATH") > 64 * 1024 * 1024 )); then
  echo "[-] Signed kernel exceeds the 64 MiB ChromeOS kernel partition." >&2
  exit 1
fi

IS_CHROMEOS=0
if command -v rootdev >/dev/null 2>&1; then
  IS_CHROMEOS=1
fi

if [[ -z "$KERNEL_FIT_PATH" && -z "$SIGNED_KERNEL_PATH" && "$IS_CHROMEOS" -eq 0 ]]; then
  echo "======================================================================" >&2
  echo "[-] ERROR: No kernel binary found for Depthcharge boot!" >&2
  echo "" >&2
  echo "    The USB drive requires a Depthcharge-signed kernel on Partition 1 (KERN-A)." >&2
  echo "    Neither 'artifacts/kernel.fit' nor an existing ChromeOS kernel was found." >&2
  echo "" >&2
  echo "    How to fix:" >&2
  echo "    1. Build the kernel FIT image on your Linux workstation:" >&2
  echo "           ./scripts/build-kernel-fit.sh <path_to_Image> [path_to_dtb]" >&2
  echo "       (or full build from source: ./scripts/build-mt8186-kernel.sh)" >&2
  echo "    2. Pass the kernel binary directly:" >&2
  echo "           sudo $0 --kernel /path/to/kernel.fit $DEV" >&2
  echo "    3. Or execute this script directly on the Chromebook in ChromeOS Developer Mode" >&2
  echo "       to automatically repack the running stock kernel." >&2
  echo "======================================================================" >&2
  exit 1
fi

for required_command in cgpt blockdev mkfs.ext4 bsdtar md5sum blkid dd findmnt; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "[-] Required command is missing: $required_command" >&2
    exit 1
  fi
done
ARCHIVE="$ALARM_SOURCE"
if [[ "$ALARM_SOURCE" =~ ^https:// ]]; then
  ARCHIVE_TMP="$(mktemp -d)"
  ARCHIVE="$ARCHIVE_TMP/ArchLinuxARM-aarch64-latest.tar.gz"
  curl --fail --location --show-error "$ALARM_SOURCE" -o "$ARCHIVE"
  curl --fail --location --show-error "${ALARM_SOURCE}.md5" -o "$ARCHIVE.md5"
elif [[ "$ALARM_SOURCE" =~ ^http:// ]]; then
  echo "[-] Rootfs download URLs must use HTTPS." >&2
  exit 1
elif [[ ! -f "$ARCHIVE" ]]; then
  echo "[-] Arch Linux ARM archive not found: $ARCHIVE" >&2
  exit 1
fi
if [[ ! -f "$ARCHIVE.md5" ]]; then
  echo "[-] Missing checksum file: $ARCHIVE.md5" >&2
  exit 1
fi
expected_md5="$(awk 'NR == 1 { print $1 }' "$ARCHIVE.md5" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$expected_md5" =~ ^[0-9a-f]{32}$ ]]; then
  echo "[-] Invalid MD5 checksum format in $ARCHIVE.md5" >&2
  exit 1
fi
actual_md5="$(md5sum "$ARCHIVE" | awk '{ print $1 }' | tr '[:upper:]' '[:lower:]')"
if [[ "$actual_md5" != "$expected_md5" ]]; then
  echo "[-] Rootfs checksum mismatch; refusing to erase the USB drive." >&2
  exit 1
fi
if [[ -z "$WIFI_SSID" && "$IS_CHROMEOS" -eq 1 && -f /var/cache/shill/default.profile ]]; then
  echo "== Detecting saved Wi-Fi settings from ChromeOS..."
  prof=/var/cache/shill/default.profile
  ssid=$(sed -n '/^\[wifi_/,/^\[/{s/^Name=//p}' "$prof" | head -1)
  if [[ -z "$ssid" ]]; then
    ssid=$(sed -n 's/^\[wifi_any_\([0-9a-f]*\)_.*/\1/p' "$prof" | head -1 | sed "s/../\\\\x&/g" | xargs -0 printf "%b" 2>/dev/null || true)
  fi
  psk=$(sed -n '/^\[wifi_/,/^\[/{s/^WiFi.Passphrase=//p}' "$prof" | head -1)
  case "$psk" in rot47:*) psk=$(printf '%s' "${psk#rot47:}" | tr '!-~' 'P-~!-O');; esac
  WIFI_SSID="$ssid"
  WIFI_PASS="$psk"
fi
if [[ -n "$WIFI_SSID" && -z "$WIFI_PASS" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Enter Wi-Fi passphrase for '$WIFI_SSID' (hidden): " WIFI_PASS
    echo ""
  fi
  if [[ -z "$WIFI_PASS" ]]; then
    echo "[-] Wi-Fi passphrase was not provided; omit --wifi-ssid or rerun interactively." >&2
    exit 1
  fi
fi

if [[ -z "$WIFI_SSID" && "${ALLOW_NO_WIFI:-0}" != 1 ]]; then
  echo "[-] No Wi-Fi network found: pass --wifi-ssid <name> (or ALLOW_NO_WIFI=1 if you have another way in)." >&2
  exit 1
fi

echo "WARNING: all data on $DEV will be erased."
if [[ "${CONFIRM_ERASE:-}" != "$DEV" ]]; then
  if [[ ! -t 0 ]]; then
    echo "[-] Non-interactive run refused. Set CONFIRM_ERASE='$DEV' to confirm." >&2
    exit 1
  fi
  read -r -p "Type '$DEV' to continue: " confirmation
  [[ "$confirmation" == "$DEV" ]] || { echo "[-] Confirmation did not match; aborting." >&2; exit 1; }
fi

if command -v crossystem >/dev/null 2>&1; then
  echo "== Enabling ChromeOS Developer Mode USB boot & relaxing devkeys enforcement..."
  crossystem dev_boot_usb=1 dev_boot_signed_only=0
  [[ "$(crossystem dev_boot_usb)" == 1 ]] || { echo "[-] crossystem did not enable USB boot." >&2; exit 1; }
  [[ "$(crossystem dev_boot_signed_only)" == 0 ]] || { echo "[-] crossystem did not allow developer-signed kernels." >&2; exit 1; }
else
  echo "[!] crossystem is unavailable; enable USB boot flags on the Chromebook before booting this key."
fi

KERNEL_TMP_DIR="$(mktemp -d /tmp/asus-cm14-kernel.XXXXXX)"
TMP_KERN="$KERNEL_TMP_DIR/kernel.bin"
if [[ -n "$SIGNED_KERNEL_PATH" ]]; then
  cp "$SIGNED_KERNEL_PATH" "$TMP_KERN"
elif [[ -n "$KERNEL_FIT_PATH" ]]; then
  bash "$REPO_ROOT/install/sign-kernel.sh" \
    --vmlinuz "$KERNEL_FIT_PATH" --out "$TMP_KERN" --target usb
elif [[ "$IS_CHROMEOS" -eq 1 ]]; then
  command -v futility >/dev/null 2>&1 || { echo "[-] futility is required to repack the ChromeOS kernel." >&2; exit 1; }
  [[ -f /usr/share/vboot/devkeys/kernel.keyblock && -f /usr/share/vboot/devkeys/kernel_data_key.vbprivk ]] || {
    echo "[-] ChromeOS developer signing keys are missing." >&2
    exit 1
  }
  running_disk="$(rootdev -s -d)"
  running_root="$(rootdev -s)"
  root_num="${running_root##*[!0-9]}"
  [[ "$root_num" == 3 || "$root_num" == 5 ]] || {
    echo "[-] Unexpected ChromeOS root partition: $running_root (expected p3 or p5)." >&2
    exit 1
  }
  kern_num=$((root_num - 1))
  if [[ "$running_disk" =~ [0-9]$ ]]; then
    part_kern="${running_disk}p${kern_num}"
  else
    part_kern="${running_disk}${kern_num}"
  fi
  echo "== Running root $running_root -> stock kernel partition $part_kern"
  [[ -b "$part_kern" ]] || { echo "[-] Active ChromeOS kernel partition not found." >&2; exit 1; }
  KERNEL_SOURCE_TMP="$(mktemp /tmp/asus-cm14-stock-kernel-XXXXXX)"
  KERNEL_CONFIG_TMP="$(mktemp /tmp/asus-cm14-cmdline-XXXXXX)"
  dd if="$part_kern" of="$KERNEL_SOURCE_TMP" bs=1M status=none
  printf '%s\n' "console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1" > "$KERNEL_CONFIG_TMP"
  futility vbutil_kernel --repack "$TMP_KERN" --oldblob "$KERNEL_SOURCE_TMP" \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --config "$KERNEL_CONFIG_TMP" --flags 0x1
else
  echo "[-] No kernel source available for signing." >&2
  exit 1
fi

if (( $(stat -c %s "$TMP_KERN") > 64 * 1024 * 1024 )); then
  echo "[-] Signed kernel exceeds the 64 MiB ChromeOS kernel partition." >&2
  exit 1
fi
if command -v futility >/dev/null 2>&1; then
  futility vbutil_kernel --verify "$TMP_KERN"
elif command -v vbutil_kernel >/dev/null 2>&1; then
  vbutil_kernel --verify "$TMP_KERN"
else
  echo "[-] vbutil_kernel or futility is required to verify the signed kernel." >&2
  exit 1
fi

echo "== Unmounting existing partitions on $DEV..."
for p in "$DEV"[0-9]*; do
  [[ -b "$p" ]] || continue
  if findmnt -rn -S "$p" >/dev/null 2>&1; then
    umount "$p"
  fi
done

echo "== Partitioning $DEV with ChromeOS GPT layout..."
total_sectors=$(blockdev --getsz "$DEV")
if (( total_sectors <= 139264 + 2048 )); then
  echo "[-] USB device is too small for the required partitions." >&2
  exit 1
fi

cgpt create "$DEV"
cgpt boot -p "$DEV"

cgpt add -i 1 -t kernel -b 8192 -s 131072 -l KERN-A -S 1 -T 1 -P 15 "$DEV"

cgpt add -i 2 -t data -b 139264 -s $((total_sectors - 139264 - 2048)) -l OMARCHY_ROOT "$DEV"

if ! blockdev --rereadpt "$DEV"; then
  echo "[!] Kernel partition table reread failed; waiting before checking the new partitions."
  sleep 2
fi
cgpt show "$DEV"

part1="${DEV}1"
part2="${DEV}2"
[[ "$DEV" =~ [0-9]$ ]] && part1="${DEV}p1" && part2="${DEV}p2"

echo "== Formatting $part2 as ext4 (label: OMARCHY_ROOT)..."
mkfs.ext4 -F -L OMARCHY_ROOT "$part2"

mkdir -p "$MNT"
mount "$part2" "$MNT"

echo "== Extracting verified Arch Linux ARM aarch64 rootfs..."
bsdtar -xpf "$ARCHIVE" -C "$MNT"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$part2")"
if [[ -z "$ROOT_PARTUUID" ]]; then
  echo "[-] Could not read PARTUUID for $part2." >&2
  exit 1
fi
sync

echo "== Installing ASUS CM14 hardware files and configurations..."
if [[ -d "$REPO_ROOT/port/quigon/root" ]]; then
  cp -a "$REPO_ROOT/port/quigon/root/." "$MNT/"
  find "$MNT/etc" "$MNT/usr" -perm /022 ! -type l -exec chmod go-w {} +
fi
cat > "$MNT/etc/fstab" <<FSTAB
PARTUUID=$ROOT_PARTUUID / ext4 defaults,noatime 0 1
FSTAB
for executable_dir in \
  usr/local/bin usr/local/sbin usr/local/libexec/quigon \
  usr/lib/systemd/system-sleep usr/lib/systemd/system-generators \
  usr/lib/NetworkManager/dispatcher.d; do
  [[ -d "$MNT/$executable_dir" ]] && find "$MNT/$executable_dir" -type f -exec chmod 755 {} +
done

echo "asus-cm14" > "$MNT/etc/hostname"

mkdir -p "$MNT/etc/sudoers.d"
echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
chmod 440 "$MNT/etc/sudoers.d/10-wheel"

TARGET_SOC="${SOC:-mt8186}"
MODULES_ROOT="$REPO_ROOT/artifacts/modules-$TARGET_SOC/lib/modules"
if [[ -d "$MODULES_ROOT" ]]; then
  mkdir -p "$MNT/usr/lib/modules"
  cp -a "$MODULES_ROOT/." "$MNT/usr/lib/modules/"
else
  echo "[!] No built module tree found at $MODULES_ROOT; verify the kernel modules are available before boot."
fi

cat > "$MNT/etc/systemd/network/wlan.network" <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF

if [[ -n "$WIFI_SSID" && -n "$WIFI_PASS" ]]; then
  echo "== Configuring Wi-Fi network for '$WIFI_SSID' (using hashed PSK, no cleartext password)..."
  if [[ "$WIFI_SSID" == *$'\n'* || "$WIFI_SSID" == *$'\r'* ]]; then
    echo "[-] SSIDs containing line breaks are not supported by this installer." >&2
    exit 1
  fi
  SSID_ESCAPED="${WIFI_SSID//\\/\\\\}"
  SSID_ESCAPED="${SSID_ESCAPED//\"/\\\"}"
  mkdir -p "$MNT/etc/wpa_supplicant"
  chmod 755 "$MNT/etc/wpa_supplicant"

  if command -v python3 >/dev/null 2>&1; then
    WPA_HASH="$(printf '%s\0%s\0' "$WIFI_PASS" "$WIFI_SSID" | python3 -c \
      'import hashlib, sys; password, ssid = sys.stdin.buffer.read().split(b"\0")[:2]; print(hashlib.pbkdf2_hmac("sha1", password, ssid, 4096, 32).hex())')"
    if [[ ! "$WPA_HASH" =~ ^[0-9a-f]{64}$ ]]; then
      echo "[-] Failed to derive a valid Wi-Fi PSK." >&2
      exit 1
    fi
    PSK_LINE="psk=$WPA_HASH"
    NM_PSK="$WPA_HASH"
  else
    echo "[!] python3 not found: the Wi-Fi passphrase is stored in cleartext in a root-only (0600) file on the USB key."
    PSK_LINE="psk=\"$WIFI_PASS\""
    NM_PSK=""
  fi

  cat > "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" <<WPA
ctrl_interface=/run/wpa_supplicant
update_config=1
network={
  ssid="$SSID_ESCAPED"
  $PSK_LINE
}
WPA
  chmod 600 "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

  if [[ -n "$NM_PSK" ]]; then
  mkdir -p "$MNT/etc/NetworkManager/system-connections"
  cat > "$MNT/etc/NetworkManager/system-connections/DefaultWiFi.nmconnection" <<NMC
[connection]
id=DefaultWiFi
uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a1b2c3d4-e5f6-7890-abcd-ef0123456789")
type=wifi
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=$SSID_ESCAPED

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$NM_PSK

[ipv4]
method=auto

[ipv6]
method=auto
NMC
  chmod 600 "$MNT/etc/NetworkManager/system-connections/DefaultWiFi.nmconnection"
  fi
fi

KVER=$(uname -r 2>/dev/null || echo "")
if [[ -n "$KVER" && -d "/lib/modules/$KVER" ]]; then
  echo "== Copying ChromeOS kernel modules ($KVER) and firmware..."
  mkdir -p "$MNT/usr/lib/modules"
  cp -a "/lib/modules/$KVER" "$MNT/usr/lib/modules/"
fi
if [[ -d "/lib/firmware" ]]; then
  mkdir -p "$MNT/usr/lib/firmware/updates"
  cp -a /lib/firmware/. "$MNT/usr/lib/firmware/updates/"
fi

echo "== Verifying MediaTek Wi-Fi (MT7921 / MT7925) & Bluetooth firmwares..."
FW_TARGET="$MNT/usr/lib/firmware/mediatek"
mkdir -p "$FW_TARGET"
if [[ -e "$MNT/lib" && ! -L "$MNT/lib" ]]; then
  mkdir -p "$MNT/lib/firmware/mediatek"
fi

for fw_src in /lib/firmware/mediatek /usr/lib/firmware/mediatek; do
  if [[ -d "$fw_src" ]]; then
    echo "   Copying firmwares from $fw_src..."
    cp -an "$fw_src/." "$FW_TARGET/"
  fi
done

MTK_BLOBS=(
  "WIFI_MT7961_patch_mcu_1_2_hdr.bin"
  "WIFI_RAM_CODE_MT7961_1.bin"
  "WIFI_MT7922_patch_mcu_1_1_hdr.bin"
  "WIFI_RAM_CODE_MT7922_1.bin"
  "WIFI_MT7925_patch_mcu_1_1_hdr.bin"
  "WIFI_RAM_CODE_MT7925_1.bin"
  "BT_RAM_CODE_MT7961_1_2_hdr.bin"
  "BT_RAM_CODE_MT7922_1_1_hdr.bin"
  "BT_RAM_CODE_MT7925_1_1_hdr.bin"
)

FW_BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek"
for blob in "${MTK_BLOBS[@]}"; do
  if [[ ! -f "$FW_TARGET/$blob" ]]; then
    echo "   [!] Firmware blob missing: $blob (attempting download...)"
    if command -v curl >/dev/null 2>&1; then
      if curl --fail --location --show-error --max-time 15 "$FW_BASE_URL/$blob" -o "$FW_TARGET/$blob"; then
        echo "   [+] Downloaded $blob successfully."
      else
        rm -f "$FW_TARGET/$blob"
        echo "   [!] Firmware remains unavailable: $blob" >&2
      fi
    else
      echo "   [!] curl unavailable; firmware remains missing: $blob" >&2
    fi
  fi
done

if [[ -e "$MNT/lib" && ! -L "$MNT/lib" && -d "$MNT/lib/firmware" ]]; then
  mkdir -p "$MNT/lib/firmware/mediatek"
  cp -an "$FW_TARGET/." "$MNT/lib/firmware/mediatek/"
fi

echo "== Installing Omarchy desktop environment files..."
mkdir -p "$MNT/usr/local/share/quigon"
if [[ -f "$REPO_ROOT/scripts/setup-omarchy.sh" ]]; then
  cp -f "$REPO_ROOT/scripts/setup-omarchy.sh" "$MNT/usr/local/share/quigon/"
  chmod 755 "$MNT/usr/local/share/quigon/setup-omarchy.sh"
fi

mkdir -p "$MNT/usr/share/omarchy"
if command -v git >/dev/null 2>&1; then
  echo "== Fetching Omarchy base configuration into /usr/share/omarchy..."
  if git clone --depth 1 https://github.com/basecamp/omarchy.git "$MNT/usr/share/omarchy"; then
    echo "[+] Omarchy sources cloned; upstream provisioning scripts are not run on this ARM system."
  else
    echo "[!] Omarchy source clone failed; local Hyprland configuration can still be used." >&2
  fi
else
  echo "[!] git unavailable; Omarchy upstream sources were not cloned." >&2
fi

echo "== Preparing Hyprland & Omarchy desktop configuration..."
mkdir -p "$MNT/etc/skel/.config/hypr"
mkdir -p "$MNT/home/alarm/.config/hypr"
if [[ -d "$REPO_ROOT/port/quigon/user" ]]; then
  cp -a "$REPO_ROOT/port/quigon/user/." "$MNT/etc/skel/.config/hypr/"
  cp -a "$REPO_ROOT/port/quigon/user/." "$MNT/home/alarm/.config/hypr/"
  find "$MNT/etc/skel" "$MNT/home/alarm" -perm /022 ! -type l -exec chmod go-w {} +
  chown -R 1000:1000 "$MNT/home/alarm/.config"
fi

if [[ -n "$PUBKEY" ]]; then
  mkdir -p "$MNT/root/.ssh"
  echo "$PUBKEY" > "$MNT/root/.ssh/authorized_keys"
  chmod 700 "$MNT/root/.ssh"
  chmod 600 "$MNT/root/.ssh/authorized_keys"

  mkdir -p "$MNT/home/alarm/.ssh"
  echo "$PUBKEY" > "$MNT/home/alarm/.ssh/authorized_keys"
  chmod 700 "$MNT/home/alarm/.ssh"
  chmod 600 "$MNT/home/alarm/.ssh/authorized_keys"
  chown -R 1000:1000 "$MNT/home/alarm/.ssh"
fi

if [[ -n "$WIFI_SSID" && -f "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" \
      && ! -f "$MNT/usr/lib/systemd/system/wpa_supplicant@.service" ]]; then
  echo "== Installing wpa_supplicant in the new rootfs (chroot, needs network)..."
  mount --bind /proc "$MNT/proc"; mount --bind /sys "$MNT/sys"; mount --bind /dev "$MNT/dev"
  mount -t tmpfs tmpfs "$MNT/tmp"
  resolv_saved=0
  if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
    mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.orig"; resolv_saved=1
  fi
  cp /etc/resolv.conf "$MNT/etc/resolv.conf" || true
  chroot "$MNT" /bin/bash -c 'pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1 && pacman -Sy --noconfirm --needed wpa_supplicant' \
    || echo "[!] wpa_supplicant install failed; Wi-Fi will need manual setup." >&2
  chroot "$MNT" gpgconf --kill all 2>/dev/null || true
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/root" 2>/dev/null)" == "$MNT" ]] && kill "${p#/proc/}" 2>/dev/null || true
  done
  sleep 1
  rm -f "$MNT/etc/resolv.conf"
  if [[ "$resolv_saved" == 1 ]]; then mv "$MNT/etc/resolv.conf.orig" "$MNT/etc/resolv.conf"; fi
  for d in tmp dev sys proc; do
    mountpoint -q "$MNT/$d" && umount "$MNT/$d" || true
  done
fi

SYSTEMD_WANTS="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$SYSTEMD_WANTS"
for unit in systemd-networkd systemd-resolved sshd; do
  unit_file="$MNT/usr/lib/systemd/system/$unit.service"
  if [[ -f "$unit_file" ]]; then
    ln -sfn "/usr/lib/systemd/system/$unit.service" "$SYSTEMD_WANTS/$unit.service"
  else
    echo "[!] Unit unavailable in the rootfs: $unit.service" >&2
  fi
done

if [[ -f "$MNT/etc/systemd/system/asus-cm14-first-boot.service" ]]; then
  ln -sf /etc/systemd/system/asus-cm14-first-boot.service "$SYSTEMD_WANTS/asus-cm14-first-boot.service"
fi
if [[ -f "$MNT/etc/systemd/system/quigon-mainline.service" ]]; then
  SYSINIT_WANTS="$MNT/etc/systemd/system/sysinit.target.wants"
  mkdir -p "$SYSINIT_WANTS"
  ln -sf /etc/systemd/system/quigon-mainline.service "$SYSINIT_WANTS/quigon-mainline.service"
fi
if [[ -n "$WIFI_SSID" && -f "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" ]]; then
  if [[ -f "$MNT/usr/lib/systemd/system/wpa_supplicant@.service" ]]; then
    ln -sfn /usr/lib/systemd/system/wpa_supplicant@.service "$SYSTEMD_WANTS/wpa_supplicant@wlan0.service"
  else
    echo "[!] wpa_supplicant@.service is missing; Wi-Fi will need manual setup." >&2
  fi
fi

echo "== Writing signed kernel to $part1..."
dd if="$TMP_KERN" of="$part1" bs=1M conv=fsync status=progress

sync
echo "=========================================================="
echo "[+] USB written: $DEV. Expect a BLACK SCREEN (stock ChromeOS kernel, no VT): reach it over SSH with your key."
echo ""
echo "Mandatory NVRAM step on your ASUS Chromebook CM14:"
echo "    sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0"
echo ""
echo "To boot on ASUS Chromebook CM14:"
echo " 1. Insert USB drive into USB-A or USB-C port."
echo " 2. Power on the Chromebook (side button)."
echo " 3. On Developer Mode screen ('OS verification is OFF'),"
echo "    press [Ctrl] + [U] to boot from USB (no beep!)."
echo "=========================================================="
