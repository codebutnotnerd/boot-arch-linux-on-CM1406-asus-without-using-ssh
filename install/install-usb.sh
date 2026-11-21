#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARKIN_VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)"

DEV=""
ALARM_SOURCE="${ALARM_ARCHIVE:-}"
ALARM_CUSTOM=0
KEYMAP_ARG=""
[[ -n "${KEYMAP:-}" ]] && KEYMAP_ARG="$KEYMAP"
KEYMAP=""
USER_PASS=""
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
MNT="/usr/local/tarkin_alarm_root"
WORK="/var/tmp"
STATE_DIR="${TARKIN_STATE_DIR:-/var/tmp/tarkin-install}"
STATE="$STATE_DIR/state"
DL_DIR="$STATE_DIR/download"
LOG="$WORK/tarkin-install.log"
KERNEL_TMP_DIR=""
RESUME=0
RESUMING=0
DESKTOP=1
WM_ARG="${TARKIN_WM:-}"
WM=""
DRY_RUN=0
RESUMABLE=0
PASS_MIN=8

CMDLINE='console= loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootwait rw noinitrd net.ifnames=0 lsm=capability,landlock,yama,bpf cpuidle.governor=teo irqchip.gicv3_pseudo_nmi=1'

# shellcheck source=../scripts/lib-chromeos.sh
. "$REPO_ROOT/scripts/lib-chromeos.sh"

SAVED_SYSCTL=()
save_sysctl() {
  local f
  for f in kernel/panic kernel/panic_on_oops kernel/panic_on_warn kernel/softlockup_panic \
           kernel/hung_task_panic kernel/watchdog vm/dirty_bytes vm/dirty_background_bytes \
           vm/dirty_ratio vm/dirty_background_ratio vm/swappiness vm/overcommit_memory; do
    [[ -r /proc/sys/$f ]] && SAVED_SYSCTL+=("$f=$(cat /proc/sys/$f)")
  done
}
restore_sysctl() {
  local kv f v
  for kv in "${SAVED_SYSCTL[@]:-}"; do
    [[ -n "$kv" ]] || continue
    f="${kv%%=*}"; v="${kv#*=}"
    [[ "$(cat /proc/sys/$f 2>/dev/null)" == "$v" ]] || { echo "[i] restoring $f=$v" >&2; echo "$v" > /proc/sys/$f 2>/dev/null || true; }
  done
}
throttle_writeback() {
  echo 0 > /proc/sys/vm/dirty_bytes 2>/dev/null || true
  echo 8388608  > /proc/sys/vm/dirty_background_bytes 2>/dev/null || true
  echo 33554432 > /proc/sys/vm/dirty_bytes 2>/dev/null || true
}
MASKED_HOOKS=(30-systemd-binfmt 30-systemd-daemon-reload-system 30-systemd-daemon-reload-user
              30-systemd-sysctl 30-systemd-tmpfiles 30-systemd-udev-reload 30-systemd-update
              30-systemd-hwdb 30-systemd-catalog 90-mkinitcpio-install 60-mkinitcpio-remove
              71-dracut-install 60-dracut-remove)
mask_hooks() {
  mkdir -p "$MNT/etc/pacman.d/hooks"
  local h
  for h in "${MASKED_HOOKS[@]}"; do ln -sfn /dev/null "$MNT/etc/pacman.d/hooks/$h.hook"; done
}
unmask_hooks() {
  local h
  for h in "${MASKED_HOOKS[@]}"; do rm -f "$MNT/etc/pacman.d/hooks/$h.hook"; done
  rmdir "$MNT/etc/pacman.d/hooks" 2>/dev/null || true
}
in_chroot() {
  unshare --mount --pid --fork --propagation private bash -c '
    set -e
    M="$1"; shift
    mount -t proc proc "$M/proc"
    for x in sys sysrq-trigger; do
      mount --bind "$M/proc/$x" "$M/proc/$x"
      mount -o remount,bind,ro "$M/proc/$x"
    done
    mount --rbind /sys "$M/sys";  mount -o remount,bind,ro "$M/sys" 2>/dev/null || true
    mount --rbind /dev "$M/dev"
    mount -t tmpfs tmpfs "$M/tmp"
    exec chroot "$M" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root TERM=dumb LANG=C "$@"
  ' _ "$MNT" "$@"
}

state_get() {
  [[ -f "$STATE" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$STATE"
}
state_set() {
  mkdir -p "$STATE_DIR"
  local tmp="$STATE.tmp"
  if [[ -f "$STATE" ]]; then
    awk -v k="$1" 'index($0, k "=") != 1' "$STATE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STATE"
  sync "$STATE" 2>/dev/null || sync
}
state_del() {
  [[ -f "$STATE" ]] || return 0
  local k tmp="$STATE.tmp"
  cp "$STATE" "$tmp"
  for k in "$@"; do
    awk -v k="$k" 'index($0, k "=") != 1' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
  done
  mv -f "$tmp" "$STATE"
}
step_done() { [[ "$(state_get "STEP_$1")" == "done" ]]; }
mark_done() { state_set "STEP_$1" "done"; echo "   [step '$1' recorded as done]"; }
STICK_STEPS=(STEP_partition STEP_extract STEP_packages STEP_password STEP_wifi STEP_complete MODULES_KVER STICK_PARTUUID KEYMAP)
FS_STEPS=(STEP_extract STEP_packages STEP_password STEP_wifi STEP_complete MODULES_KVER)

cleanup() {
  local rc=$?
  restore_sysctl
  for d in tmp dev sys proc; do
    mountpoint -q "$MNT/$d" 2>/dev/null && umount "$MNT/$d" 2>/dev/null || true
  done
  if mountpoint -q "$MNT" 2>/dev/null; then
    umount "$MNT" || true
  fi
  rmdir "$MNT" 2>/dev/null || true
  [[ -z "$KERNEL_TMP_DIR" ]] || rm -rf "$KERNEL_TMP_DIR"
  if (( rc != 0 && RESUMABLE )); then
    cat >&2 <<EOF

[-] The install stopped before the end (exit code $rc). What is already done is kept.
    Fix the problem shown above, keep the same stick plugged in, then run the same command again:
        sudo bash install.sh
    It offers to resume where it stopped. Full log: $LOG
EOF
  fi
}
trap cleanup EXIT
trap 'echo "[-] Error on line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

die() { echo "[-] $*" >&2; exit 1; }
CURL_OPTS=(--fail --location --show-error --connect-timeout 20 --retry 3 --retry-delay 3 --speed-time 45 --speed-limit 2000)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alarm|-a)     ALARM_SOURCE="${2:?missing value for $1}"; ALARM_CUSTOM=1; shift 2 ;;
    --keymap|-k)    KEYMAP_ARG="${2:?missing value for $1}"; shift 2 ;;
    --wifi-ssid|-s) WIFI_SSID="${2:?missing value for $1}"; shift 2 ;;
    --wifi-pass|-w) die "Do not pass Wi-Fi passwords on the command line; the installer prompts for it." ;;
    --resume)       RESUME=1; shift ;;
    --no-desktop)   DESKTOP=0; shift ;;
    --wm)           WM_ARG="${2:?missing value for $1}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: sudo env CONFIRM_ERASE=/dev/sdX bash install/install-usb.sh [options] /dev/sdX
       (normally started by:  sudo bash install.sh)
Options:
  --alarm,   -a <file|http(s)-url>  ArchLinuxARM-aarch64 tarball (a matching .md5 file must sit next to it;
                                  a .sig file beside it is verified too)
  --wifi-ssid, -s <ssid>          Wi-Fi network (WPA2-PSK); the passphrase is prompted. Default: the network
                                  saved in ChromeOS, if any.
  --keymap,  -k <layout>          Keyboard layout of the on-screen terminal (xkb name: fr, us, de, ...). Default: fr
  --no-desktop                    Do not stage the first-boot setup (Mali GPU, sound); the stick
                                  then boots to the terminal only.
  --wm hyprland|niri              Optional: desktop the first boot sets up and starts (niri means niri +
                                  Vitrum Plus). Default: none; after the first boot choose with tarkin-desktop.
  --resume                        Continue an interrupted install on the same stick (finished steps are skipped).
  --dry-run                       Run the checks and show the plan; download, write and change nothing.
