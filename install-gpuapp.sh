#!/bin/bash
# Third-party code:
#  - vulkan-wsi-layer, (c) Arm Limited and contributors, MIT licence, cloned at install time from
#    https://gitlab.freedesktop.org/mesa/vulkan-wsi-layer at the commit pinned in WSI_COMMIT.
#  - The patch embedded at the end of this file is port/quigon/patches/vulkan-wsi-layer-quigon.patch from
#    https://github.com/zoan37/lenovo-slim3-chromebook-omarchy (commit 27ba99f), Copyright (c) 2026 zoan37,
#    MIT licence (see LICENSE). It is unmodified and checked by SHA-256 before use.
set -euo pipefail

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }
warn() { echo "[!] $*" >&2; }
ok()   { echo "[+] $*"; }

usage() {
cat <<'USAGE_EOF'
Usage: bash install-gpuapp.sh [options]            (boot-arch-linux-on-CM1406 v1.50)

Optional. Installs `gpuapp`, a command that runs one program on the Mali-G57 GPU
(Mesa Zink on the Vulkan driver of the ChromeOS libmali) instead of the CPU:

    gpuapp firefox            gpuapp --check            gpuapp --measure

Without `gpuapp` in front, programs render on the CPU exactly as before. Hyprland,
hyprland-mali, the EGL shim, console.env and the cage + foot terminal are not touched.
Needs: the GPU stack of install-hyprland.sh and a running Hyprland (Mali GPU) desktop.
Run it as your user, without sudo, in a terminal of the Hyprland desktop.

Options:
  --check      Verify the installation (read-only), then run `gpuapp --check`.
  --remove     Remove everything this script installed (packages are kept).
  --rebuild    Compile the Vulkan Wayland layer again even when it is already installed.
  --dry-run    Show what would be done; change nothing.
  -h, --help   Show this help.

Installed files:
  /usr/local/lib/tarkin-gpu/vulkan/    Mali Vulkan ICD file and the compiled Wayland layer
  /usr/local/bin/gpuapp                the launcher
  /etc/udev/rules.d/70-tarkin-dma-heap.rules   /dev/dma_heap/system: group video, mode 0660
  /usr/local/share/applications/firefox-gpu.desktop   "Firefox (GPU)", only when Firefox is installed

Limits: Wayland programs only (X11 programs fail), Chromium/Electron and Qt Quick fall
back to the CPU or crash under Zink, video decoding stays on the CPU.

Environment:
  FORCE_BOARD=1    Skip the "this is a google,tarkin board" check.
  TARKIN_PREFIX=D  Install everything under D instead of / (staging/testing only;
                   skips pacman, udevadm and the board check).
USAGE_EOF
}

DRY_RUN=0
REMOVE=0
CHECK=0
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --remove) REMOVE=1 ;;
    --check|--verify) CHECK=1 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

(( REMOVE + CHECK <= 1 )) || die "--remove and --check are mutually exclusive."
(( REBUILD == 0 || (REMOVE == 0 && CHECK == 0) )) || die "--rebuild cannot be combined with --remove or --check."

if [[ $EUID -eq 0 && -z "${TARKIN_PREFIX:-}" ]]; then
  echo "[-] Do not run this with sudo. Run it as your user: bash install-gpuapp.sh (it asks for the sudo password itself)." >&2
  exit 1
fi

PREFIX="${TARKIN_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

GPU_ROOT="$PREFIX/usr/local/lib/tarkin-gpu"
MALI_LIB="$GPU_ROOT/mali/lib"
MALI_SO="$MALI_LIB/libmali.so.0"
BIN_DIR="$GPU_ROOT/bin"
VK_ROOT="$GPU_ROOT/vulkan"
ICD="$VK_ROOT/mali_icd.json"
LAYER_DIR="$VK_ROOT/layer"
LAYER_SO="libVkLayer_window_system_integration.so"
LAYER_JSON="VkLayer_window_system_integration.json"
STAMP="$LAYER_DIR/SOURCE"
GPUAPP="$PREFIX/usr/local/bin/gpuapp"
UDEV_RULE="$PREFIX/etc/udev/rules.d/70-tarkin-dma-heap.rules"
APPS_DIR="$PREFIX/usr/local/share/applications"
FIREFOX_DESKTOP="$APPS_DIR/firefox-gpu.desktop"
DMA_HEAP="${TARKIN_DMA_HEAP:-/dev/dma_heap/system}"
PROC_ROOT="${TARKIN_PROC_ROOT:-/proc}"

