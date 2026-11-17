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

cat <<'WARN'
[i] Two rules for this stick:
    - the kernel packages of Arch Linux ARM are NOT used here; the real kernel
      is the signed ChromeOS kernel on /dev/sdX1. They are ignored below.
    - one display owner at a time. Since v1.39 install-hyprland.sh leaves GDM
      disabled and tarkin-console enabled (Hyprland starts by itself); with
      --with-gdm it is the other way round. Enabling both on the same boot
      gives a black screen. Check with: systemctl is-enabled gdm tarkin-console
WARN

info "Upgrading (this can take 20-60 minutes on USB; slow is fine, a panic is not)..."
pacman -Syu --noconfirm --ignore linux-aarch64,linux-aarch64-headers

info "Flushing..."
sync
info "Done. Rebooting is safe."
