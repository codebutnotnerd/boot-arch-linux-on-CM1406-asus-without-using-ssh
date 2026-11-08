#!/bin/bash
# check-usb.sh - diagnose an installed stick from ChromeOS (VT2, as root):   sudo bash scripts/check-usb.sh [/dev/sdX]
# Read-only. Tells you whether the firmware will accept the stick, what the stick contains, and prints the crash
# log of the last failed boot (ChromeOS keeps it in pstore).
[[ $EUID -eq 0 ]] || { echo "Run as root:  sudo bash scripts/check-usb.sh" >&2; exit 1; }
KERNEL_GUID="fe3a2a5d-4f32-41a7-b725-accc3285a309"
bad=0
ok()  { echo "  [OK]      $*"; }
warn(){ echo "  [PROBLEM] $*"; bad=1; }

DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  for d in /sys/block/sd*; do
    [[ -e "$d" && "$(cat "$d/removable" 2>/dev/null)" == 1 && "$(readlink -f "$d")" == *"/usb"* ]] && { DEV="/dev/$(basename "$d")"; break; }
  done
fi
[[ -b "$DEV" ]] || { echo "[-] No USB stick found. Plug it in (and try another port) or pass /dev/sdX." >&2; dmesg | tail -8; exit 1; }
case "$DEV" in *mmcblk*) echo "[-] Refusing the internal disk." >&2; exit 1;; esac
P1="${DEV}1"; P2="${DEV}2"; [[ "$DEV" =~ [0-9]$ ]] && { P1="${DEV}p1"; P2="${DEV}p2"; }
echo "== Stick: $DEV"

echo "== Firmware flags"
up="$(crossystem dev_boot_usb 2>&1)"; so="$(crossystem dev_boot_signed_only 2>&1)"; mf="$(crossystem mainfw_type 2>&1)"
[[ "$up" == 1 ]] && ok "dev_boot_usb=1" || warn "dev_boot_usb=$up (need 1):  sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0"
[[ "$so" == 0 ]] && ok "dev_boot_signed_only=0" || warn "dev_boot_signed_only=$so (need 0)"
[[ "$mf" == developer ]] && ok "mainfw_type=developer" || warn "mainfw_type=$mf (need developer)"

echo "== Partition table"
cgpt show "$DEV"
t="$(cgpt show -i 1 -t "$DEV" 2>/dev/null | tr 'A-F' 'a-f')"
[[ "$t" == "$KERNEL_GUID" ]] && ok "partition 1 is a ChromeOS kernel partition" || warn "partition 1 is not of type ChromeOS kernel ($t): the firmware will say 'no valid image'. Re-run the installer."
echo "  priority=$(cgpt show -i 1 -P "$DEV") tries=$(cgpt show -i 1 -T "$DEV") successful=$(cgpt show -i 1 -S "$DEV")"
[[ "$(cgpt show -i 1 -P "$DEV")" -ge 1 ]] 2>/dev/null && ok "kernel priority >= 1" || warn "kernel priority is 0: the firmware skips this partition"

echo "== Kernel signature"
T="$(mktemp /var/tmp/chk-kern.XXXXXX)"
dd if="$P1" of="$T" bs=1M count=64 status=none
if out="$(futility vbutil_kernel --verify "$T" 2>&1)"; then
  ok "kernel verifies"; echo "$out" | sed -n '/Flags/p;/Body verification/p;/^Config:/,$p' | sed 's/^/        /'
else
  warn "kernel does NOT verify: $out"
fi
rm -f "$T"

echo "== Root filesystem"
M="$(mktemp -d /var/tmp/chk-root.XXXXXX)"
if mount -o ro "$P2" "$M" 2>/dev/null; then
  PU="$(blkid -s PARTUUID -o value "$P2")"
  grep -q "$PU" "$M/etc/fstab" 2>/dev/null && ok "fstab matches the root PARTUUID" || warn "fstab does not match the root PARTUUID"
  [[ -x "$M/usr/bin/cage" && -x "$M/usr/bin/foot" && -x "$M/usr/bin/seatd" ]] && ok "cage, foot and seatd installed" || warn "cage/foot/seatd NOT installed: no on-screen terminal (re-run the installer with working internet)"
  [[ -f "$M/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" ]] && ok "Wi-Fi configuration present" || echo "  [info]    no Wi-Fi configured (use: sudo tarkin-wifi \"Name\" in the terminal)"
  [[ -x "$M/usr/bin/wpa_supplicant" ]] && ok "wpa_supplicant installed" || warn "wpa_supplicant NOT installed: the stick will have no Wi-Fi tools (re-run the installer with working internet)"
  [[ -e "$M/etc/systemd/system/multi-user.target.wants/tarkin-console.service" && -e "$M/etc/systemd/system/multi-user.target.wants/seatd.service" ]] && ok "console and seatd services enabled" || warn "console/seatd services not enabled"
  [[ -s "$M/etc/tarkin/console.env" ]] && ok "keyboard layout: $(cat "$M/etc/tarkin/console.env")" || warn "keyboard layout file missing"
  kv="$(uname -r)"; [[ -d "$M/usr/lib/modules/$kv" ]] && ok "kernel modules for $kv present" || warn "modules for $kv missing"
  ls "$M/usr/lib/firmware/updates/mediatek/mt7925/" >/dev/null 2>&1 && ok "MT7925 firmware present" || warn "MT7925 firmware missing"
  if [[ -f "$M/var/log/tarkin-boot.log" ]]; then
    echo "== Last boot report from the stick (/var/log/tarkin-boot.log, first 40 lines)"; head -40 "$M/var/log/tarkin-boot.log"
  else
    echo "  (no tarkin-boot.log: the system never got as far as running userspace)"
  fi
  umount "$M"
else
  warn "cannot mount $P2 (not ext4 or not written)"
fi
rmdir "$M" 2>/dev/null

echo "== Crash log of the previous boot (pstore)"
if ls /sys/fs/pstore/* >/dev/null 2>&1; then
  ls -l /sys/fs/pstore/
  for f in /sys/fs/pstore/console-ramoops*; do [[ -f "$f" ]] && { echo "--- tail of $f"; tail -60 "$f"; }; done
else
  echo "  none (the kernel did not crash, or the firmware rejected the stick before starting it)"
fi

echo
[[ $bad == 0 ]] && echo "Result: the stick looks correct. If the firmware still refuses it, send this whole output." \
                 || echo "Result: fix the [PROBLEM] lines above, then try again."
