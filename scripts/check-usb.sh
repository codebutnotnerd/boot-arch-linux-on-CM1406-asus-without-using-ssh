#!/bin/bash
[[ $EUID -eq 0 ]] || { echo "Run as root:  sudo bash scripts/check-usb.sh" >&2; exit 1; }
KERNEL_GUID="fe3a2a5d-4f32-41a7-b725-accc3285a309"
bad=0
ok()  { echo "  [OK]      $*"; }
warn(){ echo "  [PROBLEM] $*"; bad=1; }

DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  for d in /sys/block/sd*; do
    [[ -e "$d" && "$(readlink -f "$d")" == *"/usb"* ]] && { DEV="/dev/$(basename "$d")"; break; }
  done
fi
[[ -b "$DEV" ]] || { echo "[-] No USB drive (stick or external SSD) found. Plug it in (and try another port) or pass /dev/sdX." >&2; dmesg | tail -8; exit 1; }
case "$DEV" in *mmcblk*) echo "[-] Refusing the internal disk." >&2; exit 1;; esac
P1="${DEV}1"; P2="${DEV}2"; [[ "$DEV" =~ [0-9]$ ]] && { P1="${DEV}p1"; P2="${DEV}p2"; }
echo "== Stick: $DEV"

echo "== Firmware flags"
up="$(crossystem dev_boot_usb 2>&1)"; so="$(crossystem dev_boot_signed_only 2>&1)"; mf="$(crossystem mainfw_type 2>&1)"
[[ "$up" == 1* ]] && ok "dev_boot_usb=1" || warn "dev_boot_usb=$up (need 1):  sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0"
[[ "$so" == 0* ]] && ok "dev_boot_signed_only=0" || warn "dev_boot_signed_only=$so (need 0)"
[[ "$mf" == developer ]] && ok "mainfw_type=developer" || warn "mainfw_type=$mf (need developer)"

echo "== Partition table"
cgpt show "$DEV"
cgpt show -i 1 -t "$DEV" 2>/dev/null | grep -qi "$KERNEL_GUID" \
  && ok "partition 1 is a ChromeOS kernel partition" \
  || warn "partition 1 is not of type ChromeOS kernel: the firmware will say 'no valid image'. Re-run the installer."
echo "  priority=$(cgpt show -i 1 -P "$DEV") tries=$(cgpt show -i 1 -T "$DEV") successful=$(cgpt show -i 1 -S "$DEV")"
[[ "$(cgpt show -i 1 -P "$DEV")" -ge 1 ]] 2>/dev/null && ok "kernel priority >= 1" || warn "kernel priority is 0: the firmware skips this partition"

echo "== Kernel signature"
T="$(mktemp /var/tmp/chk-kern.XXXXXX)"
dd if="$P1" of="$T" bs=1M count=64 status=none
if out="$(futility vbutil_kernel --verify "$T" 2>&1)"; then
  ok "kernel verifies"; echo "$out" | sed -n '/Flags/p;/Body verification/p;/^Config:/,$p' | sed 's/^/        /'
else
  warn "kernel does NOT verify: $out"
fi
rm -f "$T"

