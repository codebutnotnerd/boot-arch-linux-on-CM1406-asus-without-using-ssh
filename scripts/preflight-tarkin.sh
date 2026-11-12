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