WSI_REPO="https://gitlab.freedesktop.org/mesa/vulkan-wsi-layer.git"
WSI_COMMIT="f5148d4f8c541f8aeddc88170b9e2dbbea2e8b43"
WSI_PATCH_SHA256="f4ae1ba7a575e1bfac06120f52f404d932d9c955b309539912483e295b3f82db"
PACKAGES=(vulkan-icd-loader vulkan-tools mesa-utils wayland-utils git cmake gcc make pkgconf vulkan-headers wayland-protocols libdrm)

WORK_TMP=""
cleanup() {
  if [[ -n "$WORK_TMP" ]]; then
    rm -rf "$WORK_TMP"
  fi
  return 0
}
trap cleanup EXIT

sys() {
  if (( DRY_RUN )); then
    echo "   [dry-run] $*"
    return 0
  fi
  "${SUDO[@]}" "$@"
}

check_environment() {
  [[ -n "$PREFIX" ]] && return 0
  [[ "$(uname -m)" == "aarch64" ]] || die "This is not an aarch64 machine."
  command -v pacman >/dev/null 2>&1 || die "pacman not found: this must run inside the Arch system."
  local compat
  compat="$(tr '\0' ' ' 2>/dev/null < /proc/device-tree/compatible || true)"
  if [[ -n "$compat" && "$compat" != *google,tarkin* && "${FORCE_BOARD:-0}" != 1 ]]; then
    die "This is not a google,tarkin board (compatible: $compat). Set FORCE_BOARD=1 to override."
  fi
}

check_libmali() {
  [[ -f "$MALI_SO" && -s "$MALI_SO" ]] ||
    die "libmali is missing ($MALI_SO). Install the GPU stack first: bash ~/install-hyprland.sh, then check it with tarkin-gpu-check. Nothing was installed."
  command -v readelf >/dev/null 2>&1 || die "readelf is missing (binutils). Nothing was installed."
  if ! LC_ALL=C readelf --dyn-syms -W -- "$MALI_SO" 2>/dev/null | grep -c 'vk_icd' >/dev/null; then
    die "This libmali has no Vulkan driver (no vk_icd symbols in $MALI_SO). Nothing was installed."
  fi
  ok "libmali with a Vulkan driver: $MALI_SO"
}

