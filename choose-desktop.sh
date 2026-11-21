#!/bin/bash
set -uo pipefail

ROOT="${TARKIN_ROOT:-}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VITRUM_SHA256=ed9af4fd88c1aacfaafadbd0a5f178efe944066b1d9b39fd9090bfd76607ea0a
VITRUM_NAME=install-vitrum-plus-niri-v10.sh
SHELL_PACKAGES=(quickshell qt6-declarative)
CONSOLE_ENV="$ROOT/etc/tarkin/console.env"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tarkin-desktop"
SUDO="${TARKIN_SUDO:-sudo}"

say() { echo "[*] $*"; }
ok() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[-] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: tarkin-desktop                 menu: pick the desktop started at boot
       tarkin-desktop --niri          niri (GPU, EGL fix, Super+Shift+S) + Vitrum Plus v10
       tarkin-desktop --hyprland      Hyprland with the base config
       tarkin-desktop --none          no desktop at boot, terminal only
       tarkin-desktop --undo-niri     remove Vitrum Plus and niri, back to no desktop
       tarkin-desktop --status        show what starts at boot

  --yes        do not ask (no reboot question either)
  --no-reboot  do not offer to restart at the end

Run it as alarm, without sudo (it asks for the password when needed).
Run it again any time to switch. Changes apply at the next boot.
EOF
}

find_script() {
  local name="$1" d
  for d in "$HOME" "$HERE" "$HERE/scripts" "$ROOT/usr/local/share/tarkin"; do
    if [[ -f "$d/$name" ]]; then printf '%s\n' "$d/$name"; return 0; fi
  done
  return 1
}

session() {
  sed -n 's/^TARKIN_SESSION=//p' "$CONSOLE_ENV" 2>/dev/null | tail -1 | tr -d '"'
}

base_ready() {
  [[ -x "$ROOT/usr/local/bin/hyprland-mali" ]] && command -v Hyprland >/dev/null 2>&1
}

vitrum_root() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cm1406-vitrum-plus"
}

next_wm() {
  if command -v tarkin-wm >/dev/null 2>&1; then
    tarkin-wm status 2>/dev/null | sed -n 's/^Next boot: //p' | head -1
  else
    echo hyprland
  fi
}

show_status() {
  local s wm
  s="$(session)"
  wm="$(next_wm)"
  if [[ -f "$ROOT/var/lib/tarkin/firstboot.pending" ]]; then
    echo "First boot : still running (tail -f /var/log/tarkin-firstboot.log)"
  fi
  if [[ "$s" == desktop ]]; then
    if [[ "$wm" == niri ]]; then
      if [[ -e "$(vitrum_root)" ]]; then echo "At boot    : niri + Vitrum Plus"; else echo "At boot    : niri"; fi
    else
      echo "At boot    : Hyprland"
    fi
  else
    echo "At boot    : terminal only, no desktop (choose one: tarkin-desktop)"
  fi
  if base_ready; then echo "Base       : installed (GPU stack, sound, Hyprland)"; else echo "Base       : not installed (bash ~/install-hyprland.sh --no-autostart)"; fi
  if command -v niri >/dev/null 2>&1; then echo "niri       : installed"; else echo "niri       : not installed"; fi
  if [[ -e "$(vitrum_root)" ]]; then echo "Vitrum Plus: installed ($(vitrum_root))"; else echo "Vitrum Plus: not installed"; fi
}

check_ready() {
  [[ $EUID -ne 0 ]] || die "Run it as alarm, without sudo: tarkin-desktop"
  if (( ! FIRSTBOOT )) && [[ -f "$ROOT/var/lib/tarkin/firstboot.pending" ]]; then
    die "The first-boot setup is still running. Wait for it (tail -f /var/log/tarkin-firstboot.log), then run tarkin-desktop again."
  fi
}

ensure_base() {
  base_ready && return 0
  local hypr
  hypr="$(find_script install-hyprland.sh)" || die "install-hyprland.sh not found in $HOME. Copy it from the release, then run tarkin-desktop again."
  say "Installing the base first (GPU stack, sound, Hyprland files): bash $hypr --no-autostart"
  bash "$hypr" --no-autostart || die "install-hyprland.sh failed; nothing else was changed."
}

set_boot() {
  local want="$1"
  (( FIRSTBOOT )) && return 0
  if [[ "$want" == desktop && "$(session)" == desktop ]]; then return 0; fi
  if [[ "$want" == terminal && "$(session)" != desktop ]]; then return 0; fi
  if [[ "$want" == desktop ]]; then
    "$SUDO" tarkin-display hyprland || die "sudo tarkin-display hyprland failed; the boot is unchanged."
  else
    "$SUDO" tarkin-display terminal || die "sudo tarkin-display terminal failed; the boot is unchanged."
  fi
}

vitrum_script() {
  local v
  v="$(find_script "$VITRUM_NAME")" || die "$VITRUM_NAME not found in $HOME. Copy it from the release (scripts/$VITRUM_NAME)."
  [[ "$(sha256sum "$v" | cut -d ' ' -f1)" == "$VITRUM_SHA256" ]] || die "$v is not the expected Vitrum Plus v10 (SHA-256 differs); nothing changed."
  printf '%s\n' "$v"
}

