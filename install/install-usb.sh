#!/bin/bash
set -euo pipefail

DEV=""
ALARM_SOURCE="${ALARM_ARCHIVE:-}"
ALARM_CUSTOM=0
KEYMAP="${KEYMAP:-fr}"
USER_PASS=""
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNT="/usr/local/tarkin_alarm_root"
WORK="/var/tmp"
ARCHIVE_TMP=""
KERNEL_TMP_DIR=""

CMDLINE='console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1'

SAVED_SYSCTL=()
save_sysctl() {
  local f
  for f in kernel/panic kernel/panic_on_oops kernel/panic_on_warn kernel/softlockup_panic \
           kernel/hung_task_panic kernel/watchdog vm/dirty_bytes vm/dirty_background_bytes \
           vm/dirty_ratio vm/dirty_background_ratio vm/swappiness vm/overcommit_memory; do
    [[ -r /proc/sys/$f ]] && SAVED_SYSCTL+=("$f=$(cat /proc/sys/$f)")
  done
}
restore_sysctl() {
  local kv f v
  for kv in "${SAVED_SYSCTL[@]:-}"; do
    [[ -n "$kv" ]] || continue
    f="${kv%%=*}"; v="${kv#*=}"
    [[ "$(cat /proc/sys/$f 2>/dev/null)" == "$v" ]] || { echo "[i] restoring $f=$v" >&2; echo "$v" > /proc/sys/$f 2>/dev/null || true; }
  done
}
throttle_writeback() {
  echo 0 > /proc/sys/vm/dirty_bytes 2>/dev/null || true
  echo 8388608  > /proc/sys/vm/dirty_background_bytes 2>/dev/null || true
  echo 33554432 > /proc/sys/vm/dirty_bytes 2>/dev/null || true
}
MASKED_HOOKS=(30-systemd-binfmt 30-systemd-daemon-reload-system 30-systemd-daemon-reload-user
              30-systemd-sysctl 30-systemd-tmpfiles 30-systemd-udev-reload 30-systemd-update
              30-systemd-hwdb 30-systemd-catalog 90-mkinitcpio-install 60-mkinitcpio-remove
              71-dracut-install 60-dracut-remove)
mask_hooks() {
  mkdir -p "$MNT/etc/pacman.d/hooks"
  local h
  for h in "${MASKED_HOOKS[@]}"; do ln -sfn /dev/null "$MNT/etc/pacman.d/hooks/$h.hook"; done
}
unmask_hooks() {
  local h
  for h in "${MASKED_HOOKS[@]}"; do rm -f "$MNT/etc/pacman.d/hooks/$h.hook"; done
  rmdir "$MNT/etc/pacman.d/hooks" 2>/dev/null || true
}
in_chroot() {
  unshare --mount --pid --fork --propagation private bash -c '
    set -e
    M="$1"; shift
    mount -t proc proc "$M/proc"
    for x in sys sysrq-trigger; do
      mount --bind "$M/proc/$x" "$M/proc/$x"
      mount -o remount,bind,ro "$M/proc/$x"
    done
    mount --rbind /sys "$M/sys";  mount -o remount,bind,ro "$M/sys" 2>/dev/null || true
    mount --rbind /dev "$M/dev"
    mount -t tmpfs tmpfs "$M/tmp"
    exec chroot "$M" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root TERM=dumb LANG=C "$@"
  ' _ "$MNT" "$@"
}

cleanup() {
  restore_sysctl
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
trap 'echo "[-] Error on line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

die() { echo "[-] $*" >&2; exit 1; }
CURL_OPTS=(--fail --location --show-error --connect-timeout 20 --retry 3 --retry-delay 3 --speed-time 45 --speed-limit 2000)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alarm|-a)     ALARM_SOURCE="${2:?missing value for $1}"; ALARM_CUSTOM=1; shift 2 ;;
    --keymap|-k)    KEYMAP="${2:?missing value for $1}"; shift 2 ;;
    --wifi-ssid|-s) WIFI_SSID="${2:?missing value for $1}"; shift 2 ;;
    --wifi-pass|-w) die "Do not pass Wi-Fi passwords on the command line; the installer prompts for it." ;;
    -h|--help)
      cat <<'USAGE'
