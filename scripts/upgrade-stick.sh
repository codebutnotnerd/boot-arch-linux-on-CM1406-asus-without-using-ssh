#!/bin/bash
set -euo pipefail
die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash scripts/upgrade-stick.sh"
command -v pacman >/dev/null || die "pacman not found: this must run inside the Arch system."

root_src="$(findmnt -no SOURCE /)"
case "$root_src" in
  /dev/sd*|/dev/mmcblk*) ;;
  *) info "root is $root_src (not a plain device); continuing" ;;
esac
[[ "$root_src" == /dev/mmcblk* ]] && die "$root_src is the internal eMMC, not the USB stick. Refusing."

avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
(( avail_kb >= 2 * 1048576 )) \
  || die "Only $((avail_kb / 1024)) MiB free on /: an upgrade needs ~2 GiB of headroom."

info "Keeping the system from panicking if the stick is slow..."
sysctl -w kernel.hung_task_panic=0 >/dev/null 2>&1 || info "could not set kernel.hung_task_panic"
sysctl -w vm.dirty_background_bytes=8388608 >/dev/null 2>&1 || true
sysctl -w vm.dirty_bytes=33554432 >/dev/null 2>&1 || true
sysctl kernel.hung_task_panic vm.dirty_bytes vm.dirty_background_bytes 2>/dev/null || true

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
updater=""
for candidate in /usr/local/bin/tarkin-update "$here/../rootfs/usr/local/bin/tarkin-update"; do
  if [[ -f "$candidate" ]]; then updater="$candidate"; break; fi
done

cat <<'WARN'
[i] Two rules for this stick:
    - the kernel packages of Arch Linux ARM are NOT used here; the real kernel
      is the signed ChromeOS kernel on /dev/sdX1. They are kept back below.
    - one display owner at a time. Change it only with sudo tarkin-display
      hyprland|xfce|terminal (v1.40, takes effect at the next boot). Never
      enable two display managers or a display manager plus tarkin-console.
WARN

if [[ -n "$updater" ]]; then
  info "Upgrading with $updater (20-60 minutes on USB; review the transaction before answering)..."
  bash "$updater"
else
  info "tarkin-update not found (stick made before v1.40): legacy upgrade (20-60 minutes on USB)..."
  pacman -Syu --noconfirm --ignore linux-aarch64,linux-aarch64-headers
fi

info "Flushing..."
sync
info "Done. Rebooting is safe."
