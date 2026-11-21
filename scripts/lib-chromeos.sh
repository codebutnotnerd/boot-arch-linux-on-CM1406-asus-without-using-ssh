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
  if tarkin_disk_hosts_system "$dev"; then
    echo "$dev holds a ChromeOS system folder (/, /usr/local, /home, /var or the stateful partition)." >&2
    return 1
  fi
  return 0
}

TARKIN_SYS="${TARKIN_SYS:-/sys}"
TARKIN_PROC="${TARKIN_PROC:-/proc}"

tarkin_disk_nodes() {
  local name dir p
  name="$(basename "$1")"
  dir="$TARKIN_SYS/block/$name"
  [[ -r "$dir/dev" ]] || return 1
  printf '%s %s\n' "$name" "$(cat "$dir/dev")"
  for p in "$dir/$name"*; do
    [[ -r "$p/dev" ]] || continue
    printf '%s %s\n' "$(basename "$p")" "$(cat "$p/dev")"
  done
  return 0
}

tarkin_devnum() {
  local ma="${1%%:*}" mi="${1#*:}"
  echo $(( ((ma & 0xfff) << 8) | (mi & 0xff) | ((mi & ~0xff) << 12) | ((ma & ~0xfff) << 32) ))
}

tarkin_disk_hosts_system() {
  local nodes ids
  nodes="$(tarkin_disk_nodes "$1")" || return 1
  ids="$(awk '{ print $2 }' <<<"$nodes" | tr '\n' ' ')"
  [[ -r "$TARKIN_PROC/1/mountinfo" ]] || return 1
  awk -v ids=" $ids" '
    index(ids, " " $3 " ") && ($5 == "/" || $5 == "/usr/local" || $5 == "/home" || $5 == "/var" || $5 == "/mnt/stateful_partition") { found = 1 }
    END { exit !found }
  ' "$TARKIN_PROC/1/mountinfo"
}

tarkin_proc_name() {
  local c
  c="$(cat "$TARKIN_PROC/$1/comm" 2>/dev/null || true)"
  printf '%s' "${c:-?}"
}

