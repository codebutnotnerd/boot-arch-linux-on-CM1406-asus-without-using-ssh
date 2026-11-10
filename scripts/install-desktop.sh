#!/usr/bin/env bash
set -euo pipefail
die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }
warn() { echo "[!] $*" >&2; }

CONFIGS_ONLY=0
[[ "${1:-}" == "--configs-only" ]] && CONFIGS_ONLY=1
[[ $EUID -ne 0 ]] || die "Run it as the normal user (alarm), not as root. sudo is used where needed."
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

backup() { [[ -e "$1" ]] && cp -a "$1" "$1.bak.$(date +%s)" || true; }
put() {
  mkdir -p "$(dirname "$1")"; backup "$1"; cat > "$1"; echo "   wrote $1"
}

if (( ! CONFIGS_ONLY )); then
  command -v pacman >/dev/null || die "pacman not found: this must run inside the Arch system."
  sudo -v || die "sudo needs your password (the account alarm: default password alarm unless you changed it)."
  getent hosts mirror.archlinuxarm.org >/dev/null || die "No network (cannot resolve mirror.archlinuxarm.org). Connect first: sudo tarkin-wifi \"NetworkName\"."

  info "Updating the system and installing the desktop (this takes a few minutes)..."
  sudo pacman -Syu --noconfirm
  PKGS=(labwc waybar fuzzel swaybg mako foot papirus-icon-theme adw-gtk-theme inter-font noto-fonts noto-fonts-emoji pcmanfm-gtk3 wlr-randr)
  for p in "${PKGS[@]}"; do
    if pacman -Si "$p" >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm "$p" || warn "Could not install $p (skipped)."
    else
      warn "$p is not available for this architecture (skipped)."
    fi
  done
  for c in labwc waybar fuzzel; do command -v "$c" >/dev/null || die "$c is missing: the desktop cannot work. Check the pacman messages above."; done

  info "Installing the session switcher..."
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/console" <<'TARKIN_CONSOLE_EOF'
#!/bin/bash
set -u
cd "$HOME"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export LIBSEAT_BACKEND=seatd SEATD_VTBOUND=0
export LANG=C.UTF-8
export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1
card=/dev/dri/card0
for c in /sys/class/drm/card[0-9]; do
  if [[ "$(readlink -f "$c/device/driver" 2>/dev/null)" == *mediatek* ]]; then card="/dev/dri/$(basename "$c")"; break; fi
done
export WLR_DRM_DEVICES="$card"
unset WAYLAND_DISPLAY DISPLAY
[[ -f /etc/tarkin/console.env ]] && . /etc/tarkin/console.env
export XKB_DEFAULT_LAYOUT="${XKB_DEFAULT_LAYOUT:-us}"
session="${TARKIN_SESSION:-terminal}"
echo "tarkin-console: display $card, keyboard layout $XKB_DEFAULT_LAYOUT, session $session"

if [[ "$session" == desktop ]] && command -v labwc >/dev/null 2>&1; then
  start=$SECONDS
  export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=labwc:wlroots
  labwc
  rc=$?
  if (( SECONDS - start < 15 )); then
    echo "tarkin-console: labwc exited after $((SECONDS - start))s (code $rc); falling back to the terminal." >&2
    exec cage -- foot
  fi
  exit "$rc"
fi
exec cage -- foot
TARKIN_CONSOLE_EOF
  cat > "$tmp/tarkin-session" <<'TARKIN_SESSION_EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in desktop|terminal) ;; *) echo "Usage: sudo tarkin-session desktop|terminal" >&2; exit 1 ;; esac
[[ $EUID -eq 0 ]] || { echo "Run it with sudo." >&2; exit 1; }
f=/etc/tarkin/console.env
mkdir -p /etc/tarkin
touch "$f"
if grep -q '^TARKIN_SESSION=' "$f"; then
  sed -i "s/^TARKIN_SESSION=.*/TARKIN_SESSION=$1/" "$f"
else
  echo "TARKIN_SESSION=$1" >> "$f"
fi
echo "Session set to: $1. Restarting the display now (this window will close)..."
systemctl --no-block restart tarkin-console.service
TARKIN_SESSION_EOF
  sudo install -D -m 755 "$tmp/console" /usr/local/libexec/tarkin/console
  sudo install -D -m 755 "$tmp/tarkin-session" /usr/local/bin/tarkin-session
fi

info "Writing the desktop configuration in $CFG ..."

put "$CFG/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <cornerRadius>8</cornerRadius>
    <font place="ActiveWindow"><name>Inter</name><size>11</size></font>
    <font place="InactiveWindow"><name>Inter</name><size>11</size></font>
    <font place="MenuItem"><name>Inter</name><size>12</size></font>
  </theme>
  <keyboard>
    <default />
    <keybind key="W-d"><action name="Execute"><command>fuzzel</command></action></keybind>
    <keybind key="W-Return"><action name="Execute"><command>foot</command></action></keybind>
    <keybind key="W-e"><action name="Execute"><command>pcmanfm</command></action></keybind>
    <keybind key="W-q"><action name="Close" /></keybind>
  </keyboard>
