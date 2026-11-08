#!/bin/bash
# ==============================================================================
# sign-kernel.sh - Automated Depthcharge Kernel Signer for ASUS Chromebook CM14
# Target: ASUS Chromebook CM14 (CM1406CM4A - Dotation Île-de-France)
# Board: Corsola (variant quigon) / SoC: MediaTek Kompanio 520/540 (MT8186)
# ==============================================================================
# Signs an ARM64 Linux kernel image (FIT or raw blob) with ChromeOS devkeys
# for Depthcharge bootloader direct boot via [Ctrl] + [U] (USB) or KERN-B (internal).
#
# Usage:
#   sign-kernel.sh [--vmlinuz <fit_file>] [--out <output.bin>] [--target usb|internal] [--config <cmdline.txt>]
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVKEYS_DIR="/usr/share/vboot/devkeys"
LOCAL_DEVKEYS="$REPO_ROOT/port/quigon/root/usr/local/share/quigon/devkeys"
FALLBACK_DEVKEYS="$REPO_ROOT/devkeys"

KEYBLOCK=""
PRIVKEY=""
TARGET="usb"
VMLINUZ=""
OUT=""
CONFIG_FILE=""
ARCH="${KERNEL_ARCH:-aarch64}"
FLAGS="0x1"
VERSION=1
CUSTOM_KEYS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --vmlinuz|--fit|-k|--kernel)
      VMLINUZ="$2"
      shift 2
      ;;
    --out|-o)
      OUT="$2"
      shift 2
      ;;
    --config|-c)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --flags)
      FLAGS="$2"
      shift 2
      ;;
    --keys-dir)
      CUSTOM_KEYS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--vmlinuz <path>] [--out <output.bin>] [--target usb|internal] [--config <cmdline.txt>] [--arch aarch64] [--flags 0x1]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$TARGET" != usb && "$TARGET" != internal ]]; then
  echo "[-] Error: --target must be usb or internal." >&2
  exit 2
fi

# 1. Fallback to default kernel FIT image if not provided
if [[ -z "$VMLINUZ" ]]; then
  for cand in "$REPO_ROOT/artifacts/kernel.fit" \
              "$REPO_ROOT/kernel.fit" \
              "./artifacts/kernel.fit" \
              "./kernel.fit"; do
    if [[ -f "$cand" ]]; then
      VMLINUZ="$cand"
      break
    fi
  done
fi

if [[ -z "$VMLINUZ" || ! -f "$VMLINUZ" ]]; then
  echo "[-] Error: No kernel FIT binary found to sign!" >&2
  echo "" >&2
  echo "    The signed image requires a Depthcharge-compatible FIT binary." >&2
  echo "    Please generate it first with:" >&2
  echo "        ./scripts/build-kernel-fit.sh <path_to_Image> [path_to_dtb]" >&2
  echo "    Or build the full kernel with:" >&2
  echo "        ./scripts/build-mt8186-kernel.sh" >&2
  echo "    Or specify an existing FIT binary:" >&2
  echo "        $0 --vmlinuz /path/to/kernel.fit --out /tmp/kern-usb.bin" >&2
  exit 1
fi

# 2. Fallback to default output file if not provided
if [[ -z "$OUT" ]]; then
  OUT="$REPO_ROOT/artifacts/kern-${TARGET}-signed.bin"
fi
mkdir -p "$(dirname "$OUT")"

# 3. Locate or automatically retrieve ChromeOS devkeys
SEARCH_DIRS=()
[[ -n "$CUSTOM_KEYS_DIR" ]] && SEARCH_DIRS+=("$CUSTOM_KEYS_DIR")
SEARCH_DIRS+=("$DEVKEYS_DIR" "$LOCAL_DEVKEYS" "$FALLBACK_DEVKEYS" "/root/devkeys" "./devkeys")

for dir in "${SEARCH_DIRS[@]}"; do
  if [[ -f "$dir/kernel.keyblock" && -f "$dir/kernel_data_key.vbprivk" ]]; then
    KEYBLOCK="$dir/kernel.keyblock"
    PRIVKEY="$dir/kernel_data_key.vbprivk"
    break
  fi
done

