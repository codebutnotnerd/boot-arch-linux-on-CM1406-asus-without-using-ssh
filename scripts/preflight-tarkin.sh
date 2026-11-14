#!/bin/bash
set -u
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
O=/var/tmp/pf
rm -rf "$O"; mkdir -p "$O"
KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
CMDLINE='console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1'
{
echo "== board"
compat="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)"
echo "compatible: ${compat:-unreadable}"
if [[ "$compat" == *google,tarkin* ]]; then echo "board: OK (google,tarkin)"; else echo "board: FAILED (not a google,tarkin board)"; fi
echo "kernel: $(uname -r)"
echo "mainfw_type: $(crossystem mainfw_type 2>&1)"

echo "== tools"
for c in cgpt futility bsdtar mkfs.ext4 blockdev blkid dd findmnt mountpoint chroot unshare mount umount md5sum curl crossystem rootdev lsblk; do
  printf '%s: ' "$c"; command -v "$c" || echo MISSING
done

echo "== signing keys"
[[ -f "$KB" ]] && echo "keyblock: OK" || echo "keyblock: MISSING"
[[ -f "$SK" ]] && echo "private key: OK" || echo "private key: MISSING"

echo "== firmware flags (read-only)"
echo "dev_boot_usb=$(crossystem dev_boot_usb 2>&1) dev_boot_signed_only=$(crossystem dev_boot_signed_only 2>&1)"

echo "== active slot and kernel partition"
disk="$(rootdev -s -d)"; root="$(rootdev -s)"; num="${root##*[!0-9]}"
echo "disk=$disk root=$root"
k=""
case "$num" in 3|5) k=$((num - 1));; *) echo "root partition: FAILED (unexpected $root, expected p3 or p5)";; esac
if [[ "$disk" =~ [0-9]$ ]]; then pk="${disk}p${k}"; else pk="${disk}${k}"; fi
echo "kernel partition: $pk"
[[ -b "$pk" ]] && echo "block device: OK" || echo "block device: ABSENT"

echo "== modules and firmware"
[[ -d "/lib/modules/$(uname -r)" ]] && echo "modules: OK" || echo "modules: MISSING (/lib/modules/$(uname -r))"
[[ -d /lib/firmware ]] && echo "firmware dir: OK" || echo "firmware dir: MISSING"
for b in WIFI_MT7925_PATCH_MCU_1_1_hdr.bin WIFI_RAM_CODE_MT7925_1_1.bin BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  [[ -s /lib/firmware/mediatek/mt7925/$b ]] && echo "mt7925/$b: OK" || echo "mt7925/$b: ABSENT (the installer will try to download it)"
done

echo "== space and mount options"
df -h /var/tmp /usr/local 2>&1
findmnt -no TARGET,OPTIONS -T /usr/local 2>&1

echo "== mount test (tmpfs in memory, no disk)"
mkdir -p /usr/local/pf_mnt
if mount -t tmpfs tmpfs /usr/local/pf_mnt; then echo "mount: OK"; umount /usr/local/pf_mnt; else echo "mount: FAILED"; fi
rmdir /usr/local/pf_mnt 2>/dev/null

echo "== dry-run kernel repack (writes only to $O)"
if [[ -b "$pk" && -f "$KB" && -f "$SK" ]]; then
  dd if="$pk" of="$O/stock.bin" bs=1M status=none
  echo "read: $(stat -c %s "$O/stock.bin") bytes"
  printf '%s\n' "$CMDLINE" > "$O/cmdline"
  futility vbutil_kernel --repack "$O/test-kernel.bin" --oldblob "$O/stock.bin" \
    --keyblock "$KB" --signprivate "$SK" --config "$O/cmdline" --flags 0
  rc=$?
  [[ $rc -eq 0 ]] && echo "repack: OK" || echo "repack: FAILED (exit $rc)"
  futility vbutil_kernel --verify "$O/test-kernel.bin" 2>&1 | sed -n '/Flags/p;/Body verification/p;/^Config:/,$p'
else
  echo "repack: SKIPPED (partition or keys missing)"
