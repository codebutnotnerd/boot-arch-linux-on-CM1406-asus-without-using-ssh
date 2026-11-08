#!/bin/bash
# ==============================================================================
# build-kernel-fit.sh - Generate Depthcharge-compatible FIT image (kernel.fit)
# Target: ASUS Chromebook CM14 (CM1406CM4A - Dotation Île-de-France)
# SoC: MediaTek Kompanio 520/540 (MT8186) | Board: Corsola Quigon
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$REPO_ROOT/artifacts"
mkdir -p "$ARTIFACTS_DIR"

IMAGE_SRC="${1:-${KERNEL_IMAGE:-}}"
DTB_SRC="${2:-${DTB_FILE:-}}"
OUT_FIT="${3:-$ARTIFACTS_DIR/kernel.fit}"

echo "=== ASUS CM14 Depthcharge FIT Image Generator ==="

# 1. Locate Kernel Image
if [[ -z "$IMAGE_SRC" ]]; then
  for cand in "$REPO_ROOT/arch/arm64/boot/Image" \
              "$REPO_ROOT/Image" \
              "./arch/arm64/boot/Image" \
              "./Image" \
              "/tmp/Image"; do
    if [[ -f "$cand" ]]; then
      IMAGE_SRC="$cand"
      break
    fi
  done
fi

if [[ -z "$IMAGE_SRC" || ! -f "$IMAGE_SRC" ]]; then
  echo "[-] Error: Linux kernel Image not found!" >&2
  echo "    Please specify the path to Image:" >&2
  echo "    Usage: $0 <path_to_Image> [path_to_dtb] [out_kernel.fit]" >&2
  exit 1
fi

# 2. Locate or Compile Device Tree (.dtb)
TARGET_SOC="${TARGET_SOC:-${SOC:-mt8186}}"
case "$TARGET_SOC" in
  mt8186|mt8189) ;;
  *)
    echo "[-] Unsupported SOC '$TARGET_SOC' (expected mt8186 or mt8189)." >&2
    exit 2
    ;;
esac

if [[ -z "$DTB_SRC" ]]; then
  if [[ "$TARGET_SOC" == "mt8189" ]]; then
    CANDIDATES=(
      "$REPO_ROOT/arch/arm64/boot/dts/mediatek/mt8189-quigon.dtb"
      "$REPO_ROOT/mt8189-quigon.dtb"
      "$ARTIFACTS_DIR/mt8189-quigon.dtb"
      "./mt8189-quigon.dtb"
    )
  else
    CANDIDATES=(
      "$REPO_ROOT/arch/arm64/boot/dts/mediatek/mt8186-corsola-quigon.dtb"
      "$REPO_ROOT/mt8186-corsola-quigon.dtb"
      "$ARTIFACTS_DIR/mt8186-corsola-quigon.dtb"
      "./mt8186-corsola-quigon.dtb"
    )
  fi

  for cand in "${CANDIDATES[@]}"; do
    if [[ -f "$cand" ]]; then
      DTB_SRC="$cand"
      break
    fi
  done
fi

if [[ -z "$DTB_SRC" || ! -f "$DTB_SRC" ]]; then
  echo "[-] Error: Device Tree for $TARGET_SOC not found." >&2
  echo "    Compile the DTBs in your kernel tree with: make dtbs" >&2
  echo "    Do not substitute a DTB for the other SoC." >&2
  exit 1
fi
if [[ "$TARGET_SOC" == mt8189 ]]; then
  EXPECTED_DTB="mt8189-quigon.dtb"
else
  EXPECTED_DTB="mt8186-corsola-quigon.dtb"
fi
if [[ "${ALLOW_ANY_DTB:-0}" != 1 && "$(basename "$DTB_SRC")" != "$EXPECTED_DTB" ]]; then
  echo "[-] DTB mismatch: SOC=$TARGET_SOC requires $EXPECTED_DTB, got $(basename "$DTB_SRC")." >&2
  exit 2
fi

# EXTRA_COMPAT_LIST: ';'-separated compatible strings of YOUR board (from scripts/identify-device.sh),
# put first so Depthcharge matches them. Use with ALLOW_ANY_DTB=1 and your own DTB:
#   ALLOW_ANY_DTB=1 EXTRA_COMPAT_LIST="google,tarkin-rev1;google,tarkin" ./scripts/build-kernel-fit.sh Image my.dtb
EXTRA_QUOTED=""
if [[ -n "${EXTRA_COMPAT_LIST:-}" ]]; then
  IFS=';' read -r -a _ecl <<< "$EXTRA_COMPAT_LIST"
  for c in "${_ecl[@]}"; do EXTRA_QUOTED+="\"$c\", "; done
