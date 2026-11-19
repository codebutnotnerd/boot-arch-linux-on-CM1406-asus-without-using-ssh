#!/bin/bash
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 1 ]] || { echo "Usage (ChromeOS VT2): sudo bash scripts/recover-display.sh /usr/local/alarm" >&2; exit 1; }
R="${1%/}"
[[ "$R" != / && -f "$R/etc/arch-release" &&
   -f "$R/etc/systemd/system/tarkin-console.service" &&
   -x "$R/usr/local/libexec/tarkin/console" &&
   -x "$R/usr/local/libexec/tarkin/display-guard" ]] || {
  echo "Wrong root or incomplete v1.40 tools: stop and check the mount." >&2
  exit 1
}
dm="$R/etc/systemd/system/display-manager.service"
if [[ -e "$dm" || -L "$dm" ]]; then
  [[ -L "$dm" ]] || { echo "Unrecognised display-manager alias: inspect it, nothing was overwritten." >&2; exit 1; }
  case "$(readlink "$dm")" in
    /usr/lib/systemd/system/sddm.service|/usr/lib/systemd/system/gdm.service) rm "$dm" ;;
    *) echo "Unknown display manager: inspect its configuration by hand." >&2; exit 1 ;;
  esac
fi
shopt -s nullglob
for link in "$R"/etc/systemd/system/*.{wants,requires}/{sddm,gdm,tarkin-dm-fallback,tarkin-firstboot}.service; do
  [[ -L "$link" ]] || { echo "Unexpected unit: $link" >&2; exit 1; }
  case "$(readlink "$link")" in
    /usr/lib/systemd/system/sddm.service|/usr/lib/systemd/system/gdm.service|/etc/systemd/system/tarkin-dm-fallback.service|/etc/systemd/system/tarkin-firstboot.service) rm "$link" ;;
    *) echo "Unknown link: $link; inspect it, nothing was overwritten." >&2; exit 1 ;;
  esac
done
mkdir -p "$R/etc/tarkin" "$R/etc/systemd/system/multi-user.target.wants"
for f in "$R/etc/tarkin/console.env" "$R/etc/tarkin/display-owner"; do
  [[ ! -L "$f" && ( ! -e "$f" || -f "$f" ) ]] || {
    echo "Unexpected file: $f; inspect it, nothing was overwritten." >&2; exit 1;
  }
done
for f in "$R/etc/systemd/system/default.target" "$R/etc/systemd/system/multi-user.target.wants/tarkin-console.service"; do
  [[ ! -e "$f" || -L "$f" ]] || {
    echo "Expected a symlink: $f; inspect it, nothing was overwritten." >&2; exit 1;
  }
done
envfile="$R/etc/tarkin/console.env"
tmp="$(mktemp "$R/etc/tarkin/.recovery.XXXXXX")"
[[ ! -f "$envfile" ]] || sed '/^TARKIN_SESSION=/d' "$envfile" > "$tmp"
printf 'TARKIN_SESSION=terminal\n' >> "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$envfile"
printf 'terminal\n' > "$R/etc/tarkin/display-owner"
ln -sfn /etc/systemd/system/tarkin-console.service "$R/etc/systemd/system/multi-user.target.wants/tarkin-console.service"
ln -sfn /usr/lib/systemd/system/multi-user.target "$R/etc/systemd/system/default.target"
for marker in pending failed; do
  f="$R/var/lib/tarkin/firstboot.$marker"
  [[ ! -f "$f" ]] || mv "$f" "$f.disabled-for-recovery.$(date +%s)"
done
sync
echo "Next boot of this stick: graphical terminal (cage + foot). Check the links, then: umount $R"
