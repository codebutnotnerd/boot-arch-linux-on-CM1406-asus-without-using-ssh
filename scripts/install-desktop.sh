#!/usr/bin/env bash
set -euo pipefail
die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }
warn() { echo "[!] $*" >&2; }

CONFIGS_ONLY=0
SESSION_ONLY=0
WORKER=0
LOG=/var/log/tarkin-desktop-install.log
STATUS=/var/log/tarkin-desktop-install.status
PKGS=(hyprland alsa-utils alsa-ucm-conf pipewire wireplumber pipewire-pulse libpulse python waybar fuzzel swaybg mako foot brightnessctl papirus-icon-theme adw-gtk-theme inter-font noto-fonts noto-fonts-emoji pcmanfm)
RESET_CONFIG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    "") ;;
    --configs-only) CONFIGS_ONLY=1 ;;
    --session-only) SESSION_ONLY=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --install-packages) WORKER=1 ;;
    -h|--help) echo "Usage: bash ~/install-desktop.sh [--configs-only|--session-only|--reset-config]"; exit 0 ;;
    *) die "Unknown option: $1 (use no argument, --configs-only, --session-only or --reset-config)" ;;
  esac
  shift
done

run_worker() {
  local f kv rc=0 p
  local saved=() avail=()
  [[ $EUID -eq 0 ]] || die "--install-packages is internal and must run as root."
  rm -f "$STATUS"
  echo "== $(date -u +%FT%TZ) package step started"
  if [[ -e /var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null; then
    echo "== removing a stale pacman lock"
    rm -f /var/lib/pacman/db.lck
  fi
  for f in vm/dirty_bytes vm/dirty_background_bytes vm/dirty_ratio vm/dirty_background_ratio; do
    saved+=("$f=$(cat "/proc/sys/$f")")
  done
  echo 0 > /proc/sys/kernel/hung_task_panic 2>/dev/null || true
  echo 8388608 > /proc/sys/vm/dirty_background_bytes || true
  echo 33554432 > /proc/sys/vm/dirty_bytes || true
  (
    # set -e is ignored inside a subshell tested by "||": stop explicitly on a failed upgrade,
    # otherwise the -S below would run against new databases on a half-upgraded system.
    set -e
    pacman -Syu --noconfirm --noprogressbar --ignore linux-aarch64,linux-aarch64-headers || exit $?
    for p in "${PKGS[@]}"; do
      if pacman -Si "$p" >/dev/null 2>&1; then avail+=("$p"); else echo "[!] $p is not available for this architecture (skipped)."; fi
    done
    if ! pacman -S --needed --noconfirm --noprogressbar "${avail[@]}"; then
      echo "[!] Bulk install failed, retrying package by package."
      for p in "${avail[@]}"; do
        pacman -S --needed --noconfirm --noprogressbar "$p" || echo "[!] Could not install $p (skipped)."
      done
    fi
  ) || rc=$?
  sync
  for kv in "${saved[@]}"; do
    echo "${kv#*=}" > "/proc/sys/${kv%%=*}" 2>/dev/null || true
  done
  echo "$rc" > "$STATUS"
  echo "== $(date -u +%FT%TZ) package step finished (exit $rc)"
}

if (( WORKER )); then
  run_worker
  exit 0
fi

[[ $EUID -ne 0 ]] || die "Run it as the normal user (alarm), not as root. sudo is used where needed."
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

backup() { [[ -e "$1" ]] && cp -a "$1" "$1.bak.$(date +%s)" || true; }
put() {
  mkdir -p "$(dirname "$1")"; backup "$1"; cat > "$1"; echo "   wrote $1"
}

if (( ! CONFIGS_ONLY && ! SESSION_ONLY )); then
  command -v pacman >/dev/null || die "pacman not found: this must run inside the Arch system."
  sudo -v || die "sudo needs your password (the one chosen during the install; sticks made before v1.50: alarm unless you changed it)."
  getent hosts mirror.archlinuxarm.org >/dev/null || die "No network (cannot resolve mirror.archlinuxarm.org). Connect first: sudo tarkin-wifi \"NetworkName\"."

  free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  (( free_kb >= 1572864 )) || die "Only $((free_kb / 1024)) MiB free on the root filesystem (need 1.5 GiB). Free some space with: sudo pacman -Scc"

  info "Updating the system and installing the desktop (several minutes)."
  echo "   The package step runs detached from this terminal and is logged to $LOG."
  echo "   If the screen goes black, do NOT power off: wait 15 minutes, the step keeps running."
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  sudo rm -f "$STATUS"
  sudo bash -c 'setsid bash "$0" --install-packages >>"$1" 2>&1 </dev/null &' "$script_path" "$LOG"
  tail -n 0 -F "$LOG" 2>/dev/null &
  tailpid=$!
  started=0
  waited=0
  while [[ ! -s "$STATUS" ]]; do
    sleep 2
    if pgrep -f -- '--install-packages' >/dev/null; then
      started=1
    elif (( started )); then
      break
    else
      waited=$((waited + 2))
      (( waited < 40 )) || break
    fi
  done
  kill "$tailpid" 2>/dev/null || true
  rc="$(cat "$STATUS" 2>/dev/null || echo unknown)"
  [[ "$rc" == 0 ]] || die "The package step did not finish cleanly (status: $rc). See $LOG, then run this script again."
  for c in Hyprland waybar fuzzel; do command -v "$c" >/dev/null || die "$c is missing: the desktop cannot work (is hyprland published for aarch64 in the Arch Linux ARM repositories?). See $LOG."; done
  systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 \
    || warn "Could not enable PipeWire in your session now; if there is no sound after a reboot: systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service"
  if [[ -f /etc/systemd/user/tarkin-audio.service ]]; then
    info "Enabling the sound setup (tarkin-audio.service, user unit: speakers, headphone jack switching)..."
    if [[ -e /etc/systemd/user/default.target.wants/tarkin-audio.service ]] || sudo systemctl --global enable tarkin-audio.service >/dev/null 2>&1; then
      systemctl --user --no-block restart tarkin-audio.service >/dev/null 2>&1 || true
    else
      warn "Could not enable tarkin-audio.service; run: sudo systemctl --global enable tarkin-audio.service"
    fi
  fi

fi

if (( ! CONFIGS_ONLY )); then
  [[ -x /usr/bin/Hyprland ]] || die "Hyprland is not installed."
  sudo -v || die "sudo needs your password."
  info "Installing the session switcher..."
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/console" <<'TARKIN_CONSOLE_EOF'
#!/bin/bash
set -u
cd "$HOME" || exit 1
uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/$uid"
n=0
while [[ ! -d "$XDG_RUNTIME_DIR" && $n -lt 60 ]]; do
  sleep 1; n=$((n+1))
done
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
  echo "tarkin-console: $XDG_RUNTIME_DIR missing after ${n}s (user manager not running? check linger)" >&2
  exit 1
fi
# This is a *system* service, not a logind session: export the user D-Bus so
# GTK/portal apps started from the terminal or the desktop can reach it.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export LIBSEAT_BACKEND=seatd SEATD_VTBOUND=0
export LANG=C.UTF-8
n=0
until ls /dev/dri/card[0-9] >/dev/null 2>&1 || (( n >= 20 )); do sleep 1; n=$((n+1)); done
card=/dev/dri/card0
for c in /sys/class/drm/card[0-9]; do
  [[ -e "$c" && -e "/dev/dri/$(basename "$c")" ]] || continue
  if [[ "$(readlink -f "$c/device/driver" 2>/dev/null)" == *mediatek* ]]; then card="/dev/dri/$(basename "$c")"; break; fi
done
unset WAYLAND_DISPLAY DISPLAY
[[ -f /etc/tarkin/console.env ]] && . /etc/tarkin/console.env
export XKB_DEFAULT_LAYOUT="${XKB_DEFAULT_LAYOUT:-us}"
export AQ_DRM_DEVICES="$card" XDG_SESSION_TYPE=wayland
session="${TARKIN_SESSION:-terminal}"
echo "tarkin-console: display $card, keyboard layout $XKB_DEFAULT_LAYOUT, session $session"

# The on-screen terminal (cage + foot) is wlroots. There is no working EGL for
# this display, so letting wlroots probe GLES2 stalls or fails (long black
# screen, restart loop). Pin it like the earlier working release did: pixman
# renderer, software cursor, MediaTek display node. Hyprland unsets WLR_RENDERER.
run_terminal() {
  unset LD_PRELOAD LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER_ALLOW_SOFTWARE AQ_NO_MODIFIERS
  export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 WLR_DRM_DEVICES="$card"
  exec cage -- foot
}

if [[ "$session" != desktop ]]; then
  run_terminal
fi

gpu_cmd=()
default_cmd=()
[[ -x /usr/local/bin/hyprland-mali ]] && gpu_cmd=(/usr/local/bin/hyprland-mali)
if command -v start-hyprland >/dev/null 2>&1; then
  default_cmd=(start-hyprland)
elif command -v Hyprland >/dev/null 2>&1; then
  default_cmd=(Hyprland)
fi
if (( ${#gpu_cmd[@]} == 0 && ${#default_cmd[@]} == 0 )); then
  echo "tarkin-console: session desktop requested but Hyprland is not installed (run ~/install-desktop.sh); showing the terminal." >&2
  run_terminal
fi

render="${TARKIN_HYPR_RENDER:-auto}"
case "$render" in
  gpu|default|software) ;;
  *) render=auto ;;
esac
modes=()
case "$render" in
  gpu)
    if (( ${#gpu_cmd[@]} )); then
      modes=(gpu)
    else
      echo "tarkin-console: TARKIN_HYPR_RENDER=gpu but /usr/local/bin/hyprland-mali is missing; trying the default renderer then software." >&2
      if (( ${#default_cmd[@]} )); then modes=(default software); else modes=(software); fi
    fi
    ;;
  default)
    if (( ${#default_cmd[@]} )); then
      modes=(default)
    else
      echo "tarkin-console: TARKIN_HYPR_RENDER=default but Hyprland is missing; trying software." >&2
      modes=(software)
    fi
    ;;
  software)
    modes=(software)
    ;;
  *)
    if (( ${#gpu_cmd[@]} )); then modes+=(gpu); fi
    if (( ${#default_cmd[@]} )); then modes+=(default); fi
    modes+=(software)
    ;;
esac

set_hypr_env() {
  unset LD_PRELOAD LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER WLR_RENDERER_ALLOW_SOFTWARE AQ_NO_MODIFIERS
  export XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland AQ_DRM_DEVICES="$card"
}

for mode in "${modes[@]}"; do
  set_hypr_env
  cmd=()
  case "$mode" in
    gpu)
      cmd=("${gpu_cmd[@]}")
      echo "tarkin-console: starting Hyprland on the Mali GPU (hyprland-mali)." >&2
      ;;
    default)
      cmd=("${default_cmd[@]}")
      echo "tarkin-console: starting ${cmd[0]} with the default renderer." >&2
      ;;
    software)
      cmd=("${default_cmd[@]}")
      if (( ${#cmd[@]} == 0 )); then cmd=(Hyprland); fi
      echo "tarkin-console: starting ${cmd[0]} with software rendering." >&2
      export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_LOADER_DRIVER_OVERRIDE=kms_swrast AQ_NO_MODIFIERS=1 WLR_RENDERER_ALLOW_SOFTWARE=1
      ;;
  esac
  start=$SECONDS
  "${cmd[@]}"
  rc=$?
  if (( SECONDS - start >= 15 )); then
    exit "$rc"
  fi
  echo "tarkin-console: Hyprland ($mode) exited after $((SECONDS - start))s (code $rc)." >&2
done
echo "tarkin-console: the desktop does not start; falling back to the terminal. See: sudo tarkin-diag" >&2
run_terminal
TARKIN_CONSOLE_EOF
  cat > "$tmp/tarkin-session" <<'TARKIN_SESSION_EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in desktop|terminal) ;; *) echo "Usage: sudo tarkin-session desktop|terminal" >&2; exit 1 ;; esac
[[ $EUID -eq 0 ]] || { echo "Run it with sudo." >&2; exit 1; }
if systemctl is-active --quiet gdm.service 2>/dev/null; then
  echo "GDM owns the display (install-hyprland.sh): pick the session with the gear in GDM." >&2
  echo "To use the on-screen console instead: sudo systemctl disable --now gdm && sudo systemctl enable --now tarkin-console" >&2
  exit 1
fi
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

if (( SESSION_ONLY )); then
  echo "[+] Session files updated. Now: sudo tarkin-session desktop"
  exit 0
fi

info "Writing the desktop configuration in $CFG ..."

KBLAYOUT="$(sed -n 's/^XKB_DEFAULT_LAYOUT=//p' /etc/tarkin/console.env 2>/dev/null | head -1 || true)"
KBLAYOUT="${KBLAYOUT:-us}"

write_hypr=1
if [[ -f "$CFG/hypr/hyprland.lua" && $RESET_CONFIG -eq 0 ]]; then
  if command -v Hyprland >/dev/null 2>&1; then
    if Hyprland --verify-config >/dev/null 2>&1; then
      write_hypr=0
      info "Keeping the existing $CFG/hypr/hyprland.lua (it verifies)."
    else
      warn "$CFG/hypr/hyprland.lua has errors; backing it up and writing a known-good one."
    fi
  else
    write_hypr=0
    warn "Hyprland is not installed, so $CFG/hypr/hyprland.lua cannot be verified; keeping it."
  fi
elif [[ -f "$CFG/hypr/hyprland.lua" ]]; then
  warn "--reset-config: backing up the existing config and writing a known-good one."
fi

if (( write_hypr )); then
put "$CFG/hypr/hyprland.lua" <<EOF
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "1",
})

hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 1,
        col = {
            active_border   = "rgba(4cc2ffff)",
            inactive_border = "rgba(3a3a3aff)",
        },
    },
    decoration = {
        rounding = 8,
        blur   = { enabled = false },
        shadow = { enabled = false },
    },
    animations = {
        enabled = false,
    },
    input = {
        kb_layout    = "$KBLAYOUT",
        follow_mouse = 1,
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            tap_and_drag         = true,
            clickfinger_behavior = true,
            disable_while_typing = true,
            scroll_factor        = 0.6,
        },
    },
    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
    },
    cursor = {
        no_hardware_cursors = 1,
    },
})

hl.on("hyprland.start", function()
    hl.exec_cmd("swaybg -c 0b3d91")
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
end)

local mod = "SUPER"

hl.bind(mod .. " + D",         hl.dsp.exec_cmd("fuzzel"))
hl.bind(mod .. " + Return",    hl.dsp.exec_cmd("foot"))
hl.bind(mod .. " + E",         hl.dsp.exec_cmd("pcmanfm"))
hl.bind(mod .. " + Q",         hl.dsp.window.close())
hl.bind(mod .. " + F",         hl.dsp.window.fullscreen())
hl.bind(mod .. " + V",         hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())
hl.bind(mod .. " + left",      hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right",     hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",        hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",      hl.dsp.focus({ direction = "down" }))
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%- --min-value=1"), { locked = true, repeating = true })
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true })
hl.bind("F13", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("F14", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
EOF

put "$CFG/hypr/hyprland.conf" <<EOF
monitor = , preferred, auto, 1

\$mod = SUPER

input {
    kb_layout = $KBLAYOUT
    follow_mouse = 1
    touchpad {
        natural_scroll = true
        tap-to-click = true
        tap-and-drag = true
        clickfinger_behavior = true
        disable_while_typing = true
        scroll_factor = 0.6
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 1
    col.active_border = rgba(4cc2ffff)
    col.inactive_border = rgba(3a3a3aff)
}

decoration {
    rounding = 8
    blur {
        enabled = false
    }
}

animations {
    enabled = false
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
}

cursor {
    no_hardware_cursors = true
}

exec-once = swaybg -c 0b3d91
exec-once = waybar
exec-once = mako

bind = \$mod, D, exec, fuzzel
bind = \$mod, Return, exec, foot
bind = \$mod, E, exec, pcmanfm
bind = \$mod, Q, killactive
bind = \$mod SHIFT, E, exit
bind = \$mod, F, fullscreen
bind = \$mod, V, togglefloating
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
bindm = \$mod, mouse:272, movewindow
bindm = \$mod, mouse:273, resizewindow
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%- --min-value=1
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , F13, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindel = , F14, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
EOF
if command -v Hyprland >/dev/null 2>&1 && ! Hyprland --verify-config >/dev/null 2>&1; then
  die "The generated config does not verify; Hyprland reported errors. Check $CFG/hypr/"
fi
info "Hyprland config verified: $CFG/hypr/hyprland.lua"
fi

put "$CFG/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "bottom",
  "height": 48,
  "spacing": 6,
  "modules-left": [],
  "modules-center": ["custom/start", "wlr/taskbar"],
  "modules-right": ["network", "backlight", "battery", "clock"],
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
    "format-disconnected": "Offline",
    "tooltip-format-wifi": "{essid}"
  },
  "backlight": {
    "format": "Bright {percent}%",
    "tooltip": false
  },
  "battery": {
    "format": "{capacity}%",
    "format-full": "{capacity}% full",
    "tooltip-format": "{timeTo}",
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
#network, #backlight, #battery, #clock { padding: 0 12px; margin: 6px 2px; border-radius: 8px; }
#network:hover, #backlight:hover, #battery:hover, #clock:hover { background: rgba(255, 255, 255, 0.10); }
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
[main]
font=monospace:size=13

[colors-dark]
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
  echo "    Super+e files, Super+q close window, Super+f fullscreen, Super+Shift+e quit. Back to the terminal: sudo tarkin-session terminal"
  echo "    (the start button on the taskbar also opens the menu; run 'foot' from it for a terminal)."
  echo "    Hyprland starts with software rendering. For the Mali-G57 GPU also run:"
  echo "      bash ~/install-hyprland.sh"
  echo "    It adds a \"Hyprland (Mali GPU)\" session in GDM and the console then starts it"
  echo "    automatically (fallback: default Hyprland, then software, then terminal)."
fi