tarkin_stick_blockers() {
  local dev="$1" nodes n id h dmname own pid ns f kind target num path map
  declare -A by_id=() by_num=() seen_ns=()
  nodes="$(tarkin_disk_nodes "$dev")" || { printf 'error\tcannot read %s/block/%s\n' "$TARKIN_SYS" "$(basename "$dev")"; return 0; }
  map=""
  while read -r n id; do
    by_id[$id]="$n"
    by_num[$(tarkin_devnum "$id")]="$n"
    map+="$n $id $(tarkin_devnum "$id") "
  done <<<"$nodes"

  while read -r n id; do
    if [[ "$n" == "$(basename "$dev")" ]]; then f="$TARKIN_SYS/block/$n/holders"; else f="$TARKIN_SYS/block/$(basename "$dev")/$n/holders"; fi
    for h in "$f"/*; do
      [[ -e "$h" || -L "$h" ]] || continue
      h="$(basename "$h")"
      dmname="$(cat "$TARKIN_SYS/block/$h/dm/name" 2>/dev/null || true)"
      printf 'holder\t/dev/%s is used by /dev/%s%s (device-mapper, LVM or RAID)\n' "$n" "$h" "${dmname:+ ($dmname)}"
    done
  done <<<"$nodes"

  if [[ -r "$TARKIN_PROC/swaps" ]]; then
    while read -r path _; do
      [[ -n "$path" && "$path" != Filename ]] || continue
      path="${path//\\040/ }"
      if [[ "$path" == /dev/* ]]; then
        target="$(basename "$(readlink -f "$path" 2>/dev/null || echo "$path")")"
        if [[ " $(awk '{ print $1 }' <<<"$nodes" | tr '\n' ' ') " == *" $target "* ]]; then
          printf 'swap\t/dev/%s is used as swap (swapoff /dev/%s)\n' "$target" "$target"
        fi
      else
        num="$(stat -c %d -- "$path" 2>/dev/null || true)"
        if [[ -n "$num" && -n "${by_num[$num]:-}" ]]; then
          printf 'swap\tthe swap file %s is on /dev/%s (swapoff %s)\n' "$path" "${by_num[$num]}" "$path"
        fi
      fi
    done < "$TARKIN_PROC/swaps"
  fi

  own="$(readlink "$TARKIN_PROC/self/ns/mnt" 2>/dev/null || echo self)"
  for f in "$TARKIN_PROC"/[0-9]*/mountinfo; do
    [[ -r "$f" ]] || continue
    pid="$(basename "$(dirname "$f")")"
    ns="$(readlink "$TARKIN_PROC/$pid/ns/mnt" 2>/dev/null || echo "pid$pid")"
    [[ -z "${seen_ns[$ns]:-}" ]] || continue
    seen_ns[$ns]=1
    while read -r id target; do
      [[ -n "${by_id[$id]:-}" ]] || continue
      target="${target//\\040/ }"
      if [[ "$ns" == "$own" ]]; then
        printf 'mount-here\t/dev/%s is mounted on %s\n' "${by_id[$id]}" "$target"
      else
        printf 'mount-other\t/dev/%s is mounted on %s in another mount namespace (seen from process %s, %s)\n' "${by_id[$id]}" "$target" "$pid" "$(tarkin_proc_name "$pid")"
      fi
    done < <(awk '{ print $3, $5 }' "$f" 2>/dev/null)
  done

  while IFS=$'\t' read -r kind pid n; do
    [[ -r "$TARKIN_PROC/$pid/comm" ]] || continue
    case "$kind" in
      dev) printf 'open\tprocess %s (%s) has /dev/%s open\n' "$pid" "$(tarkin_proc_name "$pid")" "$n" ;;
      file) printf 'open\tprocess %s (%s) has a file open on /dev/%s\n' "$pid" "$(tarkin_proc_name "$pid")" "$n" ;;
      cwd) printf 'open\tprocess %s (%s) works in a folder on /dev/%s\n' "$pid" "$(tarkin_proc_name "$pid")" "$n" ;;
      root) printf 'open\tprocess %s (%s) runs in a chroot on /dev/%s\n' "$pid" "$(tarkin_proc_name "$pid")" "$n" ;;
      exe) printf 'open\tprocess %s (%s) runs a program from /dev/%s\n' "$pid" "$(tarkin_proc_name "$pid")" "$n" ;;
    esac
  done < <(
    {
      timeout 60 find "$TARKIN_PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf 'L\t%p\t%l\n' 2>/dev/null
      timeout 60 find -L "$TARKIN_PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf 'D\t%p\t%D\n' 2>/dev/null
      timeout 60 find -L "$TARKIN_PROC"/[0-9]*/cwd "$TARKIN_PROC"/[0-9]*/root "$TARKIN_PROC"/[0-9]*/exe -maxdepth 0 -printf 'D\t%p\t%D\n' 2>/dev/null
    } | awk -F '\t' -v proc="$TARKIN_PROC" -v self="$$" -v sub_pid="${BASHPID:-}" -v map="$map" '
      BEGIN {
        k = split(map, parts, " ")
        for (i = 1; i + 2 <= k; i += 3) { name[parts[i]] = 1; num[parts[i + 2]] = parts[i] }
      }
      {
        rest = substr($2, length(proc) + 2)
        split(rest, bits, "/")
        pid = bits[1]; kind = bits[2]
        if (pid == self || pid == sub_pid) next
        if ($1 == "L") {
          if (substr($3, 1, 5) != "/dev/") next
          n = substr($3, 6)
          if (n in name) print "dev\t" pid "\t" n
        } else if ($3 in num) {
          if (kind == "fd") kind = "file"
          print kind "\t" pid "\t" num[$3]
        }
      }' | sort -u
  )
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