desktop_on_gpu() {
  local pid
  for pid in $(pgrep -x Hyprland -u "$(id -u)" 2>/dev/null); do
    if grep -q 'libmali' "$PROC_ROOT/$pid/maps" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

check_desktop_gpu() {
  local out
  if [[ -x "$BIN_DIR/mali-probe" ]]; then
    if ! out="$(env LD_LIBRARY_PATH="$MALI_LIB" timeout 45 "$BIN_DIR/mali-probe" 5 2>&1)"; then
      tail -n 5 <<<"$out" >&2
      die "The Mali GPU probe failed or timed out (same probe as tarkin-gpu-check). Nothing was installed."
    fi
    ok "Mali GPU probe passed"
  else
    warn "$BIN_DIR/mali-probe is missing: probe skipped (it comes with install-hyprland.sh)."
  fi
  desktop_on_gpu ||
    die "The desktop is not on the GPU: no running Hyprland of this user has libmali loaded. Start Hyprland (Mali GPU) first (sudo tarkin-display hyprland, sudo reboot, then tarkin-gpu-check) and run this script from a terminal of that desktop. Nothing was installed."
  ok "Hyprland is running on the Mali GPU"
}

install_packages() {
  [[ -n "$PREFIX" ]] && return 0
  local want=() p
  for p in "${PACKAGES[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || want+=("$p")
  done
  if (( ${#want[@]} == 0 )); then
    info "All packages are already installed."
    return 0
  fi
  if (( DRY_RUN )); then
    info "Would install: ${want[*]}"
    return 0
  fi
  getent hosts mirror.archlinuxarm.org >/dev/null 2>&1 || die "No network (cannot resolve mirror.archlinuxarm.org). Connect first: sudo tarkin-wifi \"NetworkName\"."
  info "Installing: ${want[*]}"
  sys pacman -S --needed --noconfirm --noprogressbar --ignore linux-aarch64,linux-aarch64-headers "${want[@]}" ||
    die "pacman could not install the packages. If it reports packages not found, update first with: sudo tarkin-update, then run this script again. Nothing else was installed."
}

check_build_tools() {
  local c
  for c in git cmake make gcc pkg-config sha256sum timeout; do
    command -v "$c" >/dev/null 2>&1 || die "$c is missing; install it with: sudo pacman -S --needed ${PACKAGES[*]}"
  done
}

write_icd() {
  printf '{ "file_format_version": "1.0.0", "ICD": { "library_path": "%s", "api_version": "1.3.211" } }\n' "$MALI_SO" > "$1"
}

check_vulkan_driver() {
  local out
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    [[ -n "$PREFIX" ]] && return 0
    die "vulkaninfo is missing (vulkan-tools). Nothing was installed."
  fi
  write_icd "$WORK_TMP/mali_icd.json"
  out="$(VK_DRIVER_FILES="$WORK_TMP/mali_icd.json" timeout 30 vulkaninfo --summary 2>&1)" || true
  if ! grep -q 'Mali' <<<"$out"; then
    tail -n 5 <<<"$out" >&2
    die "The Vulkan loader does not find the Mali driver in $MALI_SO (vulkaninfo --summary shows no Mali device). Nothing was installed."
  fi
  ok "Vulkan driver answers: $(grep -m1 -E 'deviceName' <<<"$out" | sed 's/^[[:space:]]*//' || true)"
}

layer_is_current() {
  [[ -f "$LAYER_DIR/$LAYER_SO" && -f "$LAYER_DIR/$LAYER_JSON" && -f "$STAMP" ]] &&
    grep -qx "commit=$WSI_COMMIT" "$STAMP" && grep -qx "patch_sha256=$WSI_PATCH_SHA256" "$STAMP"
}

build_layer() {
  local src="$WORK_TMP/vulkan-wsi-layer" log="$WORK_TMP/build.log" head jobs
  write_wsi_patch "$WORK_TMP/vulkan-wsi-layer-quigon.patch"
  [[ "$(sha256sum "$WORK_TMP/vulkan-wsi-layer-quigon.patch" | cut -d ' ' -f1)" == "$WSI_PATCH_SHA256" ]] ||
    die "The embedded vulkan-wsi-layer patch does not match its SHA-256; this copy of install-gpuapp.sh is damaged. Nothing was installed."
  info "Downloading vulkan-wsi-layer (commit ${WSI_COMMIT:0:7}) and compiling it as $(id -un); this takes a few minutes..."
  jobs="$(nproc 2>/dev/null || echo 2)"
  if ! {
    git clone "$WSI_REPO" "$src" &&
    git -C "$src" checkout -q "$WSI_COMMIT" &&
    head="$(git -C "$src" rev-parse HEAD)" && [[ "$head" == "$WSI_COMMIT" ]] &&
    git -C "$src" apply "$WORK_TMP/vulkan-wsi-layer-quigon.patch" &&
    sed -i 's/ -Werror//g' "$src/CMakeLists.txt" &&
    ( cd "$src" && cmake . -Bbuild -DCMAKE_BUILD_TYPE=Release -DBUILD_WSI_HEADLESS=1 -DBUILD_WSI_WAYLAND=1 \
        -DSELECT_EXTERNAL_ALLOCATOR=dma_buf_heaps -DWSIALLOC_MEMORY_HEAP_NAME=system -DKERNEL_HEADER_DIR=/usr/include ) &&
    make -C "$src/build" -j"$jobs"
  } >"$log" 2>&1; then
    cp "$log" "$HOME/install-gpuapp-build.log" 2>/dev/null || true
    tail -n 15 "$log" >&2
    die "Building vulkan-wsi-layer failed (network, or a compiler error above). Full log: ~/install-gpuapp-build.log. Nothing was installed."
  fi
  [[ -s "$src/build/$LAYER_SO" && -s "$src/build/$LAYER_JSON" ]] ||
    die "The build did not produce $LAYER_SO and $LAYER_JSON. Nothing was installed."
  ok "vulkan-wsi-layer compiled"
}

write_stamp() {
  cat > "$1" <<STAMP_EOF
source=$WSI_REPO
commit=$WSI_COMMIT
patch=vulkan-wsi-layer-quigon.patch (zoan37/lenovo-slim3-chromebook-omarchy 27ba99f, MIT)
patch_sha256=$WSI_PATCH_SHA256
licence=MIT (Arm Limited and contributors; patch Copyright (c) 2026 zoan37)
STAMP_EOF
}

write_gpuapp() {
  cat > "$1" <<'GPUAPP_EOF'
#!/bin/bash
set -u
VK="@VK@"
ICD="$VK/mali_icd.json"
LAYER="$VK/layer"
HEAP="${TARKIN_DMA_HEAP:-/dev/dma_heap/system}"

usage() {
cat <<'USAGE_EOF'
Usage: gpuapp <program> [arguments]    run a Wayland program on the Mali-G57 GPU (Mesa Zink)
       gpuapp --check                  one line: apps on the GPU: yes/no (reason)
       gpuapp --measure                compare CPU and GPU rendering (glmark2-es2-wayland, about 1 min)
       gpuapp --help

Example: gpuapp firefox   (close the normal Firefox first, or the new window joins it on the CPU)
Limits: X11 programs fail; Chromium/Electron and Qt Quick fall back to the CPU or crash;
video decoding stays on the CPU.
USAGE_EOF
}

GPU_ENV=(env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER -u GBM_ALWAYS_SOFTWARE
  VK_DRIVER_FILES="$ICD" VK_ADD_IMPLICIT_LAYER_PATH="$LAYER"
  MESA_LOADER_DRIVER_OVERRIDE=zink "SDL_VIDEODRIVER=wayland,x11")

missing_reason() {
  local lib
  [[ -r "$ICD" ]] || { echo "$ICD is missing; run bash ~/install-gpuapp.sh"; return 0; }
  lib="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ICD")"
  [[ -n "$lib" && -e "$lib" ]] || { echo "libmali is missing (${lib:-no library_path in $ICD}); run bash ~/install-hyprland.sh"; return 0; }
  [[ -r "$LAYER/libVkLayer_window_system_integration.so" && -r "$LAYER/VkLayer_window_system_integration.json" ]] ||
    { echo "the Vulkan Wayland layer is missing in $LAYER; run bash ~/install-gpuapp.sh"; return 0; }
  [[ -r "$HEAP" && -w "$HEAP" ]] ||
    { echo "$HEAP is not readable and writable by $(id -un) (expected group video, mode 0660); run bash ~/install-gpuapp.sh or reboot"; return 0; }
  return 1
}

find_wayland() {
  local s
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && return 0
  for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
    if [[ -S "$s" ]]; then export WAYLAND_DISPLAY="${s##*/}"; return 0; fi
  done
  return 1
}

renderer_of() {
  timeout 20 "$@" eglinfo -B -p wayland 2>&1 | grep -i -m1 'renderer' | sed 's/^[^:]*:[[:space:]]*//'
}

check() {
  local why r err
  if why="$(missing_reason)"; then echo "apps on the GPU: no ($why)"; return 1; fi
  find_wayland || { echo "apps on the GPU: no (no Wayland session found; run this in a terminal of the Hyprland desktop)"; return 1; }
  command -v eglinfo >/dev/null 2>&1 || { echo "apps on the GPU: no (eglinfo is missing; sudo pacman -S --needed mesa-utils)"; return 1; }
  r="$(renderer_of "${GPU_ENV[@]}")"
  case "$r" in
    *zink*Mali*) echo "apps on the GPU: yes ($r)"; return 0 ;;
    "") err="$(timeout 20 "${GPU_ENV[@]}" eglinfo -B -p wayland 2>&1 | grep -m1 -E 'ZINK|rror' || true)"
        echo "apps on the GPU: no (eglinfo shows no renderer${err:+: $err})"; return 1 ;;
    *)  err="$(timeout 20 "${GPU_ENV[@]}" eglinfo -B -p wayland 2>&1 | grep -m1 'ZINK' || true)"
        echo "apps on the GPU: no (renderer is $r${err:+; $err})"; return 1 ;;
  esac
}

score_of() {
  timeout 90 "$@" glmark2-es2-wayland -s 800x600 -b build:duration=5.0 -b texture:duration=5.0 -b shading:duration=5.0 2>&1 |
    sed -n 's/.*glmark2 Score:[[:space:]]*\([0-9]\+\).*/\1/p' | tail -n 1
}

measure() {
  local why before_r after_r before after
  if why="$(missing_reason)"; then echo "gpuapp: cannot measure: $why" >&2; return 1; fi
  find_wayland || { echo "gpuapp: cannot measure: no Wayland session found; run this in a terminal of the Hyprland desktop" >&2; return 1; }
  if command -v eglinfo >/dev/null 2>&1; then
    before_r="$(renderer_of env)"; after_r="$(renderer_of "${GPU_ENV[@]}")"
  else
    before_r="unknown (eglinfo is missing)"; after_r="$before_r"
  fi
  echo "without gpuapp: ${before_r:-no renderer}"
  echo "with gpuapp   : ${after_r:-no renderer}"
  if ! command -v glmark2-es2-wayland >/dev/null 2>&1; then
    echo "No speed measured: glmark2-es2-wayland is not installed (package glmark2: pacman if it has it, otherwise the AUR). Only the renderer names above were compared."
    return 2
  fi
  echo "Running glmark2-es2-wayland twice (3 scenes of 5 s, 800x600, at most 90 s each); do not touch the windows..."
  before="$(score_of env)"; after="$(score_of "${GPU_ENV[@]}")"
  echo "glmark2 score without gpuapp: ${before:-none (failed or timed out)}"
  echo "glmark2 score with gpuapp   : ${after:-none (failed or timed out)}"
  [[ -n "$before" && -n "$after" ]] || return 1
  if (( before > 0 )); then
    echo "ratio: x$(( after / before )).$(( (after * 10 / before) % 10 )) (higher is better)"
  fi
}

case "${1:-}" in
  ""|-h|--help) usage; [[ -n "${1:-}" ]] || exit 2; exit 0 ;;
  --check) check; exit $? ;;
  --measure|--mesure) measure; exit $? ;;
  --) shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; } ;;
  -*) echo "gpuapp: unknown option: $1 (use --help)" >&2; exit 2 ;;