Usage: sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh [options] /dev/sdX
Options:
  --alarm,   -a <file|http(s)-url>  ArchLinuxARM-aarch64 tarball (a matching .md5 file must sit next to it;
                                  a .sig file beside it is verified too)
  --wifi-ssid, -s <ssid>          Wi-Fi network (WPA2-PSK); the passphrase is prompted. Default: the network
                                  saved in ChromeOS, if any.
  --keymap,  -k <layout>          Keyboard layout of the on-screen terminal (xkb name: fr, us, de, ...). Default: fr
Environment:
  CONFIRM_ERASE=/dev/sdX  required, must equal the target device
  ALLOW_NO_WIFI=1         allow an install without any Wi-Fi configuration
  WIFI_COUNTRY=FR         optional two-letter regulatory domain written to wpa_supplicant
  ALLOW_NO_PKGS=1         skip the network check and the Wi-Fi tools (the stick then has no on-screen terminal)
  ALLOW_INSECURE_HTTP=1   accept a rootfs downloaded over plain http without a verifiable GPG signature
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
[[ "$KEYMAP" =~ ^[a-z0-9_+-]{2,20}$ ]] || die "--keymap must be an xkb layout name such as fr or us."

echo "=== Target: ASUS Chromebook CM1406 (Google Tarkin, MT8189) ==="

command -v rootdev >/dev/null 2>&1 || die "rootdev not found: run this on the Chromebook, in ChromeOS Developer Mode."

if [[ "${FORCE_BOARD:-0}" != 1 ]]; then
  compat="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
  [[ "$compat" == *google,tarkin* ]] \
    || die "This is not a google,tarkin board (compatible: ${compat:-unreadable}). Set FORCE_BOARD=1 to override."
fi

name="$(basename "$DEV")"
[[ "$DEV" =~ mmcblk ]] && die "$DEV looks like internal eMMC. This installer only targets USB drives."
[[ -d "/sys/block/$name" ]] || die "$DEV is not a whole disk. Pass the device (e.g. /dev/sda), not a partition."
[[ "$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)" == 1 ]] \
  || die "$DEV is marked non-removable. Aborting to protect the internal drive."
[[ "$(readlink -f "/sys/class/block/$name")" == *"/usb"* ]] \
  || die "$DEV is not identified as a USB device by sysfs."
[[ "$(rootdev -s -d 2>/dev/null || true)" != "$DEV" ]] \
  || die "$DEV is the disk ChromeOS is running from."

for c in cgpt futility blockdev mkfs.ext4 bsdtar md5sum blkid dd findmnt mountpoint chroot crossystem curl unshare; do
  command -v "$c" >/dev/null 2>&1 || die "Required command is missing: $c"
done
KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
[[ -f "$KB" && -f "$SK" ]] || die "ChromeOS developer signing keys are missing ($KB, $SK)."

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

ALARM_KEY_FPR=68B3537F39A313B3E574D06777193F152BDBE6A6
ALARM_KEYSERVERS=(hkps://keyserver.ubuntu.com hkps://keys.openpgp.org)

verify_signature() {
  local file="$1" sig="$2" gh ks status
  command -v gpg >/dev/null 2>&1 || return 1
  [[ -s "$sig" ]] || return 1
  gh="$(mktemp -d "$WORK/alarm-gpg.XXXXXX")"
  chmod 700 "$gh"
  for ks in "${ALARM_KEYSERVERS[@]}"; do
    if gpg --homedir "$gh" --batch --keyserver "$ks" --recv-keys "$ALARM_KEY_FPR" >/dev/null 2>&1; then break; fi
  done
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null)" || { rm -rf -- "$gh"; return 1; }
  rm -rf -- "$gh"
  grep -q "^\[GNUPG:\] VALIDSIG .*$ALARM_KEY_FPR" <<<"$status"
}

ARCHIVE=""
ARCHIVE_URL=""
if [[ -n "$ALARM_SOURCE" && "$ALARM_SOURCE" != http* ]]; then
  [[ -f "$ALARM_SOURCE" ]] || die "Arch Linux ARM archive not found: $ALARM_SOURCE"
  ARCHIVE="$ALARM_SOURCE"