fi
echo "[+] Using Kernel Image: $IMAGE_SRC"
echo "[+] Using Device Tree:  $DTB_SRC"

# 3. Compress Image with lz4 (Depthcharge required format on ARM64)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
if [[ "$IMAGE_SRC" =~ \.lz4$ ]]; then
  cp "$IMAGE_SRC" "$TMP_DIR/Image.lz4"
else
  echo "[*] Compressing Image with lz4 (-9)..."
  if command -v lz4 >/dev/null 2>&1; then
    lz4 -l -q -9 -f "$IMAGE_SRC" "$TMP_DIR/Image.lz4"
  else
    echo "[-] Error: 'lz4' compression utility not found. Please install lz4 (apt install lz4 / pacman -S lz4)." >&2
    exit 1
  fi
fi

cp "$DTB_SRC" "$TMP_DIR/quigon.dtb"

# 4. Generate FIT Image ITS descriptor
cat > "$TMP_DIR/kernel.its" <<ITS
/dts-v1/;

/ {
	description = "ASUS Chromebook CM14 (Corsola Quigon / Obiwan) FIT Image for Depthcharge";
	#address-cells = <1>;

	images {
		kernel {
			description = "Linux Kernel ARM64";
			data = /incbin/("Image.lz4");
			type = "kernel_noload";
			arch = "arm64";
			os = "linux";
			compression = "lz4";
			load = <0>;
			entry = <0>;
			hash-1 {
				algo = "sha256";
			};
		};

		fdt-1 {
			description = "ASUS CM14 Device Tree";
			data = /incbin/("quigon.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "conf-1";
		conf-1 {
			description = "ASUS Chromebook CM14 & Corsola (Quigon & Obiwan)";
			kernel = "kernel";
			fdt = "fdt-1";
			compatible = ${EXTRA_QUOTED}"google,quigon-sku0", "google,quigon-sku1", "google,quigon-sku512", "google,quigon", "google,obiwan-rev3-sku196620", "google,obiwan-rev3", "google,obiwan-sku196620", "google,obiwan", "google,corsola", "mediatek,mt8189", "mediatek,mt8186";
		};

		conf-obiwan {
			description = "Corsola Obiwan (rev3-sku196620 / ASUS CM14 / Acer)";
			kernel = "kernel";
			fdt = "fdt-1";
			compatible = "google,obiwan-rev3-sku196620", "google,obiwan-rev3", "google,obiwan-sku196620", "google,obiwan", "google,corsola", "mediatek,mt8189", "mediatek,mt8186";
		};

		conf-corsola {
			description = "Generic Corsola MT8186 / MT8189";
			kernel = "kernel";
			fdt = "fdt-1";
			compatible = "google,corsola", "mediatek,mt8189", "mediatek,mt8186";
		};
	};
};
ITS

# 5. Compile FIT Image
echo "[*] Building FIT Image: $OUT_FIT..."
mkdir -p "$(dirname "$OUT_FIT")"
OUT_FIT="$(cd "$(dirname "$OUT_FIT")" && pwd)/$(basename "$OUT_FIT")"
if command -v mkimage >/dev/null 2>&1; then
  (cd "$TMP_DIR" && mkimage -f kernel.its "$OUT_FIT")
else
  echo "[-] Error: 'mkimage' (u-boot-tools) is required to create a FIT image." >&2
  exit 1
fi

if [[ ! -s "$OUT_FIT" ]]; then
  echo "[-] Error: mkimage did not create $OUT_FIT." >&2
  exit 1
fi
SIZE=$(stat -c %s "$OUT_FIT")
if (( SIZE >= 32 * 1024 * 1024 )); then
  echo "[-] Error: FIT image is $SIZE bytes; it must be smaller than 32 MiB." >&2
  rm -f "$OUT_FIT"
  exit 1
fi
echo "=========================================================="
echo "[+] SUCCESS: Depthcharge FIT image generated!"
echo "    File: $OUT_FIT ($SIZE bytes)"
echo ""
echo "Next step: Sign the kernel for Depthcharge via install/sign-kernel.sh:"
echo "    ./install/sign-kernel.sh --vmlinuz \"$OUT_FIT\" --out /tmp/kern-usb.bin --target usb"
echo "=========================================================="
