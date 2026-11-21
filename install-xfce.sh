#!/bin/bash
set -euo pipefail
die() { echo "install-xfce: $*" >&2; exit 1; }
[[ $# == 0 ]] || die "Usage: bash install-xfce.sh (no options)"
[[ $EUID -ne 0 ]] || die "Run as alarm, not with sudo: bash install-xfce.sh"
[[ "$(id -un)" == alarm ]] || die "This image uses alarm for its recovery console; run as alarm."
for cmd in sudo pacman tarkin-update tarkin-display; do
  command -v "$cmd" >/dev/null || die "$cmd is missing. Install the v1.40 tools before retrying."
done
for marker in pending failed; do
  [[ ! -e /var/lib/tarkin/firstboot.$marker ]] ||
    die "First boot is $marker. Finish/repair bash ~/install-hyprland.sh first."
done
state="$(systemctl show -p ActiveState --value tarkin-firstboot.service)" ||
  die "Cannot inspect first boot. Check systemctl status tarkin-firstboot.service."
case "$state" in active|activating|deactivating|reloading) die "First boot is running. Wait for it to finish." ;; esac
sudo -v
avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
[[ "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb >= 4 * 1048576 )) ||
  die "At least 4 GiB free on / is required; free space and retry."
echo "XFCE/SDDM X11 is experimental on CM1406. A black greeter may require ChromeOS offline recovery."
echo "Installing packages does not select SDDM. Keep the offline recovery instructions available."
for setting in kernel.hung_task_panic=0 vm.dirty_background_bytes=8388608 vm.dirty_bytes=33554432; do
  sudo sysctl -w "$setting" >/dev/null ||
    die "Cannot set USB writeback protection ($setting). No package install attempted."
done
sudo tarkin-update ||
  die "Protected full update failed. Fix the reported update error and rerun; display ownership is unchanged."
sudo pacman -S --needed --noconfirm --ignore linux-aarch64,linux-aarch64-headers \
  xorg-server xorg-xauth xf86-input-libinput sddm xfce4 cage foot ||
  die "XFCE package installation failed. Resolve pacman errors and rerun; display ownership is unchanged."
for cmd in Xorg sddm xfce4-session startxfce4; do
  command -v "$cmd" >/dev/null || die "$cmd is missing after package install; display ownership is unchanged."
done
[[ -f /usr/share/xsessions/xfce.desktop ]] ||
  die "No XFCE X11 session found; display ownership is unchanged."
grep -qx 'Exec=startxfce4' /usr/share/xsessions/xfce.desktop ||
  die "Unexpected XFCE session Exec; inspect /usr/share/xsessions/xfce.desktop. Ownership unchanged."
sudo install -d -m 755 /etc/sddm.conf.d
if [[ -e /etc/sddm.conf ]]; then
  die "/etc/sddm.conf exists and can override X11 settings. Review it manually; ownership is unchanged."
fi
for conf in /etc/sddm.conf.d/*.conf; do
  [[ "$conf" == /etc/sddm.conf.d/90-tarkin-xfce.conf || ! -f "$conf" ]] ||
    die "Existing $conf could override SDDM settings. Review it manually; ownership unchanged."
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/sddm.conf" <<'EOF'
[General]
DisplayServer=x11
[Users]
MinimumUid=1000
HideUsers=root
RememberLastUser=true
RememberLastSession=true
[X11]
SessionDir=/usr/share/xsessions
EOF
cat > "$tmp/state.conf" <<'EOF'
[Last]
User=alarm
Session=/usr/share/xsessions/xfce.desktop
EOF
sudo install -m 644 "$tmp/sddm.conf" /etc/sddm.conf.d/90-tarkin-xfce.conf
sudo install -d -m 750 -o sddm -g sddm /var/lib/sddm
if sudo test -e /var/lib/sddm/state.conf; then
  sudo cp -a /var/lib/sddm/state.conf "/var/lib/sddm/state.conf.bak.$(date +%s)"
fi
sudo install -m 600 -o sddm -g sddm "$tmp/state.conf" /var/lib/sddm/state.conf
echo "XFCE installed; display ownership UNCHANGED. Dotfiles, Mali and console.env were kept."
echo "To opt in for next boot: sudo tarkin-display xfce"
echo "Return next boot: sudo tarkin-display terminal (graphical cage + foot), or hyprland."
