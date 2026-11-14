#!/usr/bin/env bash
# XFCE + i3 + SDDM on the Tarkin stick.
#
# This is the "I want a normal login screen and a real desktop" option. It is
# the riskiest thing you can do on this machine, for one reason: there is no
# text console on this kernel. If the greeter fails to draw, the panel is black
# and there is nothing to read or type on.
#
# What is installed here:
#   sddm      login screen, X11 greeter (the Wayland one needs EGL, which this
#             machine does not have: software rendering only, WLR/pixman)
#   xfce4     default session, X11 (plus the xfce4-goodies group)
#   i3        second session in the SDDM menu, in case XFCE misbehaves.
#             XFCE is remembered as the default (~/.dmrc), i3 is one click away
#             in the session menu.
#
# Run it as `alarm`, not root:
#     bash ~/install-xfce.sh
#     sudo reboot
#
# `--console dm` installs all of this during the USB install. This script is
# therefore the repair path (or the way to add the desktop later, from the
# tarkin-console terminal). It is the same configuration code either way.
#
# Undo (from ChromeOS, stick mounted at /mnt/alarm):
#     sudo rm -f /mnt/alarm/etc/systemd/system/display-manager.service
#     sudo ln -sfn /etc/systemd/system/tarkin-console.service \
#       /mnt/alarm/etc/systemd/system/multi-user.target.wants/tarkin-console.service
#     echo graphical | sudo tee /mnt/alarm/etc/tarkin/console-mode
set -euo pipefail
die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }
warn() { echo "[!] $*" >&2; }

CONFIGS_ONLY=0
case "${1:-}" in
  "") ;;
  --configs-only) CONFIGS_ONLY=1 ;;
  -h|--help) echo "Usage: bash ~/install-xfce.sh [--configs-only]"; exit 0 ;;
  *) die "Unknown option: $1 (use no argument or --configs-only)" ;;
esac
if (( ! CONFIGS_ONLY )); then
  [[ $EUID -ne 0 ]] || die "Run it as the normal user (alarm), not as root. sudo is used where needed."
fi
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
ETC="${TARKIN_ETC:-/etc}"     # override only for tests (--configs-only)

backup() { [[ -e "$1" ]] && cp -a "$1" "$1.bak.$(date +%s)" || true; }
put() {
  mkdir -p "$(dirname "$1")"; backup "$1"; cat > "$1"; echo "   wrote $1"
}

if (( ! CONFIGS_ONLY )); then
  command -v pacman >/dev/null || die "pacman not found: this must run inside the Arch system."
  sudo -v || die "sudo needs your password (alarm: default password alarm unless you changed it)."
  getent hosts mirror.archlinuxarm.org >/dev/null \
    || die "No network (cannot resolve mirror.archlinuxarm.org). Connect first: sudo tarkin-wifi \"NetworkName\"."

  # Same protection as install-desktop.sh: this is a USB rootfs and a slow flush
  # must never panic the kernel in the middle of a transaction.
  info "Throttling writeback and disabling panic-on-hung-task..."
  sudo sysctl -w kernel.hung_task_panic=0 >/dev/null 2>&1 || warn "could not set kernel.hung_task_panic"
  sudo sysctl -w vm.dirty_background_bytes=8388608 >/dev/null 2>&1 || true
  sudo sysctl -w vm.dirty_bytes=33554432 >/dev/null 2>&1 || true

  avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  (( avail_kb >= 4 * 1048576 )) \
    || die "Only $((avail_kb / 1024)) MiB free on /: XFCE + Xorg + SDDM need about 4 GiB. Free space or use a bigger stick."

  if [[ -e /etc/systemd/system/display-manager.service ]] \
     && ! readlink -f /etc/systemd/system/display-manager.service | grep -q '/sddm.service$'; then
    warn "another display manager is enabled: $(readlink -f /etc/systemd/system/display-manager.service)"
    warn "disable it first: sudo systemctl disable --now <that-service>"
  fi

  # Input: the Elan trackpad must bind to hid-multitouch, X11 then uses libinput.
  printf 'i2c-hid\nhid-multitouch\n' | sudo tee /etc/modules-load.d/tarkin-input.conf >/dev/null
  sudo modprobe i2c-hid 2>/dev/null || true
  sudo modprobe hid-multitouch 2>/dev/null || true

  info "Installing Xorg, SDDM, XFCE and i3 (NOT a full -Syu: see scripts/upgrade-stick.sh)..."
  PKGS=(xorg-server xorg-xinit xorg-xauth xf86-input-libinput mesa sddm \
        i3-wm i3status i3lock dmenu xterm)
  for p in "${PKGS[@]}"; do
    if pacman -Si "$p" >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm --ignore linux-aarch64,linux-aarch64-headers "$p" \
        || warn "Could not install $p (skipped)."
    else
      warn "$p is not available for this architecture (skipped)."
    fi
  done
  if pacman -Sgq xfce4 >/dev/null 2>&1; then
    info "Installing the xfce4 group..."
    if sudo pacman -S --needed --noconfirm --ignore linux-aarch64,linux-aarch64-headers xfce4; then
      if pacman -Sgq xfce4-goodies >/dev/null 2>&1; then
        info "Installing the xfce4-goodies group (panel plugins, taskmanager, screenshooter, ...)..."
        sudo pacman -S --needed --noconfirm --ignore linux-aarch64,linux-aarch64-headers xfce4-goodies \
          || warn "Could not install the xfce4-goodies group (XFCE itself is fine)."
      else
        warn "the xfce4-goodies group is not available; skipping it."
      fi
    else
      warn "Could not install the xfce4 group."
    fi
  else
    warn "the xfce4 group is not available; XFCE will be missing (i3 still works)."
  fi

  for c in Xorg sddm xfce4-session i3; do
    command -v "$c" >/dev/null || warn "$c not found on PATH after the install"
  done
  command -v Xorg >/dev/null || warn "Xorg is missing: the greeter cannot start."
  command -v sddm >/dev/null || die "sddm is missing: without it this install boots to tarkin-console only."
