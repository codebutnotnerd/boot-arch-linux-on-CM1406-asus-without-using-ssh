#!/bin/bash
# Guided installer for the ChromeOS VT2 shell (v1.50). THE command is:  sudo bash install.sh
# (install.sh at the top of the repository starts this script). It finds the rootfs and the stick,
# offers to resume an interrupted install, then runs install/install-usb.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"
STATE_DIR="${TARKIN_STATE_DIR:-/var/tmp/tarkin-install}"
STATE="$STATE_DIR/state"

die() { echo "[-] $*" >&2; exit 1; }

DRY_RUN=0
FRESH=0
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; PASS+=("$1"); shift ;;
    --fresh)   FRESH=1; shift ;;
    --resume)  shift ;;   # resuming is offered automatically
    -h|--help)
      cat <<'USAGE'
Usage: sudo bash install.sh [options]

Makes the Arch Linux ARM stick for the ASUS CM1406 in one go: rootfs download (continues
an interrupted download), partitioning, rootfs, kernel, Wi-Fi, password, and a first-boot
step that installs Hyprland, the Mali GPU stack and sound once the stick has booted.
If it is interrupted (power, reboot, network), run the same command again: it offers to
resume where it stopped. Log: /var/tmp/tarkin-install.log

Options:
  --dry-run            Checks and plan only; nothing is downloaded, written or changed.
  --fresh              Ignore an interrupted install and start over (erases the stick again).
  --no-desktop         Terminal only: no first-boot Hyprland/GPU/sound setup.
  --keymap <layout>    Keyboard layout on the stick (fr, us, de, ...). Default fr.
  --wifi-ssid <name>   Wi-Fi to use instead of the one saved in ChromeOS (passphrase is asked).
  --alarm <file|url>   Rootfs tarball to use (its .md5 must sit next to it).
More options and environment variables: bash install/install-usb.sh --help
USAGE
      exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root, in VT2:  sudo bash install.sh"
echo "=== boot-arch-linux-on-CM1406 v$VERSION ==="
(( DRY_RUN )) && echo "=== DRY RUN: nothing is downloaded, written or changed ==="

# shellcheck source=../scripts/lib-chromeos.sh
. "$ROOT/scripts/lib-chromeos.sh"

state_get() {
  [[ -f "$STATE" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$STATE"
}

usb_disks() {
  local d name
  for d in /sys/block/sd*; do
    [[ -e "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$(readlink -f "$d")" == *"/usb"* ]] || continue
    printf '%s %s %s\n' "$name" "$(lsblk -dno SIZE "/dev/$name" 2>/dev/null)" "$(lsblk -dno MODEL "/dev/$name" 2>/dev/null | tr ' ' '_')"
  done
}

ALARM=""
USER_ALARM=0
for a in ${PASS[@]+"${PASS[@]}"}; do [[ "$a" == --alarm || "$a" == -a ]] && USER_ALARM=1; done
for dir in /var/tmp /home/chronos/user/MyFiles/Downloads /home/chronos/user/Downloads /home/chronos/u-*/MyFiles/Downloads /home/chronos/u-*/Downloads "$ROOT" "$ROOT/.."; do
  [[ -f "$dir/ArchLinuxARM-aarch64-latest.tar.gz" ]] && { ALARM="$dir/ArchLinuxARM-aarch64-latest.tar.gz"; break; }
done
ALARM_ARGS=()
if (( USER_ALARM )); then
  echo "Rootfs    : given with --alarm"
elif [[ -n "$ALARM" ]]; then
  [[ -f "$ALARM.md5" ]] || die "Found $ALARM but not $ALARM.md5 beside it. Download the .md5 file too."
  echo "Rootfs    : $ALARM"
  ALARM_ARGS=(--alarm "$ALARM")
elif [[ -s "$STATE_DIR/download/ArchLinuxARM-aarch64-latest.tar.gz" ]]; then
  echo "Rootfs    : downloaded earlier into $STATE_DIR/download (checked again; a partial download continues)"
else
  echo "Rootfs    : not found locally, the installer will download it (about 800 MB; an interrupted download continues on the next run)"
fi

mapfile -t disks < <(usb_disks)
if (( ${#disks[@]} == 0 )); then
  echo "[-] No USB stick detected. Replug it, wait 5 seconds, try another port, then run this again." >&2
  echo "    Kernel messages:" >&2; dmesg | tail -8 >&2
  exit 1
fi

# ---- Resume an interrupted install? ----
saved_uuid="$(state_get STICK_PARTUUID | tr '[:upper:]' '[:lower:]')"
if [[ -n "$saved_uuid" && "$(state_get STEP_complete)" != "done" ]] && (( ! FRESH )); then
  resume_dev=""
  for d in "${disks[@]}"; do
    dev="/dev/${d%% *}"
    u="$(cgpt show -i 2 -u "$dev" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [[ -n "$u" && "$u" == "$saved_uuid" ]]; then resume_dev="$dev"; break; fi
  done
  if [[ -n "$resume_dev" ]]; then
    echo
    echo "An interrupted install was found on $resume_dev:"
    lsblk -o NAME,SIZE,MODEL,LABEL "$resume_dev" 2>/dev/null || true
    if (( DRY_RUN )); then
      exec env CONFIRM_ERASE="$resume_dev" bash "$HERE/install-usb.sh" --resume ${ALARM_ARGS[@]+"${ALARM_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"} "$resume_dev"
    fi
    read -r -p "Resume it (finished steps are skipped)? [Y/n] " ans
    case "${ans:-y}" in
      y|Y|yes|o|O|oui)
        exec env CONFIRM_ERASE="$resume_dev" bash "$HERE/install-usb.sh" --resume ${ALARM_ARGS[@]+"${ALARM_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"} "$resume_dev" ;;
      *) echo "Not resuming: a new install starts (the stick you pick is erased)." ;;
    esac
  else
    echo "[i] An interrupted install exists, but its stick is not plugged in. Plug it in and run this again to"
    echo "    resume it, or continue below to start over on another stick."
  fi
fi

echo "USB drives (sticks and external SSDs):"
for d in "${disks[@]}"; do printf '   /dev/%-8s %s\n' "${d%% *}" "${d#* }"; done
default="/dev/${disks[0]%% *}"
if (( DRY_RUN )); then
  DEV="$default"
  echo "Dry run on the first USB drive: $DEV"
  exec bash "$HERE/install-usb.sh" ${ALARM_ARGS[@]+"${ALARM_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"} "$DEV"
fi
read -r -p "Device to ERASE and install on [$default]: " DEV
DEV="${DEV:-$default}"
[[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
ok=0; for d in "${disks[@]}"; do [[ "/dev/${d%% *}" == "$DEV" ]] && ok=1; done
[[ $ok == 1 ]] || die "$DEV is not one of the detected USB sticks. Aborting."

echo
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINT "$DEV" 2>/dev/null || true
echo "ALL DATA ON $DEV WILL BE ERASED."
read -r -p "Type the device name again to confirm ($DEV): " confirm
[[ "$confirm" == "$DEV" ]] || die "Confirmation did not match. Aborting."

exec env CONFIRM_ERASE="$DEV" bash "$HERE/install-usb.sh" ${ALARM_ARGS[@]+"${ALARM_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"} "$DEV"
