# shellcheck shell=bash

KERNEL_TYPE_GUID="fe3a2a5d-4f32-41a7-b725-accc3285a309"

tarkin_usb_boot_flags() {
  local n
  for n in dev_boot_external dev_boot_usb; do
    if crossystem "$n" >/dev/null 2>&1; then
      printf '%s\n' "$n"
    fi
  done
  return 0
}

tarkin_usb_boot_state() {
  local n
  n="$(tarkin_usb_boot_flags | head -n 1)"
  [[ -n "$n" ]] || return 1
  printf '%s=%s\n' "$n" "$(crossystem "$n" 2>/dev/null)"
}

tarkin_enable_usb_boot() {
  local flags=() n v
  mapfile -t flags < <(tarkin_usb_boot_flags)
  if (( ${#flags[@]} == 0 )); then
    echo "crossystem knows neither dev_boot_external nor dev_boot_usb." >&2
    return 1
  fi
  for n in "${flags[@]}"; do
    crossystem "$n=1" >/dev/null 2>&1 || true
  done
  crossystem dev_boot_signed_only=0 >/dev/null 2>&1 || true
  v="$(crossystem "${flags[0]}" 2>/dev/null || true)"
  if [[ "$v" != 1 ]]; then
    echo "${flags[0]} reads back as '$v' after setting it to 1." >&2
    return 1
  fi
  v="$(crossystem dev_boot_signed_only 2>/dev/null || true)"
  if [[ "$v" != 0 ]]; then
    echo "dev_boot_signed_only reads back as '$v' after setting it to 0." >&2
    return 1
  fi
  return 0
}

tarkin_part() {
  if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s\n' "$1" "$2"; else printf '%s%s\n' "$1" "$2"; fi
}

tarkin_is_safe_usb_disk() {
  local dev="$1" name
  name="$(basename "$dev")"
  case "$dev" in *mmcblk*) echo "$dev looks like the internal eMMC." >&2; return 1 ;; esac
  [[ -b "$dev" && -d "/sys/block/$name" ]] || { echo "$dev is not a whole disk." >&2; return 1; }
  [[ "$(readlink -f "/sys/class/block/$name")" == *"/usb"* ]] || { echo "$dev is not a USB disk." >&2; return 1; }
  if [[ "$(rootdev -s -d 2>/dev/null || true)" == "$dev" ]]; then
    echo "$dev is the disk ChromeOS runs from." >&2
    return 1
  fi
  return 0
}

tarkin_is_tarkin_stick() {
  local dev="$1"
  cgpt show -i 1 -t "$dev" 2>/dev/null | grep -qi "$KERNEL_TYPE_GUID" || return 1
  [[ "$(cgpt show -i 2 -l "$dev" 2>/dev/null)" == ALARM ]] || return 1
  return 0
}

tarkin_usb_disks() {
  local d
  for d in /sys/block/sd*; do
    [[ -e "$d" ]] || continue
    [[ "$(readlink -f "$d")" == *"/usb"* ]] || continue
    printf '/dev/%s\n' "$(basename "$d")"
  done
  return 0
}