esac

if why="$(missing_reason)"; then
  echo "gpuapp: warning: $why. \"$1\" will probably render on the CPU." >&2
fi
command -v -- "$1" >/dev/null 2>&1 || { echo "gpuapp: $1: command not found" >&2; exit 127; }
exec "${GPU_ENV[@]}" "$@"
GPUAPP_EOF
  sed -i "s|@VK@|$VK_ROOT|g" "$1"
}

write_firefox_desktop() {
  cat > "$1" <<'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Firefox (GPU)
GenericName=Web Browser
Comment=Firefox rendering on the Mali-G57 GPU (close the normal Firefox first)
Exec=@GPUAPP@ firefox %u
TryExec=@GPUAPP@
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
DESKTOP_EOF
  sed -i "s|@GPUAPP@|$GPUAPP|g" "$1"
}

firefox_present() {
  [[ -x "$PREFIX/usr/bin/firefox" ]] || { [[ -z "$PREFIX" ]] && command -v firefox >/dev/null 2>&1; }
}

apply_udev_rule() {
  [[ -n "$PREFIX" ]] && return 0
  sys udevadm control --reload || warn "udevadm control --reload failed."
  sys udevadm trigger --subsystem-match=dma_heap || warn "udevadm trigger failed."
  sys udevadm settle --timeout=10 || true
  (( DRY_RUN )) && return 0
  if [[ ! -e "$DMA_HEAP" ]]; then
    warn "$DMA_HEAP does not exist: this kernel has no \"system\" DMA-BUF heap, gpuapp cannot work."
  elif [[ "$(stat -c '%G %a' "$DMA_HEAP")" != "video 660" ]]; then
    warn "$DMA_HEAP is still $(stat -c '%U:%G %a' "$DMA_HEAP"); it becomes video 0660 at the next boot (sudo reboot)."
  else
    ok "$DMA_HEAP is group video, mode 0660"
  fi
  id -nG | tr ' ' '\n' | grep -qx video || warn "$(id -un) is not in the video group: gpuapp will not reach $DMA_HEAP."
}

