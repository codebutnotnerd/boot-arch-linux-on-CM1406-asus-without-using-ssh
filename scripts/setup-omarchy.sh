#!/usr/bin/env bash
# Provision the ARM64 desktop packages without running Omarchy's upstream
# installer scripts, some of which assume x86_64 or replace system settings.
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

U="${DESKTOP_USER:?Set DESKTOP_USER to the desktop account name.}"
if ! id "$U" >/dev/null 2>&1; then
  useradd -m -G wheel,seat,video,input,render -s /bin/bash "$U"
fi
usermod -aG wheel,seat,video,input,render,audio,storage "$U"
chage -d 0 "$U"

install -d -m 755 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

if [[ -n "${PUBKEY:-}" ]]; then
  install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
  printf '%s\n' "$PUBKEY" > "/home/$U/.ssh/authorized_keys"
  chown "$U:$U" "/home/$U/.ssh/authorized_keys"
  chmod 600 "/home/$U/.ssh/authorized_keys"
fi

retry() {
  local attempt=1
  while (( attempt <= 3 )); do
    if "$@"; then
      return 0
    fi
    echo "[warn] Attempt $attempt/3 failed: $*" >&2
    if (( attempt < 3 )); then
      sleep 5
    fi
    ((attempt += 1))
  done
  echo "[-] Command failed after 3 attempts: $*" >&2
  return 1
}

# These Omarchy packages are x86-only or have no suitable ARM64 build here.
x86_only_packages=(
  intel-ucode
  amd-ucode
  linux-zen
  'nvidia*'
  '1password*'
  spotify
  dropbox
  zoom
  obsidian
)
printf '[info] Omarchy x86-only packages intentionally omitted: %s\n' \
  "${x86_only_packages[*]}"
echo "[info] ARM alternatives: chromium, firefox, and compatible packages from the aarch64 extra repositories."

pacman-key --init
retry pacman-key --populate archlinuxarm
retry pacman -Syu --noconfirm

desktop_packages=(
  hyprland
  waybar
  mako
  walker
  alacritty
  pipewire
  pipewire-pulse
  wireplumber
  alsa-ucm-conf
  linux-firmware
  networkmanager
  bluez
  bluez-utils
  brightnessctl
  keyd
  greetd
  greetd-tuigreet
  seatd
  polkit
  xdg-desktop-portal-hyprland
)
retry pacman -S --needed --noconfirm "${desktop_packages[@]}"

if [[ -d /etc/skel/.config/hypr ]]; then
  install -d -o "$U" -g "$U" "/home/$U/.config/hypr" \
    || echo "[warn] Could not create the Hyprland configuration directory."
  cp -an /etc/skel/.config/hypr/. "/home/$U/.config/hypr/" \
    || echo "[warn] Could not copy the Hyprland skeleton configuration."
  chown -R "$U:$U" "/home/$U/.config/hypr" \
    || echo "[warn] Could not set ownership on the Hyprland configuration."
else
  echo "[warn] No Hyprland configuration found in /etc/skel."
fi

if systemctl list-unit-files seatd.service --no-legend | grep -q seatd.service; then
  systemctl enable seatd.service \
    || echo "[warn] Could not enable seatd.service."
else
  echo "[warn] seatd.service is not installed."
fi
if systemctl list-unit-files bluetooth.service --no-legend | grep -q bluetooth.service; then
  systemctl enable bluetooth.service \
    || echo "[warn] Could not enable bluetooth.service."
else
  echo "[warn] bluetooth.service is not installed."
fi
if systemctl list-unit-files greetd.service --no-legend | grep -q greetd.service; then
  install -d -m 755 /etc/greetd \
    || echo "[warn] Could not create /etc/greetd."
  cat > /etc/greetd/config.toml <<'GREETD' \
    || echo "[warn] Could not write the greetd configuration."
[terminal]
vt = 1

[default_session]
command = "tuigreet --cmd Hyprland"
user = "greeter"
GREETD
  systemctl enable greetd.service \
    || echo "[warn] Could not enable greetd.service."
else
  echo "[warn] greetd.service is not installed."
fi

echo "ARM64 desktop packages are installed. Omarchy upstream provisioning scripts were not run."
echo "The desktop account must set a new password at its next login."
