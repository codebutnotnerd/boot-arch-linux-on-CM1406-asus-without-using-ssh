#!/usr/bin/env bash
# Build the CM14 mainline kernel and Depthcharge FIT for MT8186 or MT8189.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOC="${SOC:-mt8186}"
case "$SOC" in
  mt8186)
    DEFCONFIG="mt8186_quigon_defconfig"
    DTS="mt8186-corsola-quigon"
    DTB="$DTS.dtb"
    ;;
  mt8189)
    DEFCONFIG="mt8189_quigon_defconfig"
    DTS="mt8189-quigon"
    DTB="$DTS.dtb"
    ;;
  *)
    echo "[-] Unsupported SOC '$SOC' (expected mt8186 or mt8189)." >&2
    exit 2
    ;;
esac

KERNEL_SRC="${1:-${KERNEL_DIR:-$HOME/linux-next}}"
OUT_DIR="${2:-${BUILD_DIR:-$KERNEL_SRC/build-cm14-$SOC}}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH=arm64
DT_DIR="$KERNEL_SRC/arch/arm64/boot/dts/mediatek"
DEFCONFIG_DIR="$KERNEL_SRC/arch/arm64/configs"
MODULES_DIR="$REPO_ROOT/artifacts/modules-$SOC"

echo "=== ASUS Chromebook CM14 kernel builder ($SOC) ==="
echo "Kernel source: $KERNEL_SRC"
echo "Build output:  $OUT_DIR"
echo "Cross-compile: $CROSS_COMPILE"

if [[ ! -d "$KERNEL_SRC" ]]; then
  echo "[*] Cloning linux-next..."
  git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git "$KERNEL_SRC"
fi
if [[ ! -f "$KERNEL_SRC/Makefile" ]]; then
  echo "[-] '$KERNEL_SRC' is not a Linux kernel source tree." >&2
  exit 1
fi
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "[-] Cross compiler not found: ${CROSS_COMPILE}gcc" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$DEFCONFIG_DIR"

echo "[*] Installing $SOC DTS and defconfig into the kernel tree..."
cp "$REPO_ROOT/port/quigon/mainline/$DTS.dts" "$DT_DIR/"
cp "$REPO_ROOT/port/quigon/mainline/$DEFCONFIG" "$DEFCONFIG_DIR/"
if [[ "$SOC" == mt8189 ]]; then
  cp "$REPO_ROOT/port/quigon/mainline/mt8189.dtsi" "$DT_DIR/"
  cp "$REPO_ROOT/port/quigon/mainline/mt8189-pinfunc.h" "$DT_DIR/"
  cp "$REPO_ROOT/port/quigon/mainline"/mt8189-quigon-*.dtsi "$DT_DIR/"
  cp -R "$REPO_ROOT/port/quigon/mainline/include/dt-bindings/." "$KERNEL_SRC/include/dt-bindings/"
fi

MAKEFILE="$DT_DIR/Makefile"
if ! grep -Fq "$DTB" "$MAKEFILE"; then
  printf 'dtb-$(CONFIG_ARCH_MEDIATEK) += %s\n' "$DTB" >> "$MAKEFILE"
fi

if [[ "$SOC" == mt8189 ]]; then
  # Apply only the reviewed MT8189 support series. An unapplied patch that no
  # longer matches the selected source must stop the build instead of being skipped.
  PATCHES=(
    mainline-mt8189-display.patch
    mainline-mt8189-gpu.patch
    mainline-mt8189-audio.patch
    mainline-mt8189-usbc-dp.patch
    mainline-mt8189-thermal.patch
    mainline-mt8189-suspend.patch
    mainline-mt8189-vcodec.patch
  )
  if [[ ! -d "$KERNEL_SRC/.git" ]]; then
    echo "[-] MT8189 patch application requires a Git kernel tree." >&2
    exit 1
  fi
  for patch_name in "${PATCHES[@]}"; do
    patch_file="$REPO_ROOT/port/quigon/patches/$patch_name"
    if [[ ! -f "$patch_file" ]]; then
      echo "[-] Required patch is missing: $patch_file" >&2
      exit 1
    fi
    if git -C "$KERNEL_SRC" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
      echo "[=] Already applied: $patch_name"
    elif git -C "$KERNEL_SRC" apply --check "$patch_file"; then
      echo "[+] Applying: $patch_name"
      git -C "$KERNEL_SRC" apply "$patch_file"
    else
      echo "[-] Patch does not apply cleanly: $patch_name" >&2
      exit 1
    fi
  done
fi

echo "[*] Configuring $DEFCONFIG..."
make -C "$KERNEL_SRC" O="$OUT_DIR" ARCH="$ARCH" \
  CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"

echo "[*] Building Image, modules, and $DTB..."
make -C "$KERNEL_SRC" O="$OUT_DIR" ARCH="$ARCH" \
  CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" \
  Image modules "mediatek/$DTB"

echo "[*] Installing modules into $MODULES_DIR..."
mkdir -p "$MODULES_DIR"
make -C "$KERNEL_SRC" O="$OUT_DIR" ARCH="$ARCH" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$MODULES_DIR" modules_install

DTB_PATH="$OUT_DIR/arch/arm64/boot/dts/mediatek/$DTB"
IMAGE_PATH="$OUT_DIR/arch/arm64/boot/Image"
if [[ ! -s "$DTB_PATH" || ! -s "$IMAGE_PATH" ]]; then
  echo "[-] Kernel Image or selected SoC DTB was not generated." >&2
  exit 1
fi

echo "[*] Packaging the matching $SOC DTB and kernel Image..."
SOC="$SOC" bash "$REPO_ROOT/scripts/build-kernel-fit.sh" \
  "$IMAGE_PATH" "$DTB_PATH" "$REPO_ROOT/artifacts/kernel.fit"

echo "[+] Build complete: $REPO_ROOT/artifacts/kernel.fit"
echo "    Modules: $MODULES_DIR/lib/modules"
echo "    Next: sudo bash install/install-usb.sh --kernel artifacts/kernel.fit /dev/sdX"
