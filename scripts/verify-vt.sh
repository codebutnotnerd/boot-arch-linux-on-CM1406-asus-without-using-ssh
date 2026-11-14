#!/bin/bash
# Verify that the running kernel really provides virtual terminals.
#
# Thin wrapper: the real checker lives on the stick as /usr/local/bin/tarkin-vtcheck
# and is installed automatically, so this works both on the stick and from a PC
# (or from ChromeOS, which runs the same signed kernel, so the answer is the
# same one the stick will get).
#
#   sudo bash scripts/verify-vt.sh
#   sudo bash scripts/verify-vt.sh --activate tty2   # switch the screen to a VT for 3 s
set -u
if command -v tarkin-vtcheck >/dev/null 2>&1; then
  exec tarkin-vtcheck "$@"
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
f="$here/../rootfs/usr/local/bin/tarkin-vtcheck"
[[ -f "$f" ]] || { echo "[-] $f not found: run this from the repository." >&2; exit 1; }
exec bash "$f" "$@"
