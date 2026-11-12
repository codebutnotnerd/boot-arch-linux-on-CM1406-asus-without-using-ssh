#!/usr/bin/env bash
set -euo pipefail
die() { echo "[-] $*" >&2; exit 1; }

DEV="${1:-}"; MODE="${2:-}"
[[ -b "$DEV" && "$MODE" =~ ^--(debug|probe|same|normal)$ ]] || die "Usage: sudo bash $0 /dev/sdX --debug|--probe|--same|--normal"
[[ $EUID -eq 0 ]] || die "Run as root (sudo, from VT2)."
for c in futility dd cgpt rootdev lsblk; do command -v "$c" >/dev/null || die "Missing command: $c"; done
[[ "$DEV" != "$(rootdev -s -d)" ]] || die "$DEV is the running ChromeOS disk."
case "$DEV" in *mmcblk*) die "$DEV looks like the internal eMMC.";; esac
[[ "$(lsblk -dno RM "$DEV" | tr -d ' ')" == 1 ]] || die "$DEV is not removable."
if [[ "$DEV" =~ [0-9]$ ]]; then P1="${DEV}p1"; else P1="${DEV}1"; fi
[[ -b "$P1" ]] || die "$P1 not found."
cgpt show -i 1 -t "$DEV" 2>/dev/null | grep -qi 'fe3a2a5d-4f32-41a7-b725-accc3285a309' \
  || die "Partition 1 of $DEV is not a ChromeOS kernel partition: this is not a stick made by install-usb.sh."

BASE='console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1'
case "$MODE" in
  --debug)
    CMDLINE="${BASE/rootwait/rootdelay=20} panic=5 ignore_loglevel" ;;
  --probe)
    CMDLINE="${BASE/rootwait/rootdelay=10}"
    CMDLINE="${CMDLINE/init=\/sbin\/init/init=\/bin\/false} panic=5 ignore_loglevel" ;;
  --same)
    CMDLINE='(unchanged stock command line)' ;;
  *)
    CMDLINE="$BASE" ;;
esac

KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
[[ -f "$KB" && -f "$SK" ]] || die "ChromeOS developer signing keys are missing."

running_disk="$(rootdev -s -d)"; running_root="$(rootdev -s)"
root_num="${running_root##*[!0-9]}"
[[ "$root_num" == 3 || "$root_num" == 5 ]] || die "Unexpected ChromeOS root partition: $running_root."
kern_num=$((root_num - 1))
if [[ "$running_disk" =~ [0-9]$ ]]; then part_kern="${running_disk}p${kern_num}"; else part_kern="${running_disk}${kern_num}"; fi
[[ -b "$part_kern" ]] || die "Active ChromeOS kernel partition not found: $part_kern"

T="$(mktemp -d /var/tmp/tarkin-cmdline.XXXXXX)"
trap 'rm -rf "$T"' EXIT
dd if="$part_kern" of="$T/stock.bin" bs=1M status=none
printf '%s\n' "$CMDLINE" > "$T/cmdline"
CFG=(--config "$T/cmdline")
[[ "$MODE" == --same ]] && CFG=()
futility vbutil_kernel --repack "$T/kernel.bin" --oldblob "$T/stock.bin" \
  --keyblock "$KB" --signprivate "$SK" ${CFG[@]+"${CFG[@]}"} --flags 0
futility vbutil_kernel --verify "$T/kernel.bin" >/dev/null || die "New kernel does not verify; stick not touched."

for p in "$DEV"?*; do
  [[ -b "$p" ]] || continue
  umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
done

echo "== Writing the kernel to $P1 with: $CMDLINE"
dd if="$T/kernel.bin" of="$P1" bs=1M conv=fsync status=none
sync
ksize="$(stat -c %s "$T/kernel.bin")"
dd if="$P1" of="$T/rb.bin" bs=1M count=$(( (ksize + 1048575) / 1048576 )) status=none
head -c "$ksize" "$T/rb.bin" > "$T/rb.trim"
[[ "$(md5sum < "$T/rb.trim" | awk '{print $1}')" == "$(md5sum < "$T/kernel.bin" | awk '{print $1}')" ]] \
  || die "Read-back differs from what was written. Try another port."
futility vbutil_kernel --verify "$T/rb.trim" >/dev/null || die "Kernel on $P1 does not verify after writing."
cgpt add -i 1 -S 1 -T 1 -P 15 "$DEV" >/dev/null 2>&1 || true
echo "[+] Kernel on $P1 rewritten and verified ($MODE)."
if [[ "$MODE" != --normal ]]; then
  cat <<'EOF'

Next:
  1. Power off, power on, and at the menu choose "Boot from external disk".
  2. --debug: hands off for 4 minutes; if the root is not found the kernel panics and the machine restarts by itself.
     --probe / --same: the machine restarts by itself after about 10 s. Do NOT hold Power.
  3. Back in ChromeOS (VT2):
       ls -la /sys/fs/pstore
       sudo tail -n 80 /sys/fs/pstore/console-ramoops-0
  4. When done: sudo bash scripts/set-cmdline.sh /dev/sdX --normal
EOF
fi