Environment:
  CONFIRM_ERASE=/dev/sdX  required, must equal the target device
  TARKIN_PASSWORD_FILE=F  non-interactive runs: the password for alarm is the first line of this root-only file
  ALLOW_NO_WIFI=1         allow an install without any Wi-Fi configuration
  WIFI_COUNTRY=FR         optional two-letter regulatory domain written to wpa_supplicant
  ALLOW_NO_PKGS=1         skip the network check and the Wi-Fi tools (the stick then has no on-screen terminal)
  ALLOW_INSECURE_HTTP=1   accept a rootfs downloaded over plain http without a verifiable GPG signature
  ALLOW_UNSIGNED_MIRROR=1 accept a rootfs from a mirror other than archlinuxarm.org without a verifiable GPG signature
  FORCE_BOARD=1           skip the "this is a google,tarkin board" check
  TARKIN_STATE_DIR=D      where progress and the download are kept (default /var/tmp/tarkin-install)
  TARKIN_WM=niri          same as --wm niri (or hyprland)
USAGE
      exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *)  [[ -z "$DEV" ]] || die "Unknown argument: $1"; DEV="$1"; shift ;;
  esac
done

[[ -n "$DEV" ]]       || die "Usage: sudo $0 [options] /dev/sdX"
[[ "$EUID" -eq 0 ]]   || die "Run this script as root."
[[ -b "$DEV" ]]       || die "Target is not a block device: $DEV"

echo "=== boot-arch-linux-on-CM1406 v$TARKIN_VERSION - target: ASUS Chromebook CM1406 (Google Tarkin, MT8189) ==="
(( DRY_RUN )) && echo "=== DRY RUN: nothing is downloaded, written or changed ==="

command -v rootdev >/dev/null 2>&1 || die "rootdev not found: run this on the Chromebook, in ChromeOS Developer Mode."

if [[ "${FORCE_BOARD:-0}" != 1 ]]; then
  compat="$(tr '\0' ' ' 2>/dev/null < /proc/device-tree/compatible || true)"
  [[ "$compat" == *google,tarkin* ]] \
    || die "This is not a google,tarkin board (compatible: ${compat:-unreadable}). Set FORCE_BOARD=1 to override."
fi

name="$(basename "$DEV")"
[[ "$DEV" =~ mmcblk ]] && die "$DEV looks like internal eMMC. This installer only targets USB drives."
[[ -d "/sys/block/$name" ]] || die "$DEV is not a whole disk. Pass the device (e.g. /dev/sda), not a partition."
[[ "$(readlink -f "/sys/class/block/$name")" == *"/usb"* ]] \
  || die "$DEV is not identified as a USB device by sysfs (USB sticks and USB-connected SSDs are accepted; internal disks are not)."
[[ "$(rootdev -s -d 2>/dev/null || true)" != "$DEV" ]] \
  || die "$DEV is the disk ChromeOS is running from."
safe_why="$(tarkin_is_safe_usb_disk "$DEV" 2>&1)" || die "Refusing $DEV: $safe_why"

for c in cgpt futility blockdev mkfs.ext4 bsdtar md5sum blkid dd findmnt mountpoint chroot crossystem curl unshare awk od; do
  command -v "$c" >/dev/null 2>&1 || die "Required command is missing: $c"
done
KB=/usr/share/vboot/devkeys/kernel.keyblock
SK=/usr/share/vboot/devkeys/kernel_data_key.vbprivk
[[ -f "$KB" && -f "$SK" ]] || die "ChromeOS developer signing keys are missing ($KB, $SK)."

running_disk="$(rootdev -s -d)"
running_root="$(rootdev -s)"
root_num="${running_root##*[!0-9]}"
[[ "$root_num" == 3 || "$root_num" == 5 ]] || die "Unexpected ChromeOS root partition: $running_root (expected p3 or p5)."
kern_num=$((root_num - 1))
part_kern="$(tarkin_part "$running_disk" "$kern_num")"
[[ -b "$part_kern" ]] || die "Active ChromeOS kernel partition not found: $part_kern"

KVER="$(uname -r)"
[[ -d "/lib/modules/$KVER" ]] || die "ChromeOS kernel modules not found in /lib/modules/$KVER."
[[ -d /lib/firmware ]]        || die "ChromeOS firmware directory /lib/firmware not found."

part1="$(tarkin_part "$DEV" 1)"; part2="$(tarkin_part "$DEV" 2)"

saved_uuid="$(state_get STICK_PARTUUID | tr '[:upper:]' '[:lower:]')"
cur_uuid="$(cgpt show -i 2 -u "$DEV" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
if (( RESUME )); then
  [[ -n "$saved_uuid" ]] || die "--resume: there is no interrupted install to resume ($STATE has no stick). Run without --resume."
  [[ "$(state_get STEP_complete)" != "done" ]] || die "--resume: the last install finished. Run without --resume to make a new stick."
  [[ "$cur_uuid" == "$saved_uuid" ]] && tarkin_is_tarkin_stick "$DEV" \
    || die "--resume: $DEV is not the stick of the interrupted install (its partition 2 does not match). Plug that stick in, or run without --resume to start over (this erases $DEV)."
  RESUMING=1
fi

if (( RESUMING )); then
  saved_keymap="$(state_get KEYMAP)"
  if [[ -n "$KEYMAP_ARG" && -n "$saved_keymap" && "$KEYMAP_ARG" != "$saved_keymap" ]]; then
    echo "[i] Keyboard layout changed from $saved_keymap to $KEYMAP_ARG for this run."
  fi
  KEYMAP="${KEYMAP_ARG:-${saved_keymap:-fr}}"
else
  KEYMAP="${KEYMAP_ARG:-fr}"
fi
[[ "$KEYMAP" =~ ^[a-z0-9_+-]{2,20}$ ]] || die "--keymap must be an xkb layout name such as fr or us."

if (( RESUMING )) && [[ -z "$WM_ARG" ]]; then
  WM="$(state_get WM)"
fi
WM="${WM_ARG:-${WM:-none}}"
case "$WM" in
  hyprland|niri|none) ;;
  *) die "--wm must be hyprland or niri (got: $WM)." ;;
esac
(( DESKTOP )) || [[ "$WM" == none ]] || die "--wm $WM needs the desktop; it cannot be combined with --no-desktop."

if (( RESUMING )); then
  echo "== Resuming the interrupted install on $DEV. Already done:"
  for s in partition extract packages password wifi; do
    if step_done "$s"; then echo "     - $s"; fi
  done
  [[ "$(state_get MODULES_KVER)" == "$KVER" ]] && echo "     - kernel modules and firmware ($KVER)"
fi

ALARM_KEY_FPR=68B3537F39A313B3E574D06777193F152BDBE6A6
ALARM_KEYSERVERS=(hkps://keyserver.ubuntu.com hkps://keys.openpgp.org)

verify_signature() {
  local file="$1" sig="$2" gh ks status
  command -v gpg >/dev/null 2>&1 || return 2
  [[ -s "$sig" ]] || return 2
  gh="$(mktemp -d "$WORK/alarm-gpg.XXXXXX")"
  chmod 700 "$gh"
  for ks in "${ALARM_KEYSERVERS[@]}"; do
    if gpg --homedir "$gh" --batch --keyserver "$ks" --recv-keys "$ALARM_KEY_FPR" >/dev/null 2>&1; then break; fi
  done
  gpg --homedir "$gh" --batch --list-keys "$ALARM_KEY_FPR" >/dev/null 2>&1 || { rm -rf -- "$gh"; return 2; }
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null)" || { rm -rf -- "$gh"; return 1; }
  rm -rf -- "$gh"
  grep -q "^\[GNUPG:\] VALIDSIG .*$ALARM_KEY_FPR" <<<"$status"
}

md5_expected() { awk 'NR == 1 { print tolower($1) }' "$1" 2>/dev/null; }
md5_of()       { md5sum "$1" | awk '{ print $1 }'; }

fetch_resumable() {
  local url="$1" out="$2" try before after rc
  for try in 1 2 3 4; do
    before="$(stat -c %s "$out" 2>/dev/null || echo 0)"
    rc=0
    if (( before > 0 )); then
      echo "   continuing at $((before / 1048576)) MiB (attempt $try)..."
      curl "${CURL_OPTS[@]}" -C - "$url" -o "$out" || rc=$?
    else
      curl "${CURL_OPTS[@]}" "$url" -o "$out" || rc=$?
    fi
    (( rc == 0 )) && return 0
    after="$(stat -c %s "$out" 2>/dev/null || echo 0)"
    if (( rc == 33 || rc == 36 || (rc == 22 && before > 0 && after == before) )); then
      echo "   [!] the server cannot continue this partial download (curl $rc); starting this file again."
      rm -f "$out"
      continue
    fi
    (( after > before )) || return "$rc"
  done
  return 1
}