install_files() {
  local d="$WORK_TMP/out" built="$1"
  if (( DRY_RUN )); then
    echo "   [dry-run] install $ICD, the layer into $LAYER_DIR, $GPUAPP and $UDEV_RULE"
    if firefox_present; then echo "   [dry-run] install $FIREFOX_DESKTOP"; fi
    return 0
  fi
  mkdir -p "$d"
  write_icd "$d/mali_icd.json"
  write_gpuapp "$d/gpuapp"
  write_stamp "$d/SOURCE"
  echo 'SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"' > "$d/70-tarkin-dma-heap.rules"
  sys install -d -m 755 "$VK_ROOT" "$LAYER_DIR"
  sys install -m 644 "$d/mali_icd.json" "$ICD"
  if [[ -n "$built" ]]; then
    sys install -m 755 "$built/$LAYER_SO" "$LAYER_DIR/$LAYER_SO"
    sys install -m 644 "$built/$LAYER_JSON" "$LAYER_DIR/$LAYER_JSON"
    sys install -m 644 "$WORK_TMP/vulkan-wsi-layer-quigon.patch" "$LAYER_DIR/vulkan-wsi-layer-quigon.patch"
    sys install -m 644 "$d/SOURCE" "$STAMP"
  fi
  sys install -D -m 755 "$d/gpuapp" "$GPUAPP"
  sys install -D -m 644 "$d/70-tarkin-dma-heap.rules" "$UDEV_RULE"
  ok "Installed $VK_ROOT, $GPUAPP and $UDEV_RULE"
  if firefox_present; then
    write_firefox_desktop "$d/firefox-gpu.desktop"
    sys install -D -m 644 "$d/firefox-gpu.desktop" "$FIREFOX_DESKTOP"
    ok "Menu entry \"Firefox (GPU)\" installed: $FIREFOX_DESKTOP (the normal Firefox entry is untouched)"
  else
    sys rm -f "$FIREFOX_DESKTOP"
    info "Firefox is not installed: no \"Firefox (GPU)\" menu entry. Run this script again after installing it."
  fi
}

