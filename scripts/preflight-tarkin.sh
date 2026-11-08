#!/bin/bash
set -u
O=/var/tmp/pf
rm -rf "$O"
mkdir -p "$O"
KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
{
echo "## outils"
for c in cgpt futility bsdtar mkfs.ext4 blockdev blkid dd findmnt mountpoint chroot mount umount md5sum curl crossystem rootdev lsblk; do
  printf '%s: ' "$c"
  command -v "$c" || echo MANQUANT
done

echo "## cles de signature"
ls -l "$KB" "$SK" 2>&1

echo "## flags firmware (lecture seule)"
echo "dev_boot_usb=$(crossystem dev_boot_usb 2>&1) dev_boot_signed_only=$(crossystem dev_boot_signed_only 2>&1)"

echo "## slot et partition noyau"
disk="$(rootdev -s -d)"
root="$(rootdev -s)"
num="${root##*[!0-9]}"
echo "disk=$disk root=$root"
k=""
case "$num" in
  3|5) k=$((num - 1));;
  *) echo "ERREUR: racine inattendue ($root)";;
esac
if [[ "$disk" =~ [0-9]$ ]]; then pk="${disk}p${k}"; else pk="${disk}${k}"; fi
echo "partition noyau: $pk"
if [[ -b "$pk" ]]; then echo "peripherique bloc: OK"; else echo "peripherique bloc: ABSENT"; fi

echo "## espace et options de montage"
df -h /var/tmp /usr/local 2>&1
findmnt -no TARGET,OPTIONS -T /usr/local 2>&1

echo "## test de montage (tmpfs en memoire, aucun disque)"
mkdir -p /usr/local/pf_mnt
if mount -t tmpfs tmpfs /usr/local/pf_mnt; then echo "mount: OK"; umount /usr/local/pf_mnt; else echo "mount: ECHEC"; fi
rmdir /usr/local/pf_mnt 2>/dev/null

echo "## repack a blanc du noyau (ecrit seulement dans $O)"
if [[ -b "$pk" && -f "$KB" && -f "$SK" ]]; then
  dd if="$pk" of="$O/stock.bin" bs=1M status=none
  echo "lu: $(stat -c %s "$O/stock.bin") octets"
  printf '%s\n' "console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1" > "$O/cmdline"
  futility vbutil_kernel --repack "$O/test-kernel.bin" --oldblob "$O/stock.bin" \
    --keyblock "$KB" --signprivate "$SK" --config "$O/cmdline" --flags 0x1
  echo "repack: exit=$?"
  ls -l "$O/test-kernel.bin" 2>&1
  futility vbutil_kernel --verify "$O/test-kernel.bin" 2>&1 | sed -n '/Flags/p;/Body verification/p;/^Config:/,$p'
else
  echo "repack: IGNORE (partition ou cles manquantes)"
fi

echo "## reseau (lecture seule)"
curl -sI --max-time 20 https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5 2>&1 | head -1
curl -sI --max-time 20 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin 2>&1 | head -1

echo "## peripheriques (branche ta cle USB avant)"
lsblk -o NAME,SIZE,RM,TRAN,TYPE,MODEL 2>&1 | grep -v -E '^(loop|zram)|[ `|]-?[0-9a-f]{20,}'
} 2>&1 | tee "$O/report.txt"
chmod -R a+r "$O"
echo
echo "Rapport: $O/report.txt"