echo "== Root filesystem"
M="$(mktemp -d /var/tmp/chk-root.XXXXXX)"
if mount -o ro "$P2" "$M" 2>/dev/null; then
  PU="$(blkid -s PARTUUID -o value "$P2")"
  if [[ -n "$PU" && "$(grep -c "$PU" "$M/etc/fstab" 2>/dev/null || echo 0)" -ge 1 ]]; then
    ok "fstab matches the root PARTUUID"
  else
    warn "fstab does not match the root PARTUUID: the kernel will not find the root (kernel panic at boot)"
  fi
  [[ -x "$M/usr/bin/cage" && -x "$M/usr/bin/foot" && -x "$M/usr/bin/seatd" ]] && ok "cage, foot and seatd installed" || warn "cage/foot/seatd NOT installed: no on-screen terminal (re-run the installer with working internet)"
  [[ -f "$M/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" ]] && ok "Wi-Fi configuration present" || echo "  [info]    no Wi-Fi configured (use: sudo tarkin-wifi \"Name\" in the terminal)"
  [[ -x "$M/usr/bin/wpa_supplicant" ]] && ok "wpa_supplicant installed" || warn "wpa_supplicant NOT installed: the stick will have no Wi-Fi tools (re-run the installer with working internet)"
  cmode="$(cat "$M/etc/tarkin/console-mode" 2>/dev/null || echo graphical)"
  if [[ "$cmode" == dm ]]; then
    ok "console mode: dm (a display manager owns the console)"
    [[ -e "$M/etc/systemd/system/multi-user.target.wants/tarkin-dm-fallback.service" ]] \
      && ok "tarkin-dm-fallback enabled (starts tarkin-console when no display manager runs)" \
      || warn "tarkin-dm-fallback is NOT enabled: if the display manager fails, the panel stays black"
    if [[ -e "$M/etc/systemd/system/display-manager.service" ]]; then
      ok "display manager enabled: $(basename "$(readlink -f "$M/etc/systemd/system/display-manager.service")")"
      [[ -f "$M/etc/sddm.conf.d/10-tarkin.conf" ]] \
        && ok "sddm configured for the X11 greeter (software rendering)" \
        || warn "no /etc/sddm.conf.d/10-tarkin.conf: sddm may try the Wayland greeter, which needs EGL"
      [[ -x "$M/usr/bin/Xorg" && -x "$M/usr/bin/sddm" ]] \
        && ok "Xorg and sddm installed" \
        || warn "Xorg/sddm missing from the rootfs: the greeter cannot start (run 'bash ~/install-xfce.sh' on the stick)"
      [[ -f "$M/home/alarm/.dmrc" ]] \
        && ok "XFCE set as the default session for alarm" \
        || echo "  [info]    no /home/alarm/.dmrc: sddm will offer the session menu without a default"
    else
      echo "  [info]    no display manager enabled: the stick boots to tarkin-console. Run 'bash ~/install-xfce.sh' on it"
    fi
    [[ -e "$M/etc/systemd/system/multi-user.target.wants/tarkin-console.service" ]] \
      && warn "tarkin-console is also enabled while a display manager is in charge: they will fight over the DRM node (black screen). Use 'systemctl disable tarkin-console'"
  else
    [[ -e "$M/etc/systemd/system/multi-user.target.wants/tarkin-console.service" && -e "$M/etc/systemd/system/multi-user.target.wants/seatd.service" ]] && ok "console and seatd services enabled" || warn "console/seatd services not enabled"
  fi
  if [[ "$cmode" == graphical ]]; then
    [[ -s "$M/etc/tarkin/console.env" ]] && ok "keyboard layout: $(cat "$M/etc/tarkin/console.env")" || warn "keyboard layout file missing"
  fi
  kv="$(uname -r)"; [[ -d "$M/usr/lib/modules/$kv" ]] && ok "kernel modules for $kv present" || warn "modules for $kv missing"
  ls "$M/usr/lib/firmware/updates/mediatek/mt7925/" >/dev/null 2>&1 && ok "MT7925 firmware present" || warn "MT7925 firmware missing"

  svc="$M/etc/systemd/system/tarkin-console.service"
  if [[ -f "$svc" && "$cmode" != dm ]]; then
    suser="$(sed -n 's/^User=//p' "$svc" | head -1)"
    sgroup="$(sed -n 's/^Group=//p' "$svc" | head -1)"
    sgroups="$(sed -n 's/^SupplementaryGroups=//p' "$svc" | head -1)"
    if [[ -n "$suser" ]]; then
      grep -q "^$suser:" "$M/etc/passwd" 2>/dev/null && ok "service user '$suser' exists in the rootfs" || warn "service user '$suser' does not exist in the rootfs /etc/passwd: the service fails at step USER"
    fi
    for g in $sgroup $sgroups; do
      if grep -q "^$g:" "$M/etc/group" 2>/dev/null; then
        ok "group '$g' exists in the rootfs"
      else
        warn "group '$g' is listed in tarkin-console.service but missing from the rootfs /etc/group: the service dies with 216/GROUP 'Failed to determine supplementary groups' (black screen). Fix: re-run the installer (it creates missing groups), or mount the root rw and run: groupadd -r $g"
      fi
    done
    [[ -e "$M/var/lib/systemd/linger/alarm" ]] && ok "linger enabled for the alarm user (/run/user/<uid> will exist)" || warn "no linger for the alarm user: /run/user/<uid> never appears and the terminal cannot start (cage needs XDG_RUNTIME_DIR)"
  else
    warn "tarkin-console.service not found in the rootfs"
  fi

  sysctl_file="$M/etc/sysctl.d/90-tarkin-panic.conf"
  if grep -qE '^[[:space:]]*kernel\.hung_task_panic[[:space:]]*=[[:space:]]*0' "$sysctl_file" 2>/dev/null; then
    ok "panic-on-hung-task disabled (a slow USB flush can no longer reboot mid-transaction)"
  else
    warn "kernel.hung_task_panic is NOT 0 in $sysctl_file: a slow USB writeback can panic and reboot in the middle of a pacman transaction (this is what left the screen black). Re-run the installer or add: kernel.hung_task_panic = 0"
  fi

  if [[ -e "$M/etc/systemd/system/multi-user.target.wants/sshd.service" ]]; then
    warn "sshd is enabled on the stick and the default account is alarm/alarm: disable it (mount the root rw, rm that symlink)"
  else
    ok "sshd is not enabled"
  fi
  if [[ "$cmode" == graphical && -e "$M/etc/systemd/system/display-manager.service" ]]; then
    warn "a display manager is enabled on the stick: it will fight seatd/tarkin-console for the DRM node (black screen). Reinstall with --console dm if you want one"
  fi

  [[ -f "$M/etc/modules-load.d/tarkin-input.conf" ]] \
    && ok "touchpad modules requested at boot (i2c-hid, hid-multitouch)" \
    || echo "  [info]    no /etc/modules-load.d/tarkin-input.conf: the Elan touchpad may bind to the generic HID driver"
  [[ -x "$M/usr/local/libexec/tarkin/touchpad-bind" && -f "$M/etc/systemd/system/tarkin-touchpad.service" ]] \
    && ok "touchpad rebind service present (tarkin-touchpad.service)" \
    || echo "  [info]    tarkin-touchpad.service is missing: the touchpad may stay on hid-generic"

  if [[ -f "$M/var/log/tarkin-boot.log" ]]; then
    echo "== Last boot report from the stick (/var/log/tarkin-boot.log, first 40 lines)"; head -40 "$M/var/log/tarkin-boot.log"
  else
    echo "  (no tarkin-boot.log: the system never got as far as running userspace)"
  fi
  umount "$M"
else
  warn "cannot mount $P2 (not ext4 or not written)"
fi
rmdir "$M" 2>/dev/null

echo "== Crash log of the previous boot (pstore)"
if ls /sys/fs/pstore/* >/dev/null 2>&1; then
  ls -l /sys/fs/pstore/
  for f in /sys/fs/pstore/console-ramoops*; do [[ -f "$f" ]] && { echo "--- tail of $f"; tail -60 "$f"; }; done
else
  echo "  none (the kernel did not crash, or the firmware rejected the stick before starting it)"
fi

echo
[[ $bad == 0 ]] && echo "Result: the stick looks correct. If the firmware still refuses it, send this whole output." \
                 || echo "Result: fix the [PROBLEM] lines above, then try again."