fi

echo "== virtual terminals (VTs: what sddm and any display manager need)"
# ChromeOS and the stick boot the SAME signed kernel, so this answer is the one
# the stick will get. 'vt -1' from sddm means VT_OPENQRY found no free VT.
sys=0; [[ -d /sys/class/tty/tty0 ]] && sys=1
dev=0; [[ -c /dev/tty0 ]] && dev=1
echo "VT driver in the kernel (sysfs): $([[ $sys == 1 ]] && echo OK || echo MISSING)"
echo "tty0 device visible in this shell: $([[ $dev == 1 ]] && echo OK || echo MISSING)"
if (( sys && ! dev )); then
  echo "  note: sysfs says the kernel HAS VTs, so this shell (crosh/container) simply does not expose /dev/tty0."
  echo "        Run this from VT2 (Ctrl+Alt+Refresh) for the real answer."
fi
n=0; for t in /dev/tty[0-9]*; do [[ -c "$t" ]] && n=$((n+1)); done
echo "VT devices in this shell: $n"
echo "console/active: $(cat /sys/class/tty/console/active 2>/dev/null || echo unreadable)"
# Could a VT draw text at all? fbcon + a framebuffer. A display manager does not
# need either (it draws through DRM), but without them a failed greeter leaves a
# black panel with no on-screen error.
fbcon=0; fbdev=0; vtdev=0
grep -qi 'frame buffer' /sys/class/vtconsole/vtcon*/name 2>/dev/null && fbcon=1
[[ -e /sys/class/graphics/fb0 ]] && fbdev=1
[[ -c /dev/tty0 ]] && vtdev=1
echo "fbcon registered: $([[ $fbcon == 1 ]] && echo OK || echo MISSING)"
echo "framebuffer: $([[ $fbdev == 1 ]] && echo OK || echo MISSING)"
echo "VT device: $([[ $vtdev == 1 ]] && echo OK || echo MISSING)"
if (( fbcon && fbdev && vtdev )); then
  echo "text console: OK (a failed greeter could be diagnosed on screen)"
else
  echo "text console: NOT AVAILABLE (a failed greeter would leave a black panel: --console dm is a one-way door)"
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' 2>&1
import array, fcntl, os
try:
    fd = os.open("/dev/tty0", os.O_RDWR | os.O_NOCTTY)
except OSError as e:
    print("VT_OPENQRY: FAILED (cannot open /dev/tty0: %s)" % e.strerror); raise SystemExit
buf = array.array("i", [0])
try:
    fcntl.ioctl(fd, 0x5600, buf, True)      # VT_OPENQRY
    print("VT_OPENQRY: OK, free VT is %d" % buf[0])
except OSError as e:
    print("VT_OPENQRY: FAILED (%s) -> a display manager will say 'vt -1'" % e.strerror)
finally:
    os.close(fd)
PY
else
  echo "VT_OPENQRY: SKIPPED (python3 not available here)"
fi

echo "== network"
if curl -sIL --max-time 20 https://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5 2>&1 | grep -q "^HTTP.* 200"; then
  echo "mirror.archlinuxarm.org: OK"
elif curl -sIL --max-time 20 http://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5 2>&1 | grep -q "^HTTP.* 200"; then
  echo "mirror.archlinuxarm.org: OK (http only: the https certificate of the ALARM server does not match its hostname, the installer uses http)"
else
  echo "mirror.archlinuxarm.org: FAILED (no network?)"
fi

echo "== block devices (plug the USB stick in first)"
lsblk -o NAME,SIZE,RM,TRAN,TYPE,MODEL 2>&1 | grep -v -E '^(loop|zram)|[ `|]-?[0-9a-f]{20,}'
} 2>&1 | tee "$O/report.txt"
chmod -R a+r "$O"
echo
echo "Report: $O/report.txt"
if grep -q -E 'MISSING|ABSENT|FAILED' "$O/report.txt"; then
  echo "Lines with MISSING/ABSENT/FAILED need attention (an ABSENT mt7925 firmware line alone is fine)."
fi