else
  ALARM_MIRRORS=(
    https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    https://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    http://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    http://fr.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    http://nj.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
  )
  [[ "$ALARM_CUSTOM" == 1 ]] && ALARM_MIRRORS=("$ALARM_SOURCE")
  ARCHIVE_TMP="$(mktemp -d "$WORK/alarm-dl.XXXXXX")"
  ARCHIVE="$ARCHIVE_TMP/ArchLinuxARM-aarch64-latest.tar.gz"
  echo "== Downloading the rootfs (stalls are detected; https mirrors are tried first, then http)..."
  for u in "${ALARM_MIRRORS[@]}"; do
    echo "== Trying $u ..."
    if curl "${CURL_OPTS[@]}" "$u" -o "$ARCHIVE" && curl "${CURL_OPTS[@]}" "${u}.md5" -o "$ARCHIVE.md5"; then
      curl "${CURL_OPTS[@]}" "${u}.sig" -o "$ARCHIVE.sig" 2>/dev/null || rm -f "$ARCHIVE.sig"
      ARCHIVE_URL="$u"
      echo "== Rootfs downloaded from $u"
      break
    fi
    rm -f "$ARCHIVE" "$ARCHIVE.md5" "$ARCHIVE.sig"
  done
  [[ -n "$ARCHIVE_URL" ]] || die "Could not download the rootfs from any mirror. Download ArchLinuxARM-aarch64-latest.tar.gz and its .md5 with the ChromeOS browser into /var/tmp, then re-run with --alarm."
fi

[[ -f "$ARCHIVE.md5" ]] || die "Missing checksum file: $ARCHIVE.md5"
expected_md5="$(awk 'NR == 1 { print $1 }' "$ARCHIVE.md5" | tr '[:upper:]' '[:lower:]')"
[[ "$expected_md5" =~ ^[0-9a-f]{32}$ ]] || die "Invalid MD5 checksum format in $ARCHIVE.md5"
actual_md5="$(md5sum "$ARCHIVE" | awk '{ print $1 }')"
[[ "$actual_md5" == "$expected_md5" ]] || die "Rootfs checksum mismatch; refusing to erase the USB drive."

if [[ -s "$ARCHIVE.sig" ]]; then
  if verify_signature "$ARCHIVE" "$ARCHIVE.sig"; then
    echo "== Rootfs signature verified (key $ALARM_KEY_FPR)."
  else
    die "The signature of the rootfs does not verify against the Arch Linux ARM Build System key; refusing to erase the USB drive."
  fi