remove_files() {
  info "Removing gpuapp..."
  [[ -n "$VK_ROOT" && "$VK_ROOT" == */usr/local/lib/tarkin-gpu/vulkan ]] || die "internal error: unexpected path $VK_ROOT"
  sys rm -f "$GPUAPP" "$FIREFOX_DESKTOP" "$UDEV_RULE"
  sys rm -rf "$VK_ROOT"
  if [[ -d "$APPS_DIR" && -z "$(ls -A "$APPS_DIR")" ]]; then
    sys rmdir "$APPS_DIR"
  fi
  if [[ -z "$PREFIX" ]]; then
    sys udevadm control --reload || true
    if [[ -e "$DMA_HEAP" ]]; then
      sys chown root:root "$DMA_HEAP" || true
      sys chmod 600 "$DMA_HEAP" || true
    fi
  fi
  ok "Removed $GPUAPP, $VK_ROOT, $UDEV_RULE and the \"Firefox (GPU)\" entry."
  echo "    Packages are kept (${PACKAGES[*]})."
  echo "    Hyprland, the Mali GPU stack and the console were never changed; programs render on the CPU as before."
}

verify_install() {
  local bad=0 f
  info "gpuapp installation"
  for f in "$MALI_SO" "$ICD" "$LAYER_DIR/$LAYER_SO" "$LAYER_DIR/$LAYER_JSON" "$STAMP" "$GPUAPP" "$UDEV_RULE"; do
    if [[ -e "$f" ]]; then echo "  [ok]   $f"; else echo "  [no]   $f is missing"; bad=1; fi
  done
  if [[ -f "$STAMP" ]] && ! layer_is_current; then
    echo "  [no]   the installed layer is not the version this script builds; run: bash ~/install-gpuapp.sh --rebuild"; bad=1
  fi
  if [[ -e "$FIREFOX_DESKTOP" ]]; then echo "  [ok]   $FIREFOX_DESKTOP"; else echo "  [..]   no \"Firefox (GPU)\" menu entry (installed only when Firefox is present)"; fi
  if grep -rqs -e 'tarkin-gpu' -e 'libmali' "$PREFIX/etc/vulkan" "$PREFIX/usr/share/vulkan/icd.d" "$PREFIX/usr/share/vulkan/implicit_layer.d" 2>/dev/null; then
    echo "  [no]   a system-wide Vulkan file points to libmali (not written by this script): every program would see the driver"; bad=1
  else
    echo "  [ok]   nothing system-wide points to the Mali Vulkan driver (only gpuapp does)"
  fi
  if [[ -z "$PREFIX" ]]; then
    if [[ -e "$DMA_HEAP" && "$(stat -c '%G %a' "$DMA_HEAP")" == "video 660" ]]; then
      echo "  [ok]   $DMA_HEAP is group video, mode 0660"
    else
      echo "  [no]   $DMA_HEAP is $(stat -c '%U:%G %a' "$DMA_HEAP" 2>/dev/null || echo missing) (expected group video, mode 660); reboot or run this script again"; bad=1
    fi
  fi
  if [[ -x "$GPUAPP" ]]; then
    "$GPUAPP" --check || bad=1
  else
    echo "apps on the GPU: no (gpuapp is not installed; run bash ~/install-gpuapp.sh)"
  fi
  return "$bad"
}