</labwc_config>
EOF

put "$CFG/labwc/themerc-override" <<'EOF'
border.width: 1
padding.height: 6
window.active.title.bg.color: #202020
window.inactive.title.bg.color: #2b2b2b
window.active.label.text.color: #ffffff
window.inactive.label.text.color: #9a9a9a
window.active.border.color: #3a3a3a
window.inactive.border.color: #2b2b2b
window.active.button.unpressed.image.color: #ffffff
window.inactive.button.unpressed.image.color: #9a9a9a
menu.items.bg.color: #2b2b2b
menu.items.text.color: #ffffff
menu.items.active.bg.color: #0078d4
menu.items.active.text.color: #ffffff
EOF

put "$CFG/labwc/autostart" <<'EOF'
swaybg -c '#0b3d91' >/dev/null 2>&1 &
waybar >/dev/null 2>&1 &
mako >/dev/null 2>&1 &
EOF
chmod +x "$CFG/labwc/autostart"

put "$CFG/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "bottom",
  "height": 48,
  "spacing": 6,
  "modules-left": [],
  "modules-center": ["custom/start", "wlr/taskbar"],
  "modules-right": ["network", "battery", "clock"],
  "custom/start": { "format": "⊞", "tooltip": false, "on-click": "fuzzel" },
  "wlr/taskbar": {
    "format": "{icon}",
    "icon-size": 26,
    "tooltip-format": "{title}",
    "on-click": "activate",
    "on-click-middle": "close"
  },
  "network": {
    "format-wifi": "Wi-Fi {signalStrength}%",
    "format-ethernet": "Ethernet",
    "format-disconnected": "Hors ligne",
    "tooltip-format-wifi": "{essid}"
  },
  "battery": {
    "format": "{capacity}%",
    "format-charging": "{capacity}% +",
    "states": { "warning": 25, "critical": 10 }
  },
  "clock": { "format": "{:%H:%M}  {:%d/%m/%Y}", "tooltip": false }
}
EOF

put "$CFG/waybar/style.css" <<'EOF'
* { font-family: "Inter", "Noto Sans", sans-serif; font-size: 14px; border: none; border-radius: 0; min-height: 0; }
window#waybar { background: rgba(32, 32, 32, 0.92); color: #ffffff; border-top: 1px solid rgba(255, 255, 255, 0.08); }
#custom-start { font-size: 26px; padding: 0 14px; margin: 6px 4px; border-radius: 8px; color: #4cc2ff; }
#custom-start:hover { background: rgba(255, 255, 255, 0.10); }
#taskbar button { padding: 0 10px; margin: 6px 2px; border-radius: 8px; background: transparent; }
#taskbar button:hover { background: rgba(255, 255, 255, 0.10); }
#taskbar button.active { background: rgba(255, 255, 255, 0.15); border-bottom: 3px solid #4cc2ff; }
#network, #battery, #clock { padding: 0 12px; margin: 6px 2px; border-radius: 8px; }
#network:hover, #battery:hover, #clock:hover { background: rgba(255, 255, 255, 0.10); }
#battery.warning { color: #ffb900; }
#battery.critical { color: #ff5555; }
EOF

put "$CFG/fuzzel/fuzzel.ini" <<'EOF'
[main]
font=Inter:size=14
terminal=foot
prompt="  "
icon-theme=Papirus-Dark
width=36
lines=10
anchor=bottom
y-margin=64
horizontal-pad=24
vertical-pad=18
inner-pad=10

[colors]
background=202020f2
text=ffffffff
match=4cc2ffff
selection=0078d4ff
selection-text=ffffffff
border=3a3a3aff

[border]
width=1
radius=12
EOF

put "$CFG/mako/config" <<'EOF'
background-color=#202020f2
text-color=#ffffff
border-color=#3a3a3a
border-radius=10
font=Inter 12
default-timeout=5000
EOF

put "$CFG/foot/foot.ini" <<'EOF'
font=monospace:size=13
[colors]
alpha=0.95
background=202020
foreground=e6e6e6
EOF

for v in gtk-3.0 gtk-4.0; do
put "$CFG/$v/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Inter 11
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF
done

echo
if (( CONFIGS_ONLY )); then
  echo "[+] Configuration written. Nothing else was changed."
else
  echo "[+] Desktop installed. To start it on the built-in display, now and at every boot:"
  echo "      sudo tarkin-session desktop"
  echo "    The screen restarts in a few seconds. Keys: Super+d start menu, Super+Enter terminal,"
  echo "    Super+e files, Super+q close window. Back to the terminal: sudo tarkin-session terminal"
  echo "    (the start button on the taskbar also opens the menu; run 'foot' from it for a terminal)."
fi