# If keys not found locally, fetch official ChromeOS devkeys from ChromiumOS vboot_reference
if [[ -z "$KEYBLOCK" ]]; then
  echo "[*] ChromeOS official devkeys not found locally. Attempting automatic download..."
  mkdir -p "$FALLBACK_DEVKEYS"
  VBOOT_URL="https://chromium.googlesource.com/chromiumos/platform/vboot_reference/+/refs/heads/main/tests/devkeys"
  
  if curl -sfL "$VBOOT_URL/kernel.keyblock?format=TEXT" | base64 -d > "$FALLBACK_DEVKEYS/kernel.keyblock" 2>/dev/null && \
     curl -sfL "$VBOOT_URL/kernel_data_key.vbprivk?format=TEXT" | base64 -d > "$FALLBACK_DEVKEYS/kernel_data_key.vbprivk" 2>/dev/null; then
    KEYBLOCK="$FALLBACK_DEVKEYS/kernel.keyblock"
    PRIVKEY="$FALLBACK_DEVKEYS/kernel_data_key.vbprivk"
    echo "[+] Devkeys successfully downloaded to $FALLBACK_DEVKEYS"
  else
    rm -f "$FALLBACK_DEVKEYS/kernel.keyblock" "$FALLBACK_DEVKEYS/kernel_data_key.vbprivk" 2>/dev/null || true
  fi
fi

if [[ -z "$KEYBLOCK" || ! -f "$KEYBLOCK" ]]; then
  echo "[-] Error: ChromeOS official devkeys not found!" >&2
  echo "    Please install vboot-utils or place kernel.keyblock and kernel_data_key.vbprivk in /usr/share/vboot/devkeys" >&2
  exit 1
fi

# 4. Detect vbutil_kernel / futility binary
VBUTIL=(vbutil_kernel)
if ! command -v vbutil_kernel >/dev/null 2>&1; then
  if command -v futility >/dev/null 2>&1; then
    VBUTIL=(futility vbutil_kernel)
  else
    echo "[-] Error: Neither vbutil_kernel nor futility found in PATH!" >&2
    echo "    On Arch: pacman -S vboot-utils" >&2
    echo "    On Debian/Ubuntu: apt install vboot-kernel-utils" >&2
    exit 1
  fi
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 5. Generate default cmdline if not provided
if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$TMP_DIR/cmdline.txt"
  if [[ "$TARGET" == "usb" ]]; then
    # Depthcharge replaces %U with the kernel partition GUID; PARTNROFF=1 points to partition 2 (ROOT ext4)
    echo "console=tty1 loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=1 rootdelay=3 rootwait rw noinitrd net.ifnames=0" > "$CONFIG_FILE"
  else
    # Internal dual-boot: KERN-B (partition 4) + 3 = partition 7 (ROOT-C ext4)
    echo "console=tty1 loglevel=7 init=/sbin/init root=PARTUUID=%U/PARTNROFF=3 rootwait rw noinitrd net.ifnames=0 quigon.default=mainline" > "$CONFIG_FILE"
  fi
fi

# Depthcharge ignores bootloader payload on ARM64, but requires a non-empty file parameter
DUMMY_BOOTLOADER="$TMP_DIR/dummy_bootloader.bin"
printf 'fake' > "$DUMMY_BOOTLOADER"

echo "=========================================================="
echo "Signing kernel for Depthcharge ($TARGET target)"
echo "SoC: MediaTek Kompanio 520/540 | Board: Corsola (quigon)"
echo "Kernel input: $VMLINUZ"
echo "Signed image: $OUT"
echo "Cmdline: $(cat "$CONFIG_FILE")"
echo "=========================================================="

"${VBUTIL[@]}" --pack "$OUT" \
  --keyblock "$KEYBLOCK" \
  --signprivate "$PRIVKEY" \
  --version "$VERSION" \
  --flags "$FLAGS" \
  --config "$CONFIG_FILE" \
  --bootloader "$DUMMY_BOOTLOADER" \
  --vmlinuz "$VMLINUZ" \
  --arch "$ARCH"

echo "Verifying signed image..."
"${VBUTIL[@]}" --verify "$OUT"

echo "[+] Success! Kernel image signed and ready: $OUT ($(stat -c %s "$OUT") bytes)"