main() {
  check_environment

  if (( CHECK )); then
    verify_install && exit 0
    exit 1
  fi

  if (( REMOVE )); then
    if (( ! DRY_RUN )) && [[ -z "$PREFIX" ]]; then
      sudo -v || die "sudo needs your password."
    fi
    remove_files
    exit 0
  fi

  (( DRY_RUN )) && info "Dry run: checking what would be done."
  check_libmali
  check_desktop_gpu
  if (( ! DRY_RUN )) && [[ -z "$PREFIX" ]]; then
    sudo -v || die "sudo needs your password (the one chosen during the install)."
  fi
  install_packages
  WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tarkin-gpuapp.XXXXXX")"
  local built=""
  if (( DRY_RUN )); then
    if layer_is_current && (( ! REBUILD )); then
      info "The Vulkan Wayland layer is already installed; it would be kept."
    else
      info "Would download vulkan-wsi-layer ${WSI_COMMIT:0:7}, apply the embedded patch and compile it."
    fi
  else
    check_build_tools
    check_vulkan_driver
    if layer_is_current && (( ! REBUILD )); then
      info "The Vulkan Wayland layer is already installed (same source and patch); not compiled again."
    else
      build_layer
      built="$WORK_TMP/vulkan-wsi-layer/build"
    fi
  fi
  install_files "$built"
  apply_udev_rule
  (( DRY_RUN )) && { info "Dry run finished; nothing was changed."; exit 0; }

  echo
  ok "Done."
  echo "    Run a program on the GPU : gpuapp <program>      (example: gpuapp firefox)"
  echo "    Check                    : gpuapp --check         (or: bash ~/install-gpuapp.sh --check, sudo tarkin-diag)"
  echo "    Measure                  : gpuapp --measure"
  echo "    Remove                   : bash ~/install-gpuapp.sh --remove"
  echo "    Without gpuapp in front, programs render on the CPU as before. Wayland programs only."
  if [[ -n "$PREFIX" ]]; then
    echo "    (staging prefix: $PREFIX - pacman and udev were not touched)"
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    "$GPUAPP" --check || warn "gpuapp --check says no; if /dev/dma_heap/system was just changed, reboot and run: gpuapp --check"
  else
    echo "    Now run in a terminal of the Hyprland desktop: gpuapp --check"
  fi
}

# port/quigon/patches/vulkan-wsi-layer-quigon.patch, zoan37/lenovo-slim3-chromebook-omarchy 27ba99f (MIT), verbatim.
write_wsi_patch() {
  cat > "$1" <<'WSI_PATCH_EOF'
diff --git a/layer/layer.cpp b/layer/layer.cpp
index d06bd7b..b30ad32 100644
--- a/layer/layer.cpp
+++ b/layer/layer.cpp
@@ -22,6 +22,8 @@
  * SOFTWARE.
  */
 
+#include <sys/stat.h>
+#include <sys/sysmacros.h>
 #include <cassert>
 #include <cstdio>
 #include <cstring>
@@ -1037,6 +1039,47 @@ wsi_layer_vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physical_device,
    layer::populate_supported_layer_features(physical_device, *pFeatures);
 }
 