elif [[ "$ARCHIVE_URL" == http://* ]]; then
  if [[ "${ALLOW_INSECURE_HTTP:-0}" == 1 ]]; then
    echo "[!] The rootfs came over plain http and its authenticity could NOT be verified (ALLOW_INSECURE_HTTP=1)." >&2
  else
    die "The rootfs came over plain http and no verifiable GPG signature is available (needs gpg, the .sig file and a keyserver). A .md5 from the same server proves nothing. Download the tarball and its .md5 with the ChromeOS browser over https into /var/tmp and use --alarm, or set ALLOW_INSECURE_HTTP=1 to accept the risk."
  fi
fi

if [[ -z "$WIFI_SSID" && "${ALLOW_NO_WIFI:-0}" != 1 && -f /var/cache/shill/default.profile ]]; then
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
if [[ -z "$WIFI_SSID" ]]; then
  echo "[i] No Wi-Fi network configured. After booting, use  sudo tarkin-wifi \"NetworkName\"  in the terminal."
fi
if [[ -n "$WIFI_SSID" ]]; then
  [[ "$WIFI_SSID" != *$'\n'* && "$WIFI_SSID" != *$'\r'* ]] || die "SSIDs containing line breaks are not supported."
  (( ${#WIFI_PASS} >= 8 && ${#WIFI_PASS} <= 63 )) || die "Only WPA2-PSK passphrases (8-63 characters) are supported."
  [[ -z "${WIFI_COUNTRY:-}" || "$WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be two capital letters, e.g. FR."
fi

if [[ "${ALLOW_NO_PKGS:-0}" != 1 ]]; then
  echo "== Checking network access to the Arch Linux ARM package mirror..."
  curl -sSIL --connect-timeout 15 --max-time 30 http://mirror.archlinuxarm.org/aarch64/core/core.db >/dev/null 2>&1 \
    || die "Cannot reach mirror.archlinuxarm.org from this shell. Check that ChromeOS has internet (Wi-Fi connected), try another network (a phone hotspot), or set ALLOW_NO_PKGS=1 to install without Wi-Fi tools (the stick then has no on-screen terminal)."
fi

if [[ -t 0 ]]; then
  read -r -s -p "Password for the user 'alarm' (empty keeps the default, 'alarm'): " USER_PASS; echo
  if [[ -n "$USER_PASS" ]]; then
    read -r -s -p "Repeat the password: " pass2; echo
    [[ "$USER_PASS" == "$pass2" ]] || die "The two passwords differ."
    [[ "$USER_PASS" != *$'\n'* && "$USER_PASS" != *$'\r'* && "$USER_PASS" != *:* ]] || die "The password must not contain a newline or a colon."
  fi
fi

echo "Target USB device : $DEV"
echo "Stock kernel      : $part_kern ($KVER)"
echo "WARNING: all data on $DEV will be erased."
if [[ "${CONFIRM_ERASE:-}" != "$DEV" ]]; then
  [[ -t 0 ]] || die "Non-interactive run refused. Set CONFIRM_ERASE='$DEV' to confirm."
  read -r -p "Type '$DEV' to continue: " confirmation
  [[ "$confirmation" == "$DEV" ]] || die "Confirmation did not match; aborting."
fi

LOG="$WORK/tarkin-install.log"
exec > >(tee -a "$LOG") 2>&1
echo "[i] Full log: $LOG (survives a reboot; send it if the machine restarts again)"
save_sysctl
throttle_writeback
echo "== Repacking the stock kernel with the developer keys..."
KERNEL_TMP_DIR="$(mktemp -d "$WORK/tarkin-kernel.XXXXXX")"
dd if="$part_kern" of="$KERNEL_TMP_DIR/stock.bin" bs=1M status=none
printf '%s\n' "$CMDLINE" > "$KERNEL_TMP_DIR/cmdline"
futility vbutil_kernel --repack "$KERNEL_TMP_DIR/kernel.bin" --oldblob "$KERNEL_TMP_DIR/stock.bin" \
  --keyblock "$KB" --signprivate "$SK" --config "$KERNEL_TMP_DIR/cmdline" --flags 0
futility vbutil_kernel --verify "$KERNEL_TMP_DIR/kernel.bin"
(( $(stat -c %s "$KERNEL_TMP_DIR/kernel.bin") <= 64 * 1024 * 1024 )) || die "Signed kernel exceeds the 64 MiB kernel partition."

echo "== Enabling developer-mode USB boot..."
crossystem dev_boot_usb=1 dev_boot_signed_only=0
[[ "$(crossystem dev_boot_usb)" == 1 && "$(crossystem dev_boot_signed_only)" == 0 ]] \
  || die "crossystem did not enable USB boot of developer-signed kernels."

unmount_all() {
  local p _
  for p in "$DEV"?*; do
    [[ -b "$p" ]] || continue
    for _ in 1 2 3; do
      findmnt -rn -S "$p" >/dev/null 2>&1 || break
      umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || sleep 1
    done
    ! findmnt -rn -S "$p" >/dev/null 2>&1 \
      || die "Cannot unmount $p. Eject the stick in the Files app (or close what uses it) and run again."
  done
}
echo "== Unmounting existing partitions on $DEV..."
unmount_all

echo "== Partitioning $DEV (ChromeOS GPT: p1 kernel, p2 root)..."
total_sectors="$(blockdev --getsz "$DEV")"
(( total_sectors > 139264 + 4 * 2097152 )) || die "USB device is too small (the system needs about 4 GiB on the stick; 8 GiB or more is recommended, 16 GiB comfortable)."
cgpt create "$DEV"
cgpt boot -p "$DEV"
cgpt add -i 1 -t kernel -b 8192 -s 131072 -l KERN-A -S 1 -T 1 -P 15 "$DEV"
cgpt add -i 2 -t data -b 139264 -s $((total_sectors - 139264 - 2048)) -l ALARM "$DEV"
part1="${DEV}1"; part2="${DEV}2"
[[ "$DEV" =~ [0-9]$ ]] && { part1="${DEV}p1"; part2="${DEV}p2"; }
expected2=$((total_sectors - 139264 - 2048))
size2=0
for _ in 1 2 3 4 5; do
  blockdev --rereadpt "$DEV" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2
  size2="$(blockdev --getsz "$part2" 2>/dev/null || echo 0)"
  (( size2 >= expected2 - 4096 )) && break
  unmount_all
  sleep 2
done
cgpt show "$DEV"
[[ -b "$part1" && -b "$part2" ]] || die "Partition device nodes did not appear for $DEV."
(( size2 >= expected2 - 4096 )) \
  || die "The kernel still sees the OLD partition table ($part2 is $size2 sectors, expected about $expected2). Nothing was written to it. Unplug the stick, plug it in again WITHOUT opening the Files app, then run the installer again."

echo "== Formatting $part2 as ext4 (label ALARM)..."
unmount_all
mkfs.ext4 -F -L ALARM "$part2"
mkdir -p "$MNT"
mount "$part2" "$MNT"
avail_kb="$(df -Pk "$MNT" | awk 'NR==2 {print $4}')"
(( avail_kb >= 3 * 1048576 )) || die "Only $((avail_kb / 1024)) MiB free on the new root filesystem (need 3 GiB). Unplug and replug the stick, then run the installer again."

echo "== Extracting the Arch Linux ARM rootfs..."
bsdtar -xpf "$ARCHIVE" -C "$MNT"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$part2")"
[[ -n "$ROOT_PARTUUID" ]] || die "Could not read PARTUUID for $part2."
sync

echo "== Installing Tarkin configuration..."
printf 'PARTUUID=%s / ext4 defaults,noatime 0 1\n' "$ROOT_PARTUUID" > "$MNT/etc/fstab"
echo "asus-cm1406" > "$MNT/etc/hostname"
cp -R --no-preserve=ownership "$REPO_ROOT/rootfs/." "$MNT/"
( cd "$REPO_ROOT/rootfs" && find . -type f ) | while read -r f; do
  chown 0:0 "$MNT/$f"
  case "$f" in ./usr/local/bin/*|./usr/local/libexec/*) chmod 755 "$MNT/$f" ;; *) chmod 644 "$MNT/$f" ;; esac
done
ALARM_UID="$(awk -F: '$1 == "alarm" { print $3 }' "$MNT/etc/passwd")"
ALARM_GID="$(awk -F: '$1 == "alarm" { print $4 }' "$MNT/etc/passwd")"
ALARM_UID="${ALARM_UID:-1000}"; ALARM_GID="${ALARM_GID:-1000}"
if [[ -d "$MNT/home/alarm" ]]; then
  install -m 755 "$REPO_ROOT/scripts/install-desktop.sh" "$MNT/home/alarm/install-desktop.sh"
  chown "$ALARM_UID:$ALARM_GID" "$MNT/home/alarm/install-desktop.sh"
fi
mkdir -p "$MNT/etc/tarkin"
printf 'XKB_DEFAULT_LAYOUT=%s\n' "$KEYMAP" > "$MNT/etc/tarkin/console.env"
chmod 644 "$MNT/etc/tarkin/console.env"
mkdir -p "$MNT/var/lib/systemd/linger"; : > "$MNT/var/lib/systemd/linger/alarm"

mkdir -p "$MNT/var/log/journal"

echo "== Copying ChromeOS kernel modules ($KVER) and firmware..."
mkdir -p "$MNT/usr/lib/modules" "$MNT/usr/lib/firmware/updates"
cp -a "/lib/modules/$KVER" "$MNT/usr/lib/modules/"
cp -a /lib/firmware/. "$MNT/usr/lib/firmware/updates/"

FW_DIR="$MNT/usr/lib/firmware/updates/mediatek/mt7925"
mkdir -p "$FW_DIR"
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
for blob in WIFI_MT7925_PATCH_MCU_1_1_hdr.bin WIFI_RAM_CODE_MT7925_1_1.bin BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  if [[ ! -s "$FW_DIR/$blob" ]]; then
    echo "   [!] $blob missing from ChromeOS, downloading..."
    curl "${CURL_OPTS[@]}" --max-time 90 "$FW_URL/$blob" -o "$FW_DIR/$blob" \
      || { rm -f "$FW_DIR/$blob"; echo "   [!] $blob unavailable: Wi-Fi may not come up." >&2; }
  fi
done

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
  mkdir -p "$MNT/etc/wpa_supplicant"
  {
    echo "ctrl_interface=/run/wpa_supplicant"
    echo "update_config=1"
    [[ -z "${WIFI_COUNTRY:-}" ]] || echo "country=$WIFI_COUNTRY"
    echo "network={"
    echo "  ssid=\"$WIFI_SSID\""
    echo "  psk=\"$WIFI_PASS\""
    echo "  key_mgmt=WPA-PSK"
    echo "}"
  } > "$WPA_CONF"
  chmod 600 "$WPA_CONF"
fi

resolv_saved=0
if [[ "${ALLOW_NO_PKGS:-0}" == 1 ]]; then
  echo "[i] ALLOW_NO_PKGS=1: skipping the package install entirely (no terminal, no Wi-Fi tools on the stick)."
else
  echo "== Installing the terminal (cage, foot, seatd), Wi-Fi tools and sudo in the new rootfs (isolated chroot, needs network)..."
  sync
  mask_hooks
  if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
    mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.orig"; resolv_saved=1
  fi
  cp /etc/resolv.conf "$MNT/etc/resolv.conf" || true
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >> "$MNT/etc/resolv.conf"
  PKG_OK=1
  in_chroot /bin/bash -c 'pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1 && pacman -Syu --noconfirm --noprogressbar --needed --ignore linux-aarch64,linux-aarch64-headers wpa_supplicant iw pciutils seatd cage foot foot-terminfo ttf-dejavu sudo nano' \
    || { PKG_OK=0; echo "[!] Package install failed (no network from this shell?)." >&2; }
  sync
  [[ -x "$MNT/usr/bin/wpa_supplicant" && -x "$MNT/usr/bin/cage" && -x "$MNT/usr/bin/foot" && -x "$MNT/usr/bin/seatd" ]] || PKG_OK=0
  restore_sysctl
fi

if [[ -x "$MNT/usr/bin/usermod" ]]; then
  for g in video input render audio seat wheel; do
    in_chroot getent group "$g" >/dev/null 2>&1 || { in_chroot groupadd -r "$g" 2>/dev/null || true; }
    in_chroot usermod -aG "$g" alarm || echo "[!] Could not add the user alarm to group $g." >&2
  done
  for g in video input render audio seat; do
    in_chroot getent group "$g" >/dev/null 2>&1 \
      || echo "[!] Group $g is still missing in the rootfs: tarkin-console.service lists it and will fail with 216/GROUP. Run scripts/check-usb.sh after booting ChromeOS." >&2
  done
  echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"; chmod 440 "$MNT/etc/sudoers.d/10-wheel"
  if [[ -n "$USER_PASS" ]]; then
    if printf 'alarm:%s\n' "$USER_PASS" | in_chroot chpasswd; then
      in_chroot passwd -l root >/dev/null 2>&1 || true
      echo "   Password set for alarm; root login locked (use sudo)."
    else
      echo "[!] Could not set the password: the default 'alarm' / 'alarm' stays. Change it at first boot with: passwd"
    fi
  else
    echo "   Default account kept: alarm / alarm. CHANGE IT at first boot with: passwd"
  fi
fi

if [[ -n "$WIFI_SSID" && -x "$MNT/usr/bin/wpa_passphrase" ]]; then
  hashed="$(printf '%s\n' "$WIFI_PASS" | in_chroot /usr/bin/wpa_passphrase "$WIFI_SSID" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')" || hashed=""
  if [[ "$hashed" =~ ^[0-9a-f]{64}$ ]]; then
    sed -i "s/^  psk=.*/  psk=$hashed/" "$WPA_CONF"
    echo "   Passphrase stored as a hashed PSK."
  else
    echo "   [!] Could not hash the passphrase; it stays in the root-only (0600) config file."
  fi
fi

if [[ "${ALLOW_NO_PKGS:-0}" != 1 ]]; then
  unmask_hooks
  rm -f "$MNT/etc/resolv.conf"
  [[ "$resolv_saved" == 1 ]] && rm -f "$MNT/etc/resolv.conf.orig" || true
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
fi
sync

WANTS="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS" "$MNT/etc/systemd/system/timers.target.wants"
enable_unit() {
  local unit="$1" dir="$2" link="${3:-$(basename "$1")}"
  if [[ -f "$MNT$unit" ]]; then ln -sfn "$unit" "$dir/$link"; else echo "[!] Unit unavailable in the rootfs: $unit" >&2; fi
}
enable_unit /usr/lib/systemd/system/systemd-networkd.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-resolved.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-timesyncd.service "$WANTS"
enable_unit /usr/lib/systemd/system/seatd.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-console.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-bootlog.timer "$MNT/etc/systemd/system/timers.target.wants"
if [[ -n "$WIFI_SSID" ]]; then
  enable_unit /usr/lib/systemd/system/wpa_supplicant@.service "$WANTS" wpa_supplicant@wlan0.service
fi

echo "== Writing the signed kernel to $part1..."
dd if="$KERNEL_TMP_DIR/kernel.bin" of="$part1" bs=1M conv=fsync status=progress
sync

echo "== Verifying what was written to $part1..."
ksize="$(stat -c %s "$KERNEL_TMP_DIR/kernel.bin")"
dd if="$part1" of="$KERNEL_TMP_DIR/readback.bin" bs=1M count=$(( (ksize + 1048575) / 1048576 )) status=none
head -c "$ksize" "$KERNEL_TMP_DIR/readback.bin" > "$KERNEL_TMP_DIR/readback.trim"
[[ "$(md5sum < "$KERNEL_TMP_DIR/readback.trim" | awk '{print $1}')" == "$(md5sum < "$KERNEL_TMP_DIR/kernel.bin" | awk '{print $1}')" ]] \
  || die "The kernel read back from $part1 differs from what was written. Try another USB port or stick."
futility vbutil_kernel --verify "$KERNEL_TMP_DIR/readback.trim" >/dev/null || die "The kernel on $part1 does not verify."
cgpt show "$DEV"
echo "   Kernel on $part1: written and verified."

if [[ "${PKG_OK:-1}" != 1 && "${ALLOW_NO_PKGS:-0}" != 1 ]]; then
  cat <<'WARN'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
[!] WARNING: the packages (wpa_supplicant, cage, foot, seatd, ...) could NOT all
    be installed on the stick. The system will probably boot but may have no
    on-screen terminal and no Wi-Fi tools.
    Fix the network (see README, "Troubleshooting") and run the installer again.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARN
fi
cat <<EOF
==========================================================
[+] USB written: $DEV

Boot it:
 1. Leave the stick plugged in and power the Chromebook off, then on.
 2. At the 'OS verification is OFF' screen press Ctrl+U.
 3. Wait 1-2 minutes: a terminal should appear on the screen (the firmware logo may stay up for a while).
    First command to run:  passwd  (the default account is alarm/alarm until you change it).
    Administration: sudo. Wi-Fi: sudo tarkin-wifi "Network".
    Optional desktop (Wi-Fi first): bash ~/install-desktop.sh then sudo tarkin-session desktop
    If the screen stays black or frozen on the logo for 3 minutes, this experimental console did not start:
    power off, then see README, "Troubleshooting".

If nothing works: hold the power button, unplug the stick, then press Ctrl+D to boot ChromeOS.
To see what happened: run  sudo bash scripts/check-usb.sh  in ChromeOS (see README, "Troubleshooting").
==========================================================
EOF
