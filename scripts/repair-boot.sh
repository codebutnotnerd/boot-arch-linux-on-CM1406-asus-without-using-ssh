#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-chromeos.sh
. "$HERE/lib-chromeos.sh"
VERSION="$(cat "$HERE/../VERSION" 2>/dev/null || echo unknown)"

CHECK_ONLY=0
ASSUME_YES=0
STICK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    /dev/*) STICK="$1" ;;
    *) echo "[-] Unknown argument: $1 (use --help)" >&2; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "Run as root, in VT2:  sudo bash scripts/repair-boot.sh" >&2; exit 1; }
for c in crossystem cgpt futility rootdev dd; do
  command -v "$c" >/dev/null 2>&1 || { echo "[-] $c is missing: run this in ChromeOS (VT2), not on the stick." >&2; exit 1; }
done

problems=()
fixes=()
manual=()
ok()   { echo "  [OK]      $*"; }
bad()  { echo "  [PROBLEM] $*"; problems+=("$*"); }
info() { echo "  [info]    $*"; }

echo "=== repair-boot v$VERSION: can this Chromebook still boot the Arch stick? ==="

echo "== 1. Developer Mode"
devsw="$(crossystem devsw_boot 2>/dev/null || true)"
mainfw="$(crossystem mainfw_type 2>/dev/null || true)"
DEVMODE=0
if [[ "$devsw" == 1 && "$mainfw" == developer ]]; then
  ok "Developer Mode is on (devsw_boot=1, mainfw_type=developer)."
  DEVMODE=1
else
  bad "Developer Mode is OFF (devsw_boot=${devsw:-?}, mainfw_type=${mainfw:-?}). Without it the stick cannot boot."
  manual+=("Turn Developer Mode back on: Esc+Refresh+Power, then Ctrl+D, then confirm. WARNING: this erases the ChromeOS user data (not the stick). Then download this repository again and run: sudo bash scripts/repair-boot.sh")
fi

echo "== 2. Firmware flags"
mapfile -t FLAGS < <(tarkin_usb_boot_flags)
NEED_FLAGS=0
if (( ${#FLAGS[@]} == 0 )); then
  bad "crossystem knows neither dev_boot_external nor dev_boot_usb; cannot check USB boot."
else
  for n in "${FLAGS[@]}"; do info "$n=$(crossystem "$n" 2>/dev/null)"; done
  v="$(crossystem "${FLAGS[0]}" 2>/dev/null)"
  if [[ "$v" == 1 ]]; then
    ok "${FLAGS[0]}=1 (USB boot allowed)."
  else
    bad "${FLAGS[0]}=$v: USB boot is OFF (a firmware update, or leaving Developer Mode, resets it)."
    NEED_FLAGS=1
  fi
fi
so="$(crossystem dev_boot_signed_only 2>/dev/null || true)"
if [[ "$so" == 0 ]]; then
  ok "dev_boot_signed_only=0 (developer-signed kernels allowed)."
else
  bad "dev_boot_signed_only=${so:-?}: the stick's developer-signed kernel would be refused."
  NEED_FLAGS=1
fi
if (( NEED_FLAGS )); then
  if (( DEVMODE )) && (( ${#FLAGS[@]} )); then
    fixes+=("flags")
  else
    manual+=("The firmware flags can only be changed in Developer Mode.")
  fi
fi

echo "== 3. The stick"
candidates=()
if [[ -n "$STICK" ]]; then
  candidates=("$STICK")
else
  while IFS= read -r d; do
    if tarkin_is_tarkin_stick "$d"; then candidates+=("$d"); fi
  done < <(tarkin_usb_disks)
fi
DEV=""
if (( ${#candidates[@]} == 0 )); then
  bad "No Arch stick found (a USB disk whose partition 1 is a ChromeOS kernel and partition 2 is labelled ALARM)."
  info "USB disks seen: $(tarkin_usb_disks | tr '\n' ' ')"
  manual+=("Plug the stick in (directly, not through a hub), wait 5 seconds, run this again. If it is plugged in: sudo bash scripts/check-usb.sh")
elif (( ${#candidates[@]} > 1 )); then
  bad "Several Arch sticks are plugged in: ${candidates[*]}. Keep one, or name it: sudo bash scripts/repair-boot.sh /dev/sdX"
else
  DEV="${candidates[0]}"
  if ! tarkin_is_safe_usb_disk "$DEV"; then
    bad "$DEV is refused (see the reason above)."
    DEV=""
  elif ! tarkin_is_tarkin_stick "$DEV"; then
    bad "$DEV is not a stick made by this installer (partition 1 must be a ChromeOS kernel, partition 2 labelled ALARM)."
    DEV=""
  fi
fi

NEED_ATTRS=0
if [[ -n "$DEV" ]]; then
  ok "stick: $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null | tr -s ' '))"
  P="$(cgpt show -i 1 -P "$DEV" 2>/dev/null)"; T="$(cgpt show -i 1 -T "$DEV" 2>/dev/null)"; S="$(cgpt show -i 1 -S "$DEV" 2>/dev/null)"
  info "kernel partition 1: priority=$P tries=$T successful=$S"
  if [[ "$P" =~ ^[0-9]+$ && "$S" =~ ^[0-9]+$ && "$T" =~ ^[0-9]+$ ]]; then
    if (( P == 0 )); then
      bad "priority 0: the firmware skips this kernel."; NEED_ATTRS=1
    elif (( S == 0 && T == 0 )); then
      bad "successful=0 and tries=0: the firmware considers this kernel bad."; NEED_ATTRS=1
    elif (( S == 0 )); then
      bad "successful=0 (tries=$T): every boot uses up a try, then the stick stops booting."; NEED_ATTRS=1
    else
      ok "boot attributes are fine."
    fi
  else
    bad "cannot read the boot attributes of $DEV partition 1."
  fi
  (( NEED_ATTRS )) && fixes+=("attrs")

  P1="$(tarkin_part "$DEV" 1)"
  T1="$(mktemp /var/tmp/repair-kern.XXXXXX)"
  if dd if="$P1" of="$T1" bs=1M count=64 status=none 2>/dev/null && futility vbutil_kernel --verify "$T1" >/dev/null 2>&1; then
    ok "the kernel on $P1 verifies."
  else
    bad "the kernel on $P1 does NOT verify (damaged stick?). This script does not rewrite kernels."
    manual+=("Make the stick again: sudo bash install.sh  (or, only if the modules line below says they match: sudo bash scripts/set-cmdline.sh $DEV --normal)")
  fi
  rm -f "$T1"

  P2="$(tarkin_part "$DEV" 2)"
  mnt="$(findmnt -rno TARGET -S "$P2" 2>/dev/null | head -n 1)"
  tmpm=""
  if [[ -z "$mnt" ]]; then
    tmpm="$(mktemp -d /var/tmp/repair-root.XXXXXX)"
    if mount -o ro "$P2" "$tmpm" 2>/dev/null; then mnt="$tmpm"; fi
  fi
  if [[ -n "$mnt" ]]; then
    mods="$(ls "$mnt/usr/lib/modules" 2>/dev/null | tr '\n' ' ')"
    info "kernel modules on the stick: ${mods:-none}; ChromeOS now runs $(uname -r)."
    [[ -f "$mnt/etc/tarkin/version" ]] && info "stick made by v$(cat "$mnt/etc/tarkin/version")"
    if [[ -n "$tmpm" ]]; then umount "$tmpm" 2>/dev/null || true; fi
  else
    info "could not mount $P2 read-only to compare kernel modules (not needed to boot)."
  fi
  if [[ -n "$tmpm" ]]; then rmdir "$tmpm" 2>/dev/null || true; fi
fi

echo
if (( ${#problems[@]} == 0 )); then
  echo "Result: nothing wrong found. Boot with the stick plugged in and press Ctrl+U (or pick \"Boot from external disk\")."
  exit 0
fi
echo "Result: ${#problems[@]} problem(s):"
for p in "${problems[@]}"; do echo "  - $p"; done
if (( ${#manual[@]} )); then
  echo "Only you can do this:"
  for m in "${manual[@]}"; do echo "  * $m"; done
fi
if (( ${#fixes[@]} == 0 )); then
  echo "Nothing this script can repair by itself."
  exit 1
fi
echo "This script can repair:"
for f in "${fixes[@]}"; do
  case "$f" in
    flags) echo "  * crossystem ${FLAGS[*]/%/=1} dev_boot_signed_only=0   (then read back)" ;;
    attrs) echo "  * cgpt add -i 1 -P 15 -T 1 -S 1 $DEV   (stick only; then read back)" ;;
  esac
done
if (( CHECK_ONLY )); then
  echo "(--check: nothing changed)"
  exit 1
fi
if (( ! ASSUME_YES )); then
  read -r -p "Apply these repairs? [y/N] " a
  case "$a" in y|Y|yes|o|O|oui) ;; *) echo "Nothing changed."; exit 1 ;; esac
fi

rc=0
for f in "${fixes[@]}"; do
  case "$f" in
    flags)
      if tarkin_enable_usb_boot; then
        echo "[+] $(tarkin_usb_boot_state) dev_boot_signed_only=$(crossystem dev_boot_signed_only) (read back)."
      else
        echo "[-] The firmware flags did not stick (see above)."; rc=1
      fi ;;
    attrs)
      if tarkin_is_safe_usb_disk "$DEV" && tarkin_is_tarkin_stick "$DEV"; then
        cgpt add -i 1 -P 15 -T 1 -S 1 "$DEV"
        P="$(cgpt show -i 1 -P "$DEV")"; T="$(cgpt show -i 1 -T "$DEV")"; S="$(cgpt show -i 1 -S "$DEV")"
        if [[ "$P" == 15 && "$T" == 1 && "$S" == 1 ]]; then
          echo "[+] $DEV partition 1: priority=15 tries=1 successful=1 (read back)."
        else
          echo "[-] $DEV partition 1 reads back priority=$P tries=$T successful=$S."; rc=1
        fi
      else
        echo "[-] $DEV no longer passes the safety checks; not touched."; rc=1
      fi ;;
  esac
done
if (( rc == 0 )); then
  echo "Done. Power off, power on with the stick plugged in, then Ctrl+U (or \"Boot from external disk\")."
  (( ${#manual[@]} )) && echo "Still to do by you: see the list above."
fi
exit "$rc"
