#!/usr/bin/env bash
set -uo pipefail
OUT="${OUT:-$HOME/tarkin-report}"
mkdir -p "$OUT"
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

DISK="$(rootdev -s -d 2>/dev/null || true)"
[[ -n "$DISK" ]] || { echo "rootdev not found: run this on ChromeOS." >&2; exit 1; }
case "$DISK" in
  *mmcblk*|*nvme*) P="${DISK}p" ;;
  *)               P="$DISK" ;;
esac
ROOT_PART="$(rootdev -s)"
ROOT_NUM="${ROOT_PART##*[!0-9]}"
KERN_A="${P}$((ROOT_NUM - 1))"

{
  echo "== board compatible =="; tr '\0' '\n' < /proc/device-tree/compatible
  echo "== model ==";           tr '\0' '\n' < /proc/device-tree/model
  echo "== root disk ==";       echo "$DISK"
  echo "== storage type ==";    case "$DISK" in *mmcblk*) echo eMMC;; /dev/sd*) ls /sys/class/ufshcd /sys/class/scsi_host 2>/dev/null | head; echo "(sdX: UFS or USB-class device)";; esac
  echo "== partitions ==";      cgpt show "$DISK" 2>/dev/null | sed -E 's/(UUID: ).*/\1<redacted>/'
  echo "== uname ==";           uname -a
  echo "== crossystem (no ids) =="; crossystem mainfw_type dev_boot_usb dev_boot_signed_only 2>/dev/null
  echo "== wifi / bt / audio / input =="
  lspci 2>/dev/null; lsusb 2>/dev/null; cat /proc/asound/cards 2>/dev/null
  grep -E "Name=" /proc/bus/input/devices 2>/dev/null
  ls /sys/class/drm 2>/dev/null
} > "$OUT/report.txt" 2>&1

dd if="$KERN_A" of="$OUT/kern_a.bin" bs=1M 2>/dev/null
if command -v futility >/dev/null 2>&1; then
  futility vbutil_kernel --get-vmlinuz "$OUT/kern_a.bin" --vmlinuz-out "$OUT/stock.fit" >/dev/null 2>&1 || true
fi
if [[ -s "$OUT/stock.fit" ]] && command -v dumpimage >/dev/null 2>&1; then
  dumpimage -l "$OUT/stock.fit" > "$OUT/stock-fit-layout.txt" 2>&1 || true
fi
if command -v dtc >/dev/null 2>&1; then
  dtc -I fs -O dts -o "$OUT/running.dts" /proc/device-tree 2>/dev/null || true
  sed -i -E '/hardware-id|hwid|serial-number|bootargs|kern_guid|mac-address/d' "$OUT/running.dts" 2>/dev/null || true
fi
rm -f "$OUT/kern_a.bin"
echo "Done. Report files: $OUT/report.txt, $OUT/running.dts, $OUT/stock-fit-layout.txt"
echo "(stock.fit is also in $OUT; it is large, keep it local unless asked.)"