install_shell_packages() {
  local p missing=()
  for p in "${SHELL_PACKAGES[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  (( ${#missing[@]} )) || return 0
  say "Installing ${missing[*]} for Vitrum Plus"
  "$SUDO" pacman -S --needed --noconfirm "${missing[@]}" || die "pacman failed (try sudo tarkin-update first). Nothing else was changed."
  mkdir -p "$STATE_DIR"
  printf '%s\n' "${missing[@]}" >> "$STATE_DIR/packages"
}

do_niri() {
  local niri_script v
  check_ready
  v="$(vitrum_script)" || exit 1
  niri_script="$(find_script install-niri.sh)" || die "install-niri.sh not found in $HOME. Copy it from the release."
  ensure_base
  say "niri with the EGL fix and Super+Shift+S: bash $niri_script"
  bash "$niri_script" || die "install-niri.sh failed. Undo: bash $niri_script --remove"
  install_shell_packages
  if [[ -e "$(vitrum_root)" ]]; then
    say "Vitrum Plus is installed: bash $v --upgrade --apply"
    bash "$v" --upgrade --apply || die "Vitrum Plus upgrade failed; the old version stays."
  else
    local extra=() plan
    plan="$(bash "$v" 2>&1)"
    [[ "$plan" != *--replace-dock* ]] || extra=(--replace-dock)
    say "Vitrum Plus v10: bash $v --apply ${extra[*]:-}"
    bash "$v" --apply ${extra[@]+"${extra[@]}"} || die "Vitrum Plus install failed; niri stays without it. Retry: tarkin-desktop --niri"
  fi
  say "Brightness and Wi-Fi from the Control Center: bash $v --system-access --apply"
  bash "$v" --system-access --apply || warn "--system-access failed; the sliders may ask for it later."
  set_boot desktop
  "$SUDO" tarkin-wm niri || die "sudo tarkin-wm niri failed."
  ok "niri + Vitrum Plus start at the next boot."
  echo "    Undo: tarkin-desktop --undo-niri   (or only switch: tarkin-desktop --hyprland)"
}

do_hyprland() {
  check_ready
  ensure_base
  set_boot desktop
  if command -v tarkin-wm >/dev/null 2>&1; then
    "$SUDO" tarkin-wm hyprland || die "sudo tarkin-wm hyprland failed."
  fi
  ok "Hyprland (base config) starts at the next boot."
  echo "    Undo: tarkin-desktop --none   (terminal only)"
}

do_none() {
  check_ready
  set_boot terminal
  ok "No desktop at the next boot: the terminal starts. Choose one later: tarkin-desktop"
}

do_undo_niri() {
  local niri_script v
  check_ready
  if [[ -e "$(vitrum_root)" ]]; then
    v="$(vitrum_script)" || exit 1
    bash "$v" --no-system-access --apply || warn "--no-system-access failed; see the lines above."
    bash "$v" --rollback --apply || die "Vitrum Plus rollback failed; niri was left as is."
  fi
  if command -v tarkin-wm >/dev/null 2>&1; then
    "$SUDO" tarkin-wm hyprland || warn "sudo tarkin-wm hyprland failed."
  fi
  if command -v niri >/dev/null 2>&1 || [[ -e "$ROOT/usr/local/bin/tarkin-wm" ]]; then
    niri_script="$(find_script install-niri.sh)" || die "install-niri.sh not found in $HOME."
    bash "$niri_script" --remove || die "install-niri.sh --remove failed."
  fi
  set_boot terminal
  ok "Vitrum Plus and niri are removed; no desktop at the next boot."
  if [[ -s "$STATE_DIR/packages" ]]; then
    echo "    Packages added by tarkin-desktop (kept): sudo pacman -Rs $(sort -u "$STATE_DIR/packages" | tr '\n' ' ')"
  fi
}

offer_reboot() {
  (( REBOOT && ! YES && ! FIRSTBOOT )) || return 0
  [[ -t 0 ]] || return 0
  local ans
  read -r -p "Restart now to start it? [Y/n] " ans
  case "${ans:-y}" in
    y|Y|yes|o|O|oui) "$SUDO" systemctl reboot ;;
    *) echo "Restart later with: sudo reboot" ;;
  esac
}

menu() {
  local ans
  show_status
  echo
  echo "Which desktop should start at boot?"
  echo "  1) niri + Vitrum Plus (macOS look, glass dock)"
  echo "  2) Hyprland, base config"
  echo "  3) none, terminal only"
  echo "  q) quit, change nothing"
  read -r -p "Choice [1/2/3/q]: " ans
  case "$ans" in
    1) MODE=niri ;;
    2) MODE=hyprland ;;
    3) MODE=none ;;
    *) echo "Nothing changed."; exit 0 ;;
  esac
}

MODE=""
YES=0
REBOOT=1
FIRSTBOOT=0
for arg in "$@"; do
  case "$arg" in
    --niri) MODE=niri ;;
    --hyprland) MODE=hyprland ;;
    --none) MODE=none ;;
    --undo-niri) MODE=undo-niri ;;
    --status) MODE=status ;;
    --yes) YES=1 ;;
    --no-reboot) REBOOT=0 ;;
    --firstboot) FIRSTBOOT=1; YES=1; REBOOT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $arg" ;;
  esac
done

if [[ -z "$MODE" ]]; then
  [[ -t 0 ]] || { usage >&2; die "No choice given. Use --niri, --hyprland, --none or --status."; }
  menu
fi

case "$MODE" in
  status) show_status; exit 0 ;;
  niri) do_niri ;;
  hyprland) do_hyprland ;;
  none) do_none ;;
  undo-niri) do_undo_niri ;;
esac
offer_reboot
exit 0
