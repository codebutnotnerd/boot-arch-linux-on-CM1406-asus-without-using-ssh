#!/bin/bash
# Finish a pacman transaction that a panic/reboot interrupted, from a PC.
#
# The stick is aarch64. On an x86_64 Arch host, qemu-user-static + binfmt lets
# us chroot into it and run the real pacman, so the package database, the files
# on disk and the linker cache all agree again.
#
# Usage (on the host, with the stick mounted, e.g. /run/media/$USER/ALARM):
#     sudo bash scripts/repair-pacman-from-host.sh [MOUNTPOINT]
#
# It never formats, repartitions or touches the signed kernel partition.
set -euo pipefail
M="${1:-}"
[[ -n "$M" ]] || M="$(findmnt -rno TARGET -S LABEL=ALARM 2>/dev/null | head -1)"
[[ -n "$M" ]] || { echo "[-] ALARM stick not mounted. Mount it or pass the mountpoint."; exit 1; }
M="$(readlink -f "$M")"

echo "== Target rootfs: $M"
[[ -f "$M/etc/pacman.conf" && -f "$M/etc/tarkin/console.env" ]] \
  || { echo "[-] $M does not look like the ALARM/Tarkin rootfs. Refusing."; exit 1; }

RESOLV_WAS_SYMLINK=0
RESOLV_TARGET=""
cleanup() {
  for d in dev proc sys; do
    mountpoint -q "$M/$d" 2>/dev/null && umount -R "$M/$d" 2>/dev/null || true
  done
  if (( RESOLV_WAS_SYMLINK )); then
    rm -f "$M/etc/resolv.conf"
    ln -sfn "$RESOLV_TARGET" "$M/etc/resolv.conf"
  fi
  echo "== Cleaned up."
}
trap cleanup EXIT

echo "== qemu-user-static + binfmt"
if ! command -v qemu-aarch64-static >/dev/null && ! command -v qemu-aarch64 >/dev/null; then
  pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
fi
systemctl restart systemd-binfmt 2>/dev/null || true
compgen -G '/proc/sys/fs/binfmt_misc/*aarch64*' >/dev/null \
  || { echo "[-] binfmt handler for aarch64 did not register."; exit 1; }

echo "== Throttling writeback on the host (this is what caused the panic)"
sysctl -w vm.dirty_background_bytes=8388608 >/dev/null
sysctl -w vm.dirty_bytes=33554432 >/dev/null

echo "== Hardening the stick"
cat > "$M/etc/sysctl.d/90-tarkin-panic.conf" <<'EOF'
kernel.hung_task_panic = 0
kernel.hung_task_timeout_secs = 120
vm.dirty_background_bytes = 8388608
vm.dirty_bytes = 33554432
kernel.panic = 10
EOF
rm -f "$M/etc/systemd/system/multi-user.target.wants/sshd.service"
rm -f "$M/etc/systemd/system/display-manager.service"

echo "== Entering the aarch64 rootfs"
mount --bind /dev "$M/dev"
mount -t proc proc "$M/proc"
mount -t sysfs sys "$M/sys"
if [[ -L "$M/etc/resolv.conf" ]]; then
  RESOLV_WAS_SYMLINK=1
  RESOLV_TARGET="$(readlink "$M/etc/resolv.conf")"
fi
rm -f "$M/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$M/etc/resolv.conf"

chroot "$M" /bin/bash -euo pipefail <<'GUEST'
echo "== Removing the stale lock left by the panic"
rm -f /var/lib/pacman/db.lck
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinuxarm >/dev/null 2>&1 || true

# Hooks that need a live systemd or a kernel build are useless in a chroot, and
# the desktop-cache hooks take hours under emulation. Rebuild those natively
# on the device instead.
mkdir -p /etc/pacman.d/hooks
masked=()
for h in /usr/share/libalpm/hooks/*.hook; do
  b="$(basename "$h")"
  case "$b" in
    30-systemd-*|90-mkinitcpio-*|60-mkinitcpio-*|71-dracut-*|\
    update-mime-database*|update-desktop-database*|gtk-update-icon-cache*|glib-compile-schemas*)
      ln -sfn /dev/null "/etc/pacman.d/hooks/$b"; masked+=("$b") ;;
  esac
done
echo "   masked ${#masked[@]} slow/irrelevant hooks"

if pacman -Syu --noconfirm --ignore linux-aarch64,linux-aarch64-headers; then
  echo "   transaction completed"
else
  echo "[!] pacman returned non-zero; reinstalling the console stack"
  pacman -S --needed --noconfirm cage foot seatd wlroots || true
fi

for h in "${masked[@]}"; do rm -f "/etc/pacman.d/hooks/$h"; done
rmdir /etc/pacman.d/hooks 2>/dev/null || true
ldconfig
GUEST

sync
echo
echo "[+] Repaired: $M"
echo "    On the first boot, rebuild the caches natively (fast):"
echo "      sudo update-mime-database /usr/share/mime"
echo "      sudo glib-compile-schemas /usr/share/glib-2.0/schemas"
echo "      sudo fc-cache -f"