ROOTFS_NAME=ArchLinuxARM-aarch64-latest.tar.gz
ALARM_MIRRORS=(
  "https://github.com/codebutnotnerd/boot-arch-linux-on-CM1406-asus-without-using-ssh/releases/download/rootfs-2026.08/$ROOTFS_NAME"
  "https://os.archlinuxarm.org/os/$ROOTFS_NAME"
  "https://mirror.archlinuxarm.org/os/$ROOTFS_NAME"
  "http://os.archlinuxarm.org/os/$ROOTFS_NAME"
  "http://mirror.archlinuxarm.org/os/$ROOTFS_NAME"
  "http://fr.mirror.archlinuxarm.org/os/$ROOTFS_NAME"
  "http://nj.us.mirror.archlinuxarm.org/os/$ROOTFS_NAME"
)

ARCHIVE=""
ARCHIVE_URL=""
ROOTFS_READY=0
get_rootfs() {
  local u saved_url mirrors=() want got tried=" "
  if [[ -n "$ALARM_SOURCE" && "$ALARM_SOURCE" != http* ]]; then
    [[ -f "$ALARM_SOURCE" ]] || die "Arch Linux ARM archive not found: $ALARM_SOURCE"
    ARCHIVE="$ALARM_SOURCE"
    ROOTFS_READY=1
    return 0
  fi
  ARCHIVE="$DL_DIR/$ROOTFS_NAME"
  saved_url="$(state_get ROOTFS_URL)"
  if [[ "$ALARM_CUSTOM" == 1 ]]; then
    mirrors=("$ALARM_SOURCE")
  else
    mirrors=("${ALARM_MIRRORS[@]}")
  fi
  if [[ -n "$saved_url" ]] && ! printf '%s\n' "${mirrors[@]}" | grep -qxF -- "$saved_url"; then
    if (( DRY_RUN )); then
      echo "   [dry-run] would delete the earlier download from $saved_url (not in this run's mirror list)"
    else
      rm -f "$ARCHIVE" "$ARCHIVE.md5" "$ARCHIVE.sig"
      state_del ROOTFS_URL ROOTFS_MD5 SIG_OK_MD5
    fi
    saved_url=""
  fi
  local http_unverified=0
  if [[ "$saved_url" == http://* && "${ALLOW_INSECURE_HTTP:-0}" != 1 ]] \
     && [[ -z "$(state_get SIG_OK_MD5)" || "$(state_get SIG_OK_MD5)" != "$(state_get ROOTFS_MD5)" ]]; then
    http_unverified=1
    echo "[i] The earlier download came over plain http without a verified signature; trying the https mirrors first."
  fi
  if (( ! http_unverified )) && [[ -n "$saved_url" && -s "$ARCHIVE" && -s "$ARCHIVE.md5" && "$(state_get ROOTFS_MD5)" == "$(md5_expected "$ARCHIVE.md5")" ]]; then
    echo "== Checking the rootfs downloaded by an earlier run ($ARCHIVE)..."
    if [[ "$(md5_of "$ARCHIVE")" == "$(md5_expected "$ARCHIVE.md5")" ]]; then
      ARCHIVE_URL="$saved_url"
      ROOTFS_READY=1
      echo "== Rootfs already downloaded from $saved_url (checksum OK); not downloading it again."
      return 0
    fi
    if (( DRY_RUN )); then
      echo "   [dry-run] the earlier download is damaged; it would be downloaded again."
      return 0
    fi
    echo "[!] The earlier download is damaged; downloading it again."
    rm -f "$ARCHIVE" "$ARCHIVE.md5" "$ARCHIVE.sig"
    state_del ROOTFS_MD5 SIG_OK_MD5
  fi
  if (( DRY_RUN )); then
    if [[ -s "$ARCHIVE" && -n "$saved_url" ]] && (( ! http_unverified )); then
      echo "   [dry-run] would continue the partial download ($(( $(stat -c %s "$ARCHIVE") / 1048576 )) MiB) from $saved_url"
    else
      echo "   [dry-run] would download the rootfs (about 800 MB) into $DL_DIR, mirrors in this order:"
      printf '               %s\n' "${mirrors[@]}"
    fi
    return 0
  fi
  mkdir -p "$DL_DIR"
  local avail_kb
  avail_kb="$(df -Pk "$DL_DIR" | awk 'NR==2 {print $4}')"
  (( avail_kb >= 1258291 )) || [[ -s "$ARCHIVE" ]] \
    || die "Only $((avail_kb / 1024)) MiB free in $DL_DIR; the rootfs download needs about 1.2 GiB."
  if [[ -n "$saved_url" ]] && (( ! http_unverified )); then
    mirrors=("$saved_url" "${mirrors[@]}")
  fi
  echo "== Getting the rootfs (an interrupted download continues where it stopped; https mirrors first, then http)..."
  for u in "${mirrors[@]}"; do
    [[ "$tried" != *" $u "* ]] || continue
    tried+="$u "
    echo "== Trying $u ..."
    rm -f "$ARCHIVE.md5.new"
    if ! curl "${CURL_OPTS[@]}" "${u}.md5" -o "$ARCHIVE.md5.new"; then
      rm -f "$ARCHIVE.md5.new"
      echo "   [!] no checksum file at this mirror (or no network); next one."
      continue
    fi
    want="$(md5_expected "$ARCHIVE.md5.new")"
    [[ "$want" =~ ^[0-9a-f]{32}$ ]] || { rm -f "$ARCHIVE.md5.new"; echo "   [!] invalid .md5 file; next mirror."; continue; }
    if [[ "$u" != "$(state_get ROOTFS_URL)" ]]; then
      rm -f "$ARCHIVE" "$ARCHIVE.md5" "$ARCHIVE.sig"
      state_del ROOTFS_MD5 SIG_OK_MD5
      state_set ROOTFS_URL "$u"
    fi
    mv -f "$ARCHIVE.md5.new" "$ARCHIVE.md5"
    if [[ -s "$ARCHIVE" && "$(md5_of "$ARCHIVE")" == "$want" ]]; then
      echo "   the file downloaded earlier is already complete."
    elif ! fetch_resumable "$u" "$ARCHIVE"; then
      echo "   [!] download from $u did not complete; trying the next mirror. Rerunning the installer later continues the partial download of the last mirror that answered."
      continue
    fi
    got="$(md5_of "$ARCHIVE")"
    if [[ "$got" != "$want" ]]; then
      echo "   [!] checksum mismatch; downloading this file again from the start."
      rm -f "$ARCHIVE"
      if ! fetch_resumable "$u" "$ARCHIVE" || [[ "$(md5_of "$ARCHIVE")" != "$want" ]]; then
        rm -f "$ARCHIVE"
        echo "   [!] still no matching checksum from $u; next mirror."
        continue
      fi
    fi
    curl "${CURL_OPTS[@]}" "${u}.sig" -o "$ARCHIVE.sig" 2>/dev/null || rm -f "$ARCHIVE.sig"
    state_set ROOTFS_MD5 "$want"
    ARCHIVE_URL="$u"
    ROOTFS_READY=1
    echo "== Rootfs downloaded from $u"
    return 0
  done
  die "Could not download the rootfs from any mirror. Run the same command again to continue, or download $ROOTFS_NAME and its .md5 with the ChromeOS browser into /var/tmp, then re-run (the launcher finds it there)."
}

drain_tty() {
  local junk
  [[ -t 0 ]] || return 0
  while IFS= read -r -s -t 0.2 -n 4096 junk; do :; done 2>/dev/null || true
}
read_hidden() {
  local c rest LC_ALL=C
  HIDDEN_REPLY=""
  drain_tty
  printf '%s' "$1" >&2
  while :; do
    c=""
    IFS= read -r -s -n 1 c || break
    case "$c" in
      ""|$'\r'|$'\n') break ;;
      $'\x7f'|$'\b')
        if [[ -n "$HIDDEN_REPLY" ]]; then HIDDEN_REPLY="${HIDDEN_REPLY%?}"; printf '\b \b' >&2; fi ;;
      $'\x15')
        while [[ -n "$HIDDEN_REPLY" ]]; do HIDDEN_REPLY="${HIDDEN_REPLY%?}"; printf '\b \b' >&2; done ;;
      $'\e')
        rest=""; IFS= read -r -s -t 0.05 -n 1 rest || true
        if [[ "$rest" == "[" || "$rest" == "O" ]]; then
          while IFS= read -r -s -t 0.05 -n 1 rest; do [[ -z "$rest" || "$rest" == [@-~] ]] && break; done || true
        fi ;;
      *) HIDDEN_REPLY+="$c"; printf '*' >&2 ;;
    esac
  done
  printf '\n' >&2
}

