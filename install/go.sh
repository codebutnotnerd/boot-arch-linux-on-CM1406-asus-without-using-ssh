#!/bin/bash
# go.sh - guided launcher for the installer, made for the ChromeOS VT2 console (no copy/paste, QWERTY keyboard).
# It finds the Arch Linux ARM tarball, detects the USB stick, asks one confirmation and runs
# install-usb.sh. Run it as root from VT2:   sudo bash install/go.sh
# Extra arguments are passed to install-usb.sh (for example  --wifi-ssid "MyNetwork"  or  --keymap us).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root:  sudo bash install/go.sh" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

usb_disks() {   # prints "name size model" for each removable USB disk
  local d name
  for d in /sys/block/sd*; do
    [[ -e "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$(cat "$d/removable" 2>/dev/null)" == 1 ]] || continue
    [[ "$(readlink -f "$d")" == *"/usb"* ]] || continue
    printf '%s %s %s\n' "$name" "$(lsblk -dno SIZE "/dev/$name" 2>/dev/null)" "$(lsblk -dno MODEL "/dev/$name" 2>/dev/null | tr ' ' '_')"
  done
}

# 1. Arch Linux ARM tarball (with its .md5 beside it)
ALARM=""
for dir in /var/tmp /home/chronos/user/MyFiles/Downloads /home/chronos/user/Downloads /home/chronos/u-*/MyFiles/Downloads /home/chronos/u-*/Downloads "$ROOT" "$ROOT/.."; do
  [[ -f "$dir/ArchLinuxARM-aarch64-latest.tar.gz" ]] && { ALARM="$dir/ArchLinuxARM-aarch64-latest.tar.gz"; break; }
done
ALARM_ARGS=()
if [[ -n "$ALARM" ]]; then
  [[ -f "$ALARM.md5" ]] || { echo "[-] Found $ALARM but not $ALARM.md5 beside it. Download the .md5 file too." >&2; exit 1; }
  echo "Rootfs    : $ALARM"
  ALARM_ARGS=(--alarm "$ALARM")
else
  echo "Rootfs    : not found locally, the installer will download it (can be slow; see README if it stalls)"
fi

# 2. USB stick
mapfile -t disks < <(usb_disks)
if (( ${#disks[@]} == 0 )); then
  echo "[-] No USB stick detected. Replug it, wait 5 seconds, try another port, then run this again." >&2
  echo "    Kernel messages:" >&2; dmesg | tail -8 >&2
  exit 1
fi
echo "USB sticks:"
printf '   /dev/%s\n' "${disks[@]}"
default="/dev/${disks[0]%% *}"
read -r -p "Device to ERASE and install on [$default]: " DEV
DEV="${DEV:-$default}"
[[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
ok=0; for d in "${disks[@]}"; do [[ "/dev/${d%% *}" == "$DEV" ]] && ok=1; done
[[ $ok == 1 ]] || { echo "[-] $DEV is not one of the detected USB sticks. Aborting." >&2; exit 1; }

echo
echo "ALL DATA ON $DEV WILL BE ERASED."
read -r -p "Type the device name again to confirm ($DEV): " confirm
[[ "$confirm" == "$DEV" ]] || { echo "[-] Confirmation did not match. Aborting." >&2; exit 1; }

exec env CONFIRM_ERASE="$DEV" bash "$HERE/install-usb.sh" "${ALARM_ARGS[@]}" "$@" "$DEV"