fi

# ---- SDDM configuration ----------------------------------------------------
# priv: sudo for the real /etc, plain for a test tree (TARKIN_ETC=...)
priv() { if [[ "$ETC" == /etc ]]; then sudo "$@"; else "$@"; fi; }

write_sddm_conf() {
  priv mkdir -p "$ETC/sddm.conf.d"
  priv tee "$ETC/sddm.conf.d/10-tarkin.conf" >/dev/null <<'EOF'
# Tarkin CM1406: software rendering only (no working EGL), so the greeter must
# be X11. The Wayland greeter needs a GL stack this machine does not have.
#
# This only selects the *greeter* backend (the login screen). It does not force
# user sessions to X11: SDDM still starts whatever you pick, including sessions
# from /usr/share/wayland-sessions (SessionDir under [Wayland]).
[General]
DisplayServer=x11
Numlock=none
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Users]
MinimumUid=1000
MaximumUid=60513
HideUsers=root

[X11]
SessionDir=/usr/local/share/xsessions,/usr/share/xsessions
EOF
  echo "   wrote $ETC/sddm.conf.d/10-tarkin.conf"
}

write_i3_conf() {
  mkdir -p "$CFG/i3"
  [[ -f "$CFG/i3/config" ]] && { echo "   keeping the existing $CFG/i3/config"; return; }
  if [[ -f /etc/i3/config ]]; then
    cp /etc/i3/config "$CFG/i3/config"; echo "   copied /etc/i3/config to $CFG/i3/config"; return
  fi
  put "$CFG/i3/config" <<'EOF'
# Tarkin fallback session (i3)
set $mod Mod4
font pango:monospace 10
bindsym $mod+Return exec xterm
bindsym $mod+d exec dmenu_run
bindsym $mod+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-msg exit
bindsym $mod+Left focus left
bindsym $mod+Right focus right
bindsym $mod+Up focus up
bindsym $mod+Down focus down
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Right move right
bindsym $mod+f fullscreen toggle
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bar {
    status_command i3status
}
EOF
}

if (( CONFIGS_ONLY )); then
  if [[ "$ETC" == /etc ]]; then
    info "Would write /etc/sddm.conf.d/10-tarkin.conf (needs sudo), ~/.dmrc, ~/.config/i3/config"
  else
    info "Test mode: writing under $ETC and $HOME"
    write_sddm_conf
    put "$HOME/.dmrc" <<'EOF'
[Desktop]
Session=xfce
EOF
  fi
  write_i3_conf
  exit 0
fi

info "Writing the SDDM configuration..."
write_sddm_conf

info "Setting XFCE as the default session (i3 stays in the SDDM menu)..."
put "$HOME/.dmrc" <<'EOF'
[Desktop]
Session=xfce
EOF

info "Writing the i3 session config (if there is none yet)..."
write_i3_conf

info "Handing the console to SDDM..."
sudo systemctl enable sddm >/dev/null 2>&1 || warn "could not enable sddm"
# tarkin-console must not compete for the DRM node; dm-fallback starts it only
# when no display manager is running.
sudo systemctl disable tarkin-console >/dev/null 2>&1 || true
sudo systemctl enable tarkin-dm-fallback >/dev/null 2>&1 || true
echo dm | sudo tee /etc/tarkin/console-mode >/dev/null
[[ -e /etc/systemd/system/display-manager.service ]] \
  || warn "display-manager.service is missing: 'systemctl enable sddm' did not create the alias, the greeter will not start at boot"

# Do not start SDDM from inside tarkin-console: cage owns the DRM node and the
# result is two things drawing on the panel. A reboot is the honest hand-over.
cat <<'EOF'

==========================================================
[+] XFCE + i3 + SDDM installed.

Reboot:   sudo reboot

You should get the SDDM greeter (X11), with "Xfce Session" and "i3" in the
session menu; XFCE is the default.

If the panel stays black:
  - wait ~60 s: tarkin-dm-fallback restarts tarkin-console when no display
    manager is running, so a failed greeter usually gives the terminal back;
  - otherwise power-cycle, boot ChromeOS (Ctrl+D), mount the stick and:
      sudo rm -f <mnt>/etc/systemd/system/display-manager.service
      sudo ln -sfn /etc/systemd/system/tarkin-console.service \
        <mnt>/etc/systemd/system/multi-user.target.wants/tarkin-console.service
      echo graphical | sudo tee <mnt>/etc/tarkin/console-mode
  - the greeter log is  journalctl -u sddm -b  and  ~/.local/share/sddm/*.log
==========================================================
EOF