password_problem() {
  local p="$1" lower LC_ALL=C
  if (( ${#p} < PASS_MIN )); then echo "Too short: use at least $PASS_MIN characters."; return 0; fi
  lower="${p,,}"
  case "$lower" in
    *alarm*|root*|password*|motdepasse*|12345678*|azerty*|qwerty*)
      echo "This password is (or contains) the default one, or is too common."; return 0 ;;
  esac
  if [[ ! "$p" =~ ^[\ -~]+$ ]]; then echo "Use plain ASCII characters only (no accents, no Tab)."; return 0; fi
  if [[ "$p" == *:* ]]; then echo "The password must not contain a colon (:)."; return 0; fi
  if [[ "$KEYMAP" != us && "${TARKIN_PASSWORD_ANY_CHARS:-0}" != 1 && ! "$p" =~ ^[bcdefghijklnoprstuvxBCDEFGHIJKLNOPRSTUVX]+$ ]]; then
    echo "Only the letters b c d e f g h i j k l n o p r s t u v x (lower or upper case) are allowed, see above."
    return 0
  fi
  return 1
}
read_password() {
  local p1 p2 why tries
  if [[ -n "${TARKIN_PASSWORD_FILE:-}" ]]; then
    [[ -f "$TARKIN_PASSWORD_FILE" && -r "$TARKIN_PASSWORD_FILE" ]] || die "TARKIN_PASSWORD_FILE: cannot read $TARKIN_PASSWORD_FILE"
    p1=""
    IFS= read -r p1 < "$TARKIN_PASSWORD_FILE" || true
    p1="${p1%$'\r'}"
    if why="$(password_problem "$p1")"; then die "TARKIN_PASSWORD_FILE: $why"; fi
    USER_PASS="$p1"
    echo "== Password for alarm read from TARKIN_PASSWORD_FILE (delete that file after the install)."
    return 0
  fi
  [[ -t 0 ]] || die "A password for the user alarm is required and this run is not interactive. Put it on the first line of a root-only file and set TARKIN_PASSWORD_FILE=/path/to/file (the default alarm/alarm is never kept)."
  echo
  echo "== Choose the password of the user 'alarm' (used for sudo on the stick). It is required:"
  echo "   the default 'alarm' is not kept, and the root account will be locked (sudo is used instead)."
  echo "   At least $PASS_MIN characters, not 'alarm'."
  if [[ "$KEYMAP" != us && "${TARKIN_PASSWORD_ANY_CHARS:-0}" != 1 ]]; then
    echo "   IMPORTANT: this VT2 console types as a US (QWERTY) keyboard, but the stick will use the"
    echo "   '$KEYMAP' layout. To get the same password on both, use ONLY these letters, whose keys are the"
    echo "   same on QWERTY, AZERTY and QWERTZ:  b c d e f g h i j k l n o p r s t u v x  (upper or lower case)."
    echo "   No digits, no symbols, no a q w z y m. Set TARKIN_PASSWORD_ANY_CHARS=1 to lift this rule."
  fi
  for tries in 1 2 3 4 5; do
    read_hidden "Password for alarm (each key shows as *): "; p1="$HIDDEN_REPLY"
    if why="$(password_problem "$p1")"; then echo "[!] $why"; continue; fi
    read_hidden "Same password again: "; p2="$HIDDEN_REPLY"
    if [[ "$p1" != "$p2" ]]; then
      echo "[!] The two entries differ (${#p1} then ${#p2} characters). Try again: watch the number of * on each line."
      continue
    fi
    USER_PASS="$p1"
    HIDDEN_REPLY=""
    return 0
  done
  die "No valid password after $tries tries. Nothing was written to the stick."
}

get_rootfs

(( ROOTFS_READY || DRY_RUN )) || die "Rootfs archive missing: $ARCHIVE"
if (( ROOTFS_READY )); then
  [[ -f "$ARCHIVE.md5" ]] || die "Missing checksum file: $ARCHIVE.md5"
  expected_md5="$(md5_expected "$ARCHIVE.md5")"
  [[ "$expected_md5" =~ ^[0-9a-f]{32}$ ]] || die "Invalid MD5 checksum format in $ARCHIVE.md5"
  actual_md5="$(md5_of "$ARCHIVE")"
  [[ "$actual_md5" == "$expected_md5" ]] || die "Rootfs checksum mismatch; refusing to erase the USB drive."

  SIG_OK=0
  if [[ -s "$ARCHIVE.sig" ]]; then
    if [[ -n "$ARCHIVE_URL" && "$(state_get SIG_OK_MD5)" == "$actual_md5" ]]; then
      SIG_OK=1; echo "== Rootfs signature already verified by an earlier run (key $ALARM_KEY_FPR)."
    else
      sig_rc=0
      verify_signature "$ARCHIVE" "$ARCHIVE.sig" || sig_rc=$?
      case "$sig_rc" in
        0) SIG_OK=1; echo "== Rootfs signature verified (key $ALARM_KEY_FPR)."
           [[ -z "$ARCHIVE_URL" ]] || (( DRY_RUN )) || state_set SIG_OK_MD5 "$actual_md5" ;;
        1) if [[ -n "$ARCHIVE_URL" ]] && (( ! DRY_RUN )); then
             rm -f "$ARCHIVE" "$ARCHIVE.md5" "$ARCHIVE.sig"
             state_del ROOTFS_URL ROOTFS_MD5 SIG_OK_MD5
             die "The signature of the rootfs downloaded from $ARCHIVE_URL does not verify against the Arch Linux ARM Build System key; refusing to erase the USB drive. The download was deleted: running the installer again downloads it again."
           fi
           die "The signature of the rootfs does not verify against the Arch Linux ARM Build System key; refusing to erase the USB drive." ;;
        *) echo "[!] $ARCHIVE.sig could not be checked (gpg missing or no keyserver reachable); relying on the .md5." >&2 ;;
      esac
    fi
  fi
  if [[ "$SIG_OK" != 1 && "$ARCHIVE_URL" == http://* ]]; then
    if [[ "${ALLOW_INSECURE_HTTP:-0}" == 1 ]]; then
      echo "[!] The rootfs came over plain http and its authenticity could NOT be verified (ALLOW_INSECURE_HTTP=1)." >&2
    else
      die "The rootfs came over plain http and no verifiable GPG signature is available (needs gpg, the .sig file and a keyserver). A .md5 from the same server proves nothing. Download the tarball and its .md5 with the ChromeOS browser over https into /var/tmp and run again, or set ALLOW_INSECURE_HTTP=1 to accept the risk."
    fi
  fi
  if [[ "$SIG_OK" != 1 && -n "$ARCHIVE_URL" && "$ARCHIVE_URL" != *archlinuxarm.org/* && "$ARCHIVE_URL" != https://github.com/codebutnotnerd/* ]]; then
    if [[ "${ALLOW_UNSIGNED_MIRROR:-0}" == 1 ]]; then
      echo "[!] The rootfs comes from $ARCHIVE_URL and its signature could NOT be verified (ALLOW_UNSIGNED_MIRROR=1)." >&2
    else
      die "The rootfs comes from a mirror that is not archlinuxarm.org and its GPG signature did not verify (the .sig must exist and be signed by key $ALARM_KEY_FPR). A .md5 from the same place proves nothing. Set ALLOW_UNSIGNED_MIRROR=1 to accept the risk."
    fi
  fi
fi

SKIP_WIFI=0
if (( RESUMING )) && step_done wifi; then
  SKIP_WIFI=1
  echo "== Wi-Fi: configured by the interrupted run, kept."
fi
if (( ! SKIP_WIFI )); then
  if [[ -z "$WIFI_SSID" && "${ALLOW_NO_WIFI:-0}" != 1 && -f /var/cache/shill/default.profile ]]; then
    echo "== Reading the saved Wi-Fi network from ChromeOS..."
    prof=/var/cache/shill/default.profile
    shill_field() {
      awk -v want="$1" '
        /^\[/ { if (found) exit; sec = ($0 ~ /^\[wifi_/); name = ""; pass = ""; next }
        sec && /^Name=/ { name = substr($0, 6); found = 1 }
        sec && /^WiFi\.Passphrase=/ { pass = substr($0, 17) }
        END { if (found) print (want == "name" ? name : pass) }' "$prof"
    }
    WIFI_SSID="$(shill_field name)"
    psk="$(shill_field pass)"
    case "$psk" in rot47:*) psk="$(printf '%s' "${psk#rot47:}" | tr '!-~' 'P-~!-O')";; esac
    WIFI_PASS="$psk"
  fi
  if [[ -n "$WIFI_SSID" && -z "$WIFI_PASS" ]] && (( ! DRY_RUN )); then
    if [[ -t 0 ]]; then
      read_hidden "Wi-Fi passphrase for '$WIFI_SSID' (each key shows as *): "; WIFI_PASS="$HIDDEN_REPLY"; HIDDEN_REPLY=""
    fi
    [[ -n "$WIFI_PASS" ]] || die "No Wi-Fi passphrase provided; omit --wifi-ssid or rerun interactively."
  fi
  if [[ -z "$WIFI_SSID" ]]; then
    echo "[i] No Wi-Fi network configured. After booting, use  sudo tarkin-wifi \"NetworkName\"  in the terminal."
    (( ! DESKTOP )) || echo "[i] The first-boot setup (Hyprland, GPU, sound) waits for that network before it starts."
  fi
  if [[ -n "$WIFI_SSID" ]] && (( ! DRY_RUN )); then
    [[ "$WIFI_SSID" != *$'\n'* && "$WIFI_SSID" != *$'\r'* ]] || die "SSIDs containing line breaks are not supported."
    (( ${#WIFI_PASS} >= 8 && ${#WIFI_PASS} <= 63 )) || die "Only WPA2-PSK passphrases (8-63 characters) are supported."
    [[ -z "${WIFI_COUNTRY:-}" || "$WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be two capital letters, e.g. FR."
  fi
fi

if [[ "${ALLOW_NO_PKGS:-0}" != 1 ]] && ! { (( RESUMING )) && step_done packages; }; then
  echo "== Checking network access to the Arch Linux ARM package mirror..."
  curl -sSIL --connect-timeout 15 --max-time 30 http://mirror.archlinuxarm.org/aarch64/core/core.db >/dev/null 2>&1 \
    || die "Cannot reach mirror.archlinuxarm.org from this shell. Check that ChromeOS has internet (Wi-Fi connected), try another network (a phone hotspot), or set ALLOW_NO_PKGS=1 to install without Wi-Fi tools (the stick then has no on-screen terminal)."
fi

NEED_PASSWORD=1
if (( RESUMING )) && step_done password; then
  NEED_PASSWORD=0
  echo "== Password for alarm: set by the interrupted run, kept."
fi

busy_list() { tarkin_stick_blockers "$DEV" 2>/dev/null || true; }
show_busy() { printf '%s\n' "$1" | cut -f2- | sed 's/^/      - /'; }
stop_busy() {
  {
    echo "[-] $DEV is in use, so it was not $2. What uses it:"
    show_busy "$1"
    echo "    Close the programs listed, eject the stick in the Files app (or unplug it and plug it in again"
    echo "    without opening the Files app), then run the same command again."
    echo "    $3"
  } >&2
  exit 1
}

settle() {
  udevadm settle --timeout=15 2>/dev/null || sleep 2
}

echo "== Checking that nothing uses $DEV..."
for _ in 1 2 3; do
  busy="$(busy_list)"
  hard="$(printf '%s\n' "$busy" | grep -v -e '^mount-here' -e '^mount-other' -e '^$' || true)"
  [[ -n "$hard" ]] || break
  settle
  sleep 2
done
mounted="$(printf '%s\n' "$busy" | grep -e '^mount-here' -e '^mount-other' || true)"
if [[ -n "$hard" ]]; then
  stop_busy "$hard" "touched" "Nothing was changed."
fi
if [[ -n "$mounted" ]]; then
  echo "   Mounted now; unmounted before anything is written:"
  show_busy "$mounted"
else
  echo "   Not mounted, not open, no swap, no device-mapper or RAID on it."
fi

if (( DRY_RUN )); then
  echo
  echo "== Plan for $DEV (dry run):"
  plan() { if (( RESUMING )) && step_done "$1"; then echo "   skip  $2 (done earlier)"; else echo "   do    $2"; fi; }
  echo "   do    re-sign the running ChromeOS kernel ($part_kern, $KVER) with the developer keys"
  echo "   do    turn USB boot on: $(tarkin_usb_boot_flags | head -n 1 || true)=1 dev_boot_signed_only=0 (now: $(tarkin_usb_boot_state 2>/dev/null || echo unknown))"
  [[ -z "$mounted" ]] || echo "   do    unmount the partitions of $DEV listed above, and stop if one stays in use"
  plan partition "partition $DEV (ChromeOS GPT: p1 kernel, p2 root) - ERASES the stick"
  plan extract "format $part2 and extract the rootfs"
  echo "   do    copy the Tarkin files (rootfs/), fstab, keyboard layout $KEYMAP"
  if [[ "$(state_get MODULES_KVER)" == "$KVER" ]] && (( RESUMING )); then
    echo "   skip  ChromeOS kernel modules and firmware ($KVER, done earlier)"
  else
    echo "   do    copy the ChromeOS kernel modules and firmware ($KVER)"
  fi
  [[ "${ALLOW_NO_PKGS:-0}" == 1 ]] && echo "   skip  packages (ALLOW_NO_PKGS=1)" || plan packages "install the terminal, Wi-Fi tools and sudo (pacman in a chroot)"
  plan password "set the password of alarm (asked before writing), lock root"
  if (( SKIP_WIFI )); then echo "   skip  Wi-Fi (done earlier)"; elif [[ -n "$WIFI_SSID" ]]; then echo "   do    Wi-Fi for the network '$WIFI_SSID'"; else echo "   skip  Wi-Fi (none configured)"; fi
  if (( DESKTOP )); then echo "   do    stage the first-boot setup: Mali GPU + sound (and the Hyprland files), as alarm, once the network is up"; else echo "   skip  first-boot desktop setup (--no-desktop)"; fi
  case "$WM" in
    niri) echo "   do    then niri + Vitrum Plus (tarkin-desktop --niri), started at boot" ;;
    hyprland) echo "   do    then start Hyprland at boot (base config)" ;;
    *) (( ! DESKTOP )) || echo "   skip  no desktop at boot until one is chosen with tarkin-desktop" ;;
  esac
  echo "   do    write and verify the signed kernel on $part1"
  echo "== Dry run finished; nothing was changed."
  RESUMABLE=0
  exit 0
fi

if (( NEED_PASSWORD )); then
  read_password
fi

echo "Target USB device : $DEV"
echo "Stock kernel      : $part_kern ($KVER)"
if (( RESUMING )); then
  echo "Resuming          : finished steps are skipped; unfinished ones are redone on $DEV."
else
  echo "WARNING: all data on $DEV will be erased."
fi
if [[ "${CONFIRM_ERASE:-}" != "$DEV" ]]; then
  [[ -t 0 ]] || die "Non-interactive run refused. Set CONFIRM_ERASE='$DEV' to confirm."
  read -r -p "Type '$DEV' to continue: " confirmation
  [[ "$confirmation" == "$DEV" ]] || die "Confirmation did not match; aborting."
fi

exec > >(tee -a "$LOG") 2>&1
echo "[i] $(date -u +%FT%TZ) v$TARKIN_VERSION $( (( RESUMING )) && echo resume || echo fresh) install on $DEV. Full log: $LOG (survives a reboot; send it if the machine restarts again)"
RESUMABLE=1
if (( ! RESUMING )); then
  state_del "${STICK_STEPS[@]}"
fi
state_set KEYMAP "$KEYMAP"
state_set WM "$WM"
save_sysctl
throttle_writeback

echo "== Repacking the stock kernel with the developer keys..."
KERNEL_TMP_DIR="$(mktemp -d "$WORK/tarkin-kernel.XXXXXX")"
dd if="$part_kern" of="$KERNEL_TMP_DIR/stock.bin" bs=1M status=none
printf '%s\n' "$CMDLINE" > "$KERNEL_TMP_DIR/cmdline"
futility vbutil_kernel --repack "$KERNEL_TMP_DIR/kernel.bin" --oldblob "$KERNEL_TMP_DIR/stock.bin" \
  --keyblock "$KB" --signprivate "$SK" --config "$KERNEL_TMP_DIR/cmdline" --flags 0
futility vbutil_kernel --verify "$KERNEL_TMP_DIR/kernel.bin"
(( $(stat -c %s "$KERNEL_TMP_DIR/kernel.bin") <= 64 * 1024 * 1024 )) || die "Signed kernel exceeds the 64 MiB kernel partition."

echo "== Enabling developer-mode USB boot..."
tarkin_enable_usb_boot || die "crossystem did not enable USB boot of developer-signed kernels (see the line above)."
echo "   $(tarkin_usb_boot_state) dev_boot_signed_only=$(crossystem dev_boot_signed_only)"

unmount_all() {
  local p _
  for p in "$DEV"?*; do
    [[ -b "$p" ]] || continue
    for _ in 1 2 3; do
      findmnt -rn -S "$p" >/dev/null 2>&1 || break
      umount "$p" 2>/dev/null \
        || { command -v udisksctl >/dev/null 2>&1 && udisksctl unmount -b "$p" >/dev/null 2>&1; } \
        || sleep 1
    done
  done
  return 0
}
release_stick() {
  local b="" _
  for _ in 1 2 3 4 5; do
    unmount_all
    settle
    b="$(busy_list)"
    [[ -n "$b" ]] || return 0
    sleep 2
  done
  stop_busy "$b" "$1" "$2"
}
reread_table() {
  sync
  blockdev --flushbufs "$DEV" 2>/dev/null || true
  if command -v partx >/dev/null 2>&1 && partx -u "$DEV" 2>/dev/null; then
    :
  elif command -v partprobe >/dev/null 2>&1 && partprobe "$DEV" 2>/dev/null; then
    :
  else
    blockdev --rereadpt "$DEV" 2>/dev/null || true
  fi
  settle
}
wipe_old_signatures() {
  local name start p
  name="$(basename "$DEV")"
  for p in "$TARKIN_SYS/block/$name/$name"*; do
    start="$(cat "$p/start" 2>/dev/null || true)"
    [[ "$start" =~ ^[0-9]+$ ]] || continue
    dd if=/dev/zero of="$DEV" bs=512 seek="$start" count=8192 conv=notrunc,fsync status=none 2>/dev/null || true
  done
  dd if=/dev/zero of="$DEV" bs=512 seek=139264 count=8192 conv=notrunc,fsync status=none
}
echo "== Unmounting existing partitions on $DEV..."
release_stick "partitioned or formatted" "Nothing was written to it."

if (( RESUMING )) && step_done partition; then
  echo "== [resume] Partition table of $DEV already written; kept."
  cgpt show "$DEV"
else
  echo "== Partitioning $DEV (ChromeOS GPT: p1 kernel, p2 root)..."
  state_del "${FS_STEPS[@]}" STEP_partition STICK_PARTUUID
  total_sectors="$(blockdev --getsz "$DEV")"
  (( total_sectors > 139264 + 4 * 2097152 )) || die "USB device is too small (the system needs about 4 GiB on the stick; 8 GiB or more is recommended, 16 GiB comfortable)."
  wipe_old_signatures
  cgpt create "$DEV"
  cgpt boot -p "$DEV"
  cgpt add -i 1 -t kernel -b 8192 -s 131072 -l KERN-A -S 1 -T 1 -P 15 "$DEV"
  cgpt add -i 2 -t data -b 139264 -s $((total_sectors - 139264 - 2048)) -l ALARM "$DEV"
  expected2=$((total_sectors - 139264 - 2048))
  size2=0
  for _ in 1 2 3 4 5; do
    reread_table
    size2="$(blockdev --getsz "$part2" 2>/dev/null || echo 0)"
    (( size2 >= expected2 - 4096 )) && break
    unmount_all
    sleep 2
  done
  cgpt show "$DEV"
  [[ -b "$part1" && -b "$part2" ]] || die "Partition device nodes did not appear for $DEV."
  if (( size2 < expected2 - 4096 )); then
    busy="$(busy_list)"
    [[ -z "$busy" ]] || stop_busy "$busy" "formatted" "The kernel still sees the OLD partition table because of this."
  fi
  (( size2 >= expected2 - 4096 )) \
    || die "The kernel still sees the OLD partition table ($part2 is $size2 sectors, expected about $expected2). Nothing was written to it. Unplug the stick, plug it in again WITHOUT opening the Files app, then run the installer again."
  state_set STICK_PARTUUID "$(cgpt show -i 2 -u "$DEV" | tr '[:upper:]' '[:lower:]')"
  mark_done partition
fi
[[ -b "$part1" && -b "$part2" ]] || die "Partition device nodes $part1 / $part2 are missing. Unplug and replug the stick, then run again."

STICK_MARK_DIR="$MNT/var/lib/tarkin"
STICK_MARK="$STICK_MARK_DIR/install-extracted"
if (( RESUMING )) && step_done extract; then
  echo "== [resume] Root filesystem already extracted; mounting it."
  release_stick "mounted" "The extracted files on it are kept."
  mkdir -p "$MNT"
  mount "$part2" "$MNT"
  [[ -f "$STICK_MARK" ]] \
    || die "The progress file says the rootfs was extracted, but $part2 does not carry the marker. Start over without resuming (answer n when asked), which erases the stick again."
else
  echo "== Formatting $part2 as ext4 (label ALARM)..."
  state_del "${FS_STEPS[@]}"
  release_stick "formatted" "The partition table is written; run the same command again to resume."
  if ! mkfs.ext4 -F -L ALARM "$part2"; then
    echo "[!] mkfs.ext4 refused $part2; checking again what holds it..." >&2
    release_stick "formatted" "The partition table is written; run the same command again to resume."
    mkfs.ext4 -F -L ALARM "$part2" \
      || die "mkfs.ext4 still refuses $part2 and no program, mount, swap or device-mapper was found on it. Unplug the stick, plug it in again without opening the Files app, then run the same command again."
  fi
  mkdir -p "$MNT"
  mount "$part2" "$MNT"
  avail_kb="$(df -Pk "$MNT" | awk 'NR==2 {print $4}')"
  (( avail_kb >= 3 * 1048576 )) || die "Only $((avail_kb / 1024)) MiB free on the new root filesystem (need 3 GiB). Unplug and replug the stick, then run the installer again."
  echo "== Extracting the Arch Linux ARM rootfs..."
  bsdtar -xpf "$ARCHIVE" -C "$MNT"
  sync
  mkdir -p "$STICK_MARK_DIR"
  date -u +%FT%TZ > "$STICK_MARK"
  sync
  mark_done extract
fi
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$part2")"
[[ -n "$ROOT_PARTUUID" ]] || die "Could not read PARTUUID for $part2."

echo "== Installing Tarkin configuration..."
printf 'PARTUUID=%s / ext4 defaults,noatime 0 1\n' "$ROOT_PARTUUID" > "$MNT/etc/fstab"
echo "asus-cm1406" > "$MNT/etc/hostname"
cp -R --no-preserve=ownership "$REPO_ROOT/rootfs/." "$MNT/"
( cd "$REPO_ROOT/rootfs" && find . -type f ) | while read -r f; do
  chown 0:0 "$MNT/$f"
  case "$f" in ./usr/local/bin/*|./usr/local/libexec/*) chmod 755 "$MNT/$f" ;; *) chmod 644 "$MNT/$f" ;; esac
done
( cd "$REPO_ROOT/rootfs" && find . -type l ) | while read -r f; do
  chown -h 0:0 "$MNT/$f"
done
ALARM_UID="$(awk -F: '$1 == "alarm" { print $3 }' "$MNT/etc/passwd")"
ALARM_GID="$(awk -F: '$1 == "alarm" { print $4 }' "$MNT/etc/passwd")"
ALARM_UID="${ALARM_UID:-1000}"; ALARM_GID="${ALARM_GID:-1000}"
[[ -d "$MNT/home/alarm" ]] || die "The rootfs has no /home/alarm: this is not the Arch Linux ARM aarch64 image."
install -m 755 "$REPO_ROOT/scripts/install-desktop.sh" "$MNT/home/alarm/install-desktop.sh"
install -m 755 "$REPO_ROOT/install-hyprland.sh" "$MNT/home/alarm/install-hyprland.sh"
install -m 755 "$REPO_ROOT/install-xfce.sh" "$MNT/home/alarm/install-xfce.sh"
install -m 755 "$REPO_ROOT/install-gpuapp.sh" "$MNT/home/alarm/install-gpuapp.sh"
install -m 755 "$REPO_ROOT/install-niri.sh" "$MNT/home/alarm/install-niri.sh"
install -m 755 "$REPO_ROOT/scripts/upgrade-stick.sh" "$MNT/home/alarm/upgrade-stick.sh"
install -m 755 "$REPO_ROOT/scripts/install-vitrum-plus-niri-v10.sh" "$MNT/home/alarm/install-vitrum-plus-niri-v10.sh"
install -D -m 755 "$REPO_ROOT/choose-desktop.sh" "$MNT/usr/local/bin/tarkin-desktop"
chown 0:0 "$MNT/usr/local/bin/tarkin-desktop"
chown "$ALARM_UID:$ALARM_GID" "$MNT/home/alarm/install-desktop.sh" "$MNT/home/alarm/install-hyprland.sh" "$MNT/home/alarm/upgrade-stick.sh" "$MNT/home/alarm/install-xfce.sh" "$MNT/home/alarm/install-gpuapp.sh" "$MNT/home/alarm/install-niri.sh" "$MNT/home/alarm/install-vitrum-plus-niri-v10.sh"
BASHRC="$MNT/home/alarm/.bashrc"
if [[ ! -f "$BASHRC" && -f "$MNT/etc/skel/.bashrc" ]]; then
  cp "$MNT/etc/skel/.bashrc" "$BASHRC"
fi
if ! grep -qs 'tarkin/shell-notice' "$BASHRC"; then
  printf '\n# Tarkin: first-boot progress and boot warnings\n[ -r /usr/local/libexec/tarkin/shell-notice ] && . /usr/local/libexec/tarkin/shell-notice\n' >> "$BASHRC"
fi
chown "$ALARM_UID:$ALARM_GID" "$BASHRC"
mkdir -p "$MNT/etc/tarkin"
printf 'XKB_DEFAULT_LAYOUT=%s\nTARKIN_SESSION=terminal\nTARKIN_HYPR_RENDER=auto\n' "$KEYMAP" > "$MNT/etc/tarkin/console.env"
chmod 644 "$MNT/etc/tarkin/console.env"
printf '%s\n' "$TARKIN_VERSION" > "$MNT/etc/tarkin/version"
chmod 644 "$MNT/etc/tarkin/version"
mkdir -p "$MNT/var/lib/systemd/linger"; : > "$MNT/var/lib/systemd/linger/alarm"

mkdir -p "$MNT/var/log/journal"

if [[ "$(state_get MODULES_KVER)" == "$KVER" ]]; then
  echo "== [resume] ChromeOS kernel modules ($KVER) and firmware already copied."
else
  echo "== Copying ChromeOS kernel modules ($KVER) and firmware..."
  mkdir -p "$MNT/usr/lib/modules" "$MNT/usr/lib/firmware/updates"
  cp -a "/lib/modules/$KVER" "$MNT/usr/lib/modules/"
  cp -a /lib/firmware/. "$MNT/usr/lib/firmware/updates/"
  sync
  state_set MODULES_KVER "$KVER"
fi

FW_DIR="$MNT/usr/lib/firmware/updates/mediatek/mt7925"
mkdir -p "$FW_DIR"
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
for blob in WIFI_MT7925_PATCH_MCU_1_1_hdr.bin WIFI_RAM_CODE_MT7925_1_1.bin BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  if [[ ! -s "$FW_DIR/$blob" ]]; then
    echo "   [!] $blob missing from ChromeOS, downloading..."
    curl "${CURL_OPTS[@]}" --max-time 90 "$FW_URL/$blob" -o "$FW_DIR/$blob" \
      || { rm -f "$FW_DIR/$blob"; echo "   [!] $blob unavailable: Wi-Fi may not come up." >&2; }
  fi
done

mkdir -p "$MNT/etc/systemd/network"
cat > "$MNT/etc/systemd/network/wlan.network" <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
EOF

WPA_CONF="$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
if (( ! SKIP_WIFI )) && [[ -n "$WIFI_SSID" ]]; then
  echo "== Configuring Wi-Fi for '$WIFI_SSID'..."
  mkdir -p "$MNT/etc/wpa_supplicant"
  ( umask 077
    {
      echo "ctrl_interface=/run/wpa_supplicant"
      echo "update_config=1"
      [[ -z "${WIFI_COUNTRY:-}" ]] || echo "country=$WIFI_COUNTRY"
      echo "network={"
      echo "  ssid=$(printf '%s' "$WIFI_SSID" | od -An -tx1 -v | tr -d ' \n')"
      echo "  psk=\"$WIFI_PASS\""
      echo "  key_mgmt=WPA-PSK"
      echo "}"
    } > "$WPA_CONF" )
  chmod 600 "$WPA_CONF"
fi

PKG_OK=1
if [[ "${ALLOW_NO_PKGS:-0}" == 1 ]]; then
  echo "[i] ALLOW_NO_PKGS=1: skipping the package install entirely (no terminal, no Wi-Fi tools on the stick)."
elif step_done packages && [[ -x "$MNT/usr/bin/cage" && -x "$MNT/usr/bin/sudo" ]]; then
  echo "== [resume] Packages already installed on the stick."
else
  echo "== Installing the terminal (cage, foot, seatd), Wi-Fi tools and sudo in the new rootfs (isolated chroot, needs network)..."
  sync
  mask_hooks
  rm -f "$MNT/var/lib/pacman/db.lck"
  resolv_saved=0
  if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
    mv -f "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.orig"; resolv_saved=1
  fi
  cp /etc/resolv.conf "$MNT/etc/resolv.conf" || true
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >> "$MNT/etc/resolv.conf"
  in_chroot /bin/bash -c 'pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1 && pacman -Syu --noconfirm --noprogressbar --needed --ignore linux-aarch64,linux-aarch64-headers wpa_supplicant iw pciutils seatd cage foot foot-terminfo ttf-dejavu sudo nano' \
    || { PKG_OK=0; echo "[!] Package install failed (no network from this shell?)." >&2; }
  sync
  [[ -x "$MNT/usr/bin/wpa_supplicant" && -x "$MNT/usr/bin/cage" && -x "$MNT/usr/bin/foot" && -x "$MNT/usr/bin/seatd" && -x "$MNT/usr/bin/sudo" ]] || PKG_OK=0
  unmask_hooks
  rm -f "$MNT/etc/resolv.conf"
  (( resolv_saved == 0 )) || rm -f "$MNT/etc/resolv.conf.orig"
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
  restore_sysctl
  throttle_writeback
  if (( PKG_OK )); then mark_done packages; fi
fi

[[ -x "$MNT/usr/bin/usermod" && -x "$MNT/usr/bin/chpasswd" && -x "$MNT/usr/bin/passwd" ]] \
  || die "usermod/chpasswd/passwd are missing from the rootfs: this is not a complete Arch Linux ARM image."
for g in video input render audio seat wheel; do
  in_chroot getent group "$g" >/dev/null 2>&1 || { in_chroot groupadd -r "$g" 2>/dev/null || true; }
  in_chroot usermod -aG "$g" alarm || echo "[!] Could not add the user alarm to group $g." >&2
done
for g in video input render audio seat; do
  in_chroot getent group "$g" >/dev/null 2>&1 \
    || echo "[!] Group $g is still missing in the rootfs: tarkin-console.service lists it and will fail with 216/GROUP. Run scripts/check-usb.sh after booting ChromeOS." >&2
done
[[ -d "$MNT/etc/sudoers.d" ]] || install -d -m 750 "$MNT/etc/sudoers.d"
echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"; chmod 440 "$MNT/etc/sudoers.d/10-wheel"

SUDO_OK=0
alarm_groups=" $(in_chroot id -nG alarm 2>/dev/null || true) "
if [[ -x "$MNT/usr/bin/sudo" && -x "$MNT/usr/bin/visudo" && "$alarm_groups" == *" wheel "* ]] \
   && in_chroot /usr/bin/visudo -c >/dev/null 2>&1; then
  SUDO_OK=1
fi

if (( NEED_PASSWORD )); then
  printf 'alarm:%s\n' "$USER_PASS" | in_chroot chpasswd \
    || die "Could not set the password of alarm on the stick."
  if (( ! SUDO_OK )); then
    printf 'root:%s\n' "$USER_PASS" | in_chroot chpasswd || die "Could not set the root password on the stick."
    echo "   [!] sudo is not usable on the stick, so root is NOT locked: root now has the same password as alarm."
  fi
  USER_PASS=""
  mark_done password
  echo "   Password set for alarm."
fi
if (( SUDO_OK )); then
  in_chroot passwd -l root >/dev/null 2>&1 || die "Could not lock the root account on the stick."
  echo "   sudo works for alarm (wheel group, sudoers checked); root login locked."
fi

if (( ! SKIP_WIFI )); then
  mark_done wifi
fi
if [[ -f "$WPA_CONF" && -x "$MNT/usr/bin/wpa_passphrase" ]] && grep -q '^  psk="' "$WPA_CONF"; then
  conf_pass="$(sed -n 's/^  psk="\(.*\)"$/\1/p' "$WPA_CONF" | head -n 1)"
  conf_ssid_hex="$(sed -n 's/^  ssid=\([0-9a-f]*\)$/\1/p' "$WPA_CONF" | head -n 1)"
  hashed=""
  if [[ -n "$conf_pass" && -n "$conf_ssid_hex" ]]; then
    conf_ssid="$(printf '%b' "$(sed 's/\(..\)/\\x\1/g' <<<"$conf_ssid_hex")")"
    hashed="$(printf '%s\n' "$conf_pass" | in_chroot /usr/bin/wpa_passphrase "$conf_ssid" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')" || hashed=""
  fi
  if [[ "$hashed" =~ ^[0-9a-f]{64}$ ]]; then
    sed -i "s/^  psk=.*/  psk=$hashed/" "$WPA_CONF"
    echo "   Wi-Fi passphrase stored as a hashed PSK."
  else
    echo "   [!] Could not hash the Wi-Fi passphrase; it stays in the root-only (0600) config file."
  fi
  conf_pass=""
fi
sync

WANTS="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS" "$MNT/etc/systemd/system/timers.target.wants"
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/sshd.service"
enable_unit() {
  local unit="$1" dir="$2" link="${3:-$(basename "$1")}"
  if [[ -f "$MNT$unit" ]]; then ln -sfn "$unit" "$dir/$link"; else echo "[!] Unit unavailable in the rootfs: $unit" >&2; fi
}
enable_unit /usr/lib/systemd/system/systemd-networkd.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-resolved.service "$WANTS"
enable_unit /usr/lib/systemd/system/systemd-timesyncd.service "$WANTS"
enable_unit /usr/lib/systemd/system/seatd.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-touchpad.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-console.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-bootcheck.service "$WANTS"
enable_unit /etc/systemd/system/tarkin-bootlog.timer "$MNT/etc/systemd/system/timers.target.wants"
if [[ -f "$WPA_CONF" ]]; then
  enable_unit /usr/lib/systemd/system/wpa_supplicant@.service "$WANTS" wpa_supplicant@wlan0.service
fi

if (( DESKTOP )) && (( PKG_OK )) && [[ "${ALLOW_NO_PKGS:-0}" != 1 ]]; then
  if [[ ! -f "$MNT/var/lib/tarkin/firstboot.done" ]]; then
    mkdir -p "$MNT/var/lib/tarkin"
    date -u +%FT%TZ > "$MNT/var/lib/tarkin/firstboot.pending"
    rm -f "$MNT/var/lib/tarkin/firstboot.failed" "$MNT/var/lib/tarkin/firstboot.attempts" "$MNT/var/lib/tarkin/firstboot.reason"
    enable_unit /etc/systemd/system/tarkin-firstboot.service "$WANTS"
    echo "== First-boot setup staged: the Mali GPU stack and sound are installed at the first boot."
  fi
  if [[ "$WM" != none ]]; then
    printf 'FIRSTBOOT_WM=%s\n' "$WM" > "$MNT/etc/tarkin/firstboot.conf"
    chmod 644 "$MNT/etc/tarkin/firstboot.conf"
    echo "== $WM chosen: set up at the first boot, then started at boot (other choice later: tarkin-desktop)."
  elif [[ "$(cat "$MNT/etc/tarkin/firstboot.conf" 2>/dev/null)" =~ ^FIRSTBOOT_WM=(niri|hyprland)$ ]]; then
    rm -f "$MNT/etc/tarkin/firstboot.conf"
  fi
else
  rm -f "$MNT/var/lib/tarkin/firstboot.pending" "$WANTS/tarkin-firstboot.service"
  (( DESKTOP )) && echo "[!] First-boot setup NOT staged (packages missing). After booting: tarkin-desktop" >&2
fi
sync

echo "== Writing the signed kernel to $part1..."
dd if="$KERNEL_TMP_DIR/kernel.bin" of="$part1" bs=1M conv=fsync status=progress
sync

echo "== Verifying what was written to $part1..."
ksize="$(stat -c %s "$KERNEL_TMP_DIR/kernel.bin")"
dd if="$part1" of="$KERNEL_TMP_DIR/readback.bin" bs=1M count=$(( (ksize + 1048575) / 1048576 )) status=none
head -c "$ksize" "$KERNEL_TMP_DIR/readback.bin" > "$KERNEL_TMP_DIR/readback.trim"
[[ "$(md5sum < "$KERNEL_TMP_DIR/readback.trim" | awk '{print $1}')" == "$(md5sum < "$KERNEL_TMP_DIR/kernel.bin" | awk '{print $1}')" ]] \
  || die "The kernel read back from $part1 differs from what was written. Try another USB port or stick."
futility vbutil_kernel --verify "$KERNEL_TMP_DIR/readback.trim" >/dev/null || die "The kernel on $part1 does not verify."
cgpt add -i 1 -S 1 -T 1 -P 15 "$DEV"
cgpt show "$DEV"
echo "   Kernel on $part1: written and verified."

if [[ "$PKG_OK" != 1 && "${ALLOW_NO_PKGS:-0}" != 1 ]]; then
  cat <<'WARN'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
[!] WARNING: the packages (wpa_supplicant, cage, foot, seatd, sudo, ...) could NOT all
    be installed on the stick. The system will probably boot but may have no
    on-screen terminal and no Wi-Fi tools.
    Fix the network (see README, "Troubleshooting") and run the same command again:
        sudo bash install.sh     (it resumes and retries only the package step)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARN
  RESUMABLE=0
  exit 1
fi
mark_done complete
RESUMABLE=0
if (( DESKTOP )) && [[ -f "$MNT/var/lib/tarkin/firstboot.pending" && "$WM" == niri ]]; then
  FIRSTBOOT_TEXT="    Then, by itself (needs Wi-Fi, 20 to 60 minutes): the Mali GPU stack, sound, niri and Vitrum Plus
    are installed (progress: tail -f /var/log/tarkin-firstboot.log), then the machine restarts once into
    niri. Do not power off while it works. Other desktop later: tarkin-desktop"
elif (( DESKTOP )) && [[ -f "$MNT/var/lib/tarkin/firstboot.pending" && "$WM" == hyprland ]]; then
  FIRSTBOOT_TEXT="    Then, by itself (needs Wi-Fi, 20 to 60 minutes): the Mali GPU stack, sound and Hyprland are
    installed (progress: tail -f /var/log/tarkin-firstboot.log), then the machine restarts once into
    Hyprland. Do not power off while it works. Other desktop later: tarkin-desktop"
elif (( DESKTOP )) && [[ -f "$MNT/var/lib/tarkin/firstboot.pending" ]]; then
  FIRSTBOOT_TEXT="    Then, by itself (needs Wi-Fi, 20 to 60 minutes): the Mali GPU stack and sound are installed
    (progress: tail -f /var/log/tarkin-firstboot.log), then the machine restarts once into the terminal.
    Do not power off while it works. Then choose the desktop: tarkin-desktop (niri + Vitrum Plus, or Hyprland)"
else
  FIRSTBOOT_TEXT="    Optional GPU desktop (Wi-Fi first): tarkin-desktop"
fi
cat <<EOF
==========================================================
[+] USB written: $DEV   (boot-arch-linux-on-CM1406 v$TARKIN_VERSION)

Boot it:
 1. Leave the stick plugged in and power the Chromebook off, then on.
 2. At the 'OS verification is OFF' screen press Ctrl+U (or pick "Boot from external disk").
 3. Wait 1-2 minutes: a terminal appears on the screen (the firmware logo may stay up for a while).
$FIRSTBOOT_TEXT
    Password (sudo): the one you chose. Root login is locked. Wi-Fi: sudo tarkin-wifi "Network".
    If the screen stays black or frozen on the logo for 3 minutes, power off, then see README, "Troubleshooting".

If nothing works: hold the power button, unplug the stick, then press Ctrl+D to boot ChromeOS.
To see what happened: run  sudo bash scripts/check-usb.sh  in ChromeOS (see README, "Troubleshooting").
After a ChromeOS update, if the stick no longer boots:  sudo bash scripts/repair-boot.sh
The downloaded rootfs stays in $DL_DIR for the next stick (remove it with: sudo rm -rf $DL_DIR).
==========================================================
EOF
