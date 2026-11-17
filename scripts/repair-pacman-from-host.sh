#!/bin/bash
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

if findmnt -rno OPTIONS -T "$M" 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
  echo "[-] $M is mounted noexec (ChromeOS mounts removable media that way), so nothing can run inside it."
  echo "    Mount the stick yourself and pass the mountpoint, e.g.:"
  echo "      sudo mkdir -p /usr/local/alarm && sudo mount /dev/sda2 /usr/local/alarm"
  echo "      sudo bash scripts/repair-pacman-from-host.sh /usr/local/alarm"
  exit 1
fi

if [[ "$(uname -m)" == aarch64 ]]; then
  echo "== Host is aarch64 (ChromeOS on the Chromebook): the rootfs runs natively, no qemu needed"
else
  echo "== qemu-user-static + binfmt"
  if ! command -v qemu-aarch64-static >/dev/null && ! command -v qemu-aarch64 >/dev/null; then
    pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
  fi
  systemctl restart systemd-binfmt 2>/dev/null || true
  compgen -G '/proc/sys/fs/binfmt_misc/*aarch64*' >/dev/null \
    || { echo "[-] binfmt handler for aarch64 did not register."; exit 1; }
fi

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
if [[ -L "$M/etc/systemd/system/display-manager.service" ]]; then
  dm_target="$(readlink -f "$M/etc/systemd/system/display-manager.service" || true)"
  if [[ -n "$dm_target" && -e "$dm_target" ]]; then
    echo "== Keeping the display manager: $(basename "$dm_target")"
  else
    rm -f "$M/etc/systemd/system/display-manager.service"
    echo "== Removed a dangling display-manager.service symlink"
  fi
fi

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

mkdir -p /etc/pacman.d/hooks
masked=()
for h in /usr/share/libalpm/hooks/*.hook; do
  b="$(basename "$h")"
  case "$b" in
    30-systemd-sysusers.hook) ;;  # keep: new packages need their users/groups (tarkin-console needs its groups)
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