+/* quigon: ChromeOS's Mali ICD doesn't implement VK_EXT_physical_device_drm, so Mesa's Zink can't match it to the
+ * Wayland compositor's DRM device ("ZINK: failed to choose pdev") and falls back to llvmpipe. Fill the DRM properties
+ * from the real device nodes when the driver leaves them empty. */
+static void quigon_fill_drm_properties(VkPhysicalDeviceProperties2 *pProperties)
+{
+   auto *drm = util::find_extension<VkPhysicalDeviceDrmPropertiesEXT>(
+      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT, pProperties->pNext);
+   if (drm == nullptr || drm->hasRender || drm->hasPrimary)
+   {
+      return;
+   }
+   const char *render = getenv("QUIGON_VK_DRM_RENDER");
+   const char *primary = getenv("QUIGON_VK_DRM_PRIMARY");
+   struct stat st;
+   if (stat(render ? render : "/dev/dri/renderD128", &st) == 0 && S_ISCHR(st.st_mode))
+   {
+      drm->hasRender = VK_TRUE;
+      drm->renderMajor = major(st.st_rdev);
+      drm->renderMinor = minor(st.st_rdev);
+   }
+   if (stat(primary ? primary : "/dev/dri/card0", &st) == 0 && S_ISCHR(st.st_mode))
+   {
+      drm->hasPrimary = VK_TRUE;
+      drm->primaryMajor = major(st.st_rdev);
+      drm->primaryMinor = minor(st.st_rdev);
+   }
+}
+
+VWL_VKAPI_CALL(void)
+wsi_layer_vkGetPhysicalDeviceProperties2(VkPhysicalDevice physical_device,
+                                         VkPhysicalDeviceProperties2 *pProperties) VWL_API_POST
+{
+   auto &instance = layer::instance_private_data::get(physical_device);
+   auto fn = instance.disp.get_fn<PFN_vkGetPhysicalDeviceProperties2KHR>("vkGetPhysicalDeviceProperties2KHR");
+   if (fn.has_value())
+   {
+      (*fn)(physical_device, pProperties);
+   }
+   quigon_fill_drm_properties(pProperties);
+}
+
 #define GET_PROC_ADDR(func)      \
    if (!strcmp(funcName, #func)) \
       return (PFN_vkVoidFunction)&wsi_layer_##func;
@@ -1203,6 +1246,16 @@ wsi_layer_vkGetInstanceProcAddr(VkInstance instance, const char *funcName) VWL_A
       GET_PROC_ADDR(vkGetPhysicalDeviceFeatures2);
    }
 
+   if (instance_data.is_instance_extension_enabled(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME) &&
+       !strcmp(funcName, "vkGetPhysicalDeviceProperties2KHR"))
+   {
+      return (PFN_vkVoidFunction)&wsi_layer_vkGetPhysicalDeviceProperties2;
+   }
+   if (core_1_1)
+   {
+      GET_PROC_ADDR(vkGetPhysicalDeviceProperties2);
+   }
+
    if (instance_data.is_instance_extension_enabled(VK_KHR_SURFACE_EXTENSION_NAME))
    {
       PFN_vkVoidFunction wsi_func = wsi::get_proc_addr(funcName, instance_data);
diff --git a/wsi/wayland/surface.cpp b/wsi/wayland/surface.cpp
index e47d675..5cce63e 100644
--- a/wsi/wayland/surface.cpp
+++ b/wsi/wayland/surface.cpp
@@ -264,19 +264,22 @@ bool surface::init()
 
    if (explicit_sync_interface.get() == nullptr)
    {
-      WSI_LOG_ERROR("Failed to obtain zwp_linux_explicit_synchronization_v1 interface.");
-      return false;
+      /* quigon: compositors without zwp_linux_explicit_synchronization_v1 (Hyprland) get implicit sync:
+       * swapchain::present_image waits for the present fence on the CPU before committing. */
+      WSI_LOG_WARNING("zwp_linux_explicit_synchronization_v1 not available, falling back to CPU-waited sync.");
    }
-
-   auto surface_sync_obj =
-      zwp_linux_explicit_synchronization_v1_get_synchronization(explicit_sync_interface.get(), wayland_surface);
-   if (surface_sync_obj == nullptr)
+   else
    {
-      WSI_LOG_ERROR("Failed to retrieve surface synchronization interface");
-      return false;
-   }
+      auto surface_sync_obj =
+         zwp_linux_explicit_synchronization_v1_get_synchronization(explicit_sync_interface.get(), wayland_surface);
+      if (surface_sync_obj == nullptr)
+      {
+         WSI_LOG_ERROR("Failed to retrieve surface synchronization interface");
+         return false;
+      }
 
-   surface_sync_interface.reset(surface_sync_obj);
+      surface_sync_interface.reset(surface_sync_obj);
+   }
 
    VkResult vk_res = VK_SUCCESS;
    if (presentation_time_interface.get() != nullptr)
diff --git a/wsi/wayland/surface_properties.cpp b/wsi/wayland/surface_properties.cpp
index 366e262..b1285e6 100644
--- a/wsi/wayland/surface_properties.cpp
+++ b/wsi/wayland/surface_properties.cpp
@@ -376,7 +376,8 @@ static bool check_wl_protocols(struct wl_display *display)
       return false;
    }
 
-   return (supported.dmabuf && supported.explicit_sync);
+   /* quigon: explicit sync is optional (see surface.cpp). */
+   return supported.dmabuf;
 }
 
 VWL_VKAPI_CALL(VkBool32)
diff --git a/wsi/wayland/swapchain.cpp b/wsi/wayland/swapchain.cpp
index 0e0e8ed..c1481cb 100644
--- a/wsi/wayland/swapchain.cpp
+++ b/wsi/wayland/swapchain.cpp
@@ -24,6 +24,8 @@
 
 #define VK_USE_PLATFORM_WAYLAND_KHR 1
 
+#include <poll.h>
+#include <cerrno>
 #include "surface_properties.hpp"
 #include <cstdint>
 #include <cstring>
@@ -418,8 +420,19 @@ void swapchain::present_image(const pending_present_request &pending_present)
    }
    else if (present_sync_fd->is_valid())
    {
-      zwp_linux_surface_synchronization_v1_set_acquire_fence(m_wsi_surface->get_surface_sync_interface(),
-                                                             present_sync_fd->get());
+      if (m_wsi_surface->get_surface_sync_interface() != nullptr)
+      {
+         zwp_linux_surface_synchronization_v1_set_acquire_fence(m_wsi_surface->get_surface_sync_interface(),
+                                                                present_sync_fd->get());
+      }
+      else
+      {
+         /* quigon: no explicit sync protocol; make sure rendering is done before the compositor samples it. */
+         struct pollfd pfd = { present_sync_fd->get(), POLLIN, 0 };
+         while (poll(&pfd, 1, -1) < 0 && errno == EINTR)
+         {
+         }
+      }
    }
 
    /* TODO: work out damage */
WSI_PATCH_EOF
}

main "$@"
