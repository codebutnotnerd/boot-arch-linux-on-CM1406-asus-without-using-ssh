#!/bin/bash
set -euo pipefail

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "== $*"; }
warn() { echo "[!] $*" >&2; }
ok()   { echo "[+] $*"; }

usage() {
cat <<'USAGE_EOF'
Usage: bash install-hyprland.sh [options]          (boot-arch-linux-on-CM1406 v1.50.2)

Installs Hyprland and makes it render on the Mali-G57 GPU with the ChromeOS
libmali and a small EGL shim, instead of falling back to the CPU.
By default Hyprland starts by itself at boot through tarkin-console (no login
screen): on the CM1406 the GDM greeter goes black as soon as a key is pressed.
GNOME stays installed; --with-gdm makes GDM the display manager instead.

Options:
  --dry-run        Show what would be done; change nothing.
  --config-only    Only write or verify the Hyprland config (no sudo needed).
  --gpu-only       Only install the Mali GPU stack, the launcher and the session
                   (no packages, no config, no display changes).
  --with-gdm       Use GDM as the display manager (login screen, GNOME and
                   Hyprland sessions) instead of the auto-starting console.
                   The GDM greeter is known to go black on the CM1406.
  --no-packages    Skip the pacman step (packages are assumed to be installed).
  --reset-config   Back up and rewrite ~/.config/hypr/hyprland.lua even when it is valid.
  --mali-source P  Path to a libmali.so copied from the ChromeOS root partition.
                   Without it the script looks in /usr/local/lib/tarkin-gpu,
                   ~/gpu-test and finally the ChromeOS partitions (read-only).
  --skip-gpu-test  Do not abort when the GPU probe fails.
  --remove         Remove the Hyprland (Mali GPU) session and launcher.
                   GNOME and GDM are kept.
  --purge-gpu      With --remove: also delete /usr/local/lib/tarkin-gpu.
  -h, --help       Show this help.

Environment:
  FORCE_BOARD=1    Skip the "this is a google,tarkin board" check.
  TARKIN_PREFIX=D  Install everything under D instead of / (staging/testing only;
                   skips pacman and systemctl).

A stick made with the one-command installer (v1.50) runs this script by itself at the
first boot (tarkin-firstboot.service, as alarm); run it by hand only to repeat or repair.

After installing: reboot; Hyprland (Mali GPU) starts by itself. Sound check: tarkin-audio-test
With --with-gdm: reboot, then in GDM click the gear and pick "Hyprland (Mali GPU)".
USAGE_EOF
}

DRY_RUN=0
CONFIG_ONLY=0
GPU_ONLY=0
NO_PACKAGES=0
RESET_CONFIG=0
SKIP_GPU_TEST=0
REMOVE=0
PURGE_GPU=0
WITH_GDM=0
MALI_SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --config-only) CONFIG_ONLY=1 ;;
    --gpu-only) GPU_ONLY=1 ;;
    --no-packages) NO_PACKAGES=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --skip-gpu-test) SKIP_GPU_TEST=1 ;;
    --mali-source)
      [[ $# -ge 2 ]] || die "missing value for --mali-source"
      MALI_SRC="$2"; shift ;;
    --remove) REMOVE=1 ;;
    --purge-gpu) PURGE_GPU=1 ;;
    --with-gdm) WITH_GDM=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

(( PURGE_GPU == 0 || REMOVE == 1 )) || die "--purge-gpu must be used together with --remove."
(( CONFIG_ONLY == 0 || GPU_ONLY == 0 )) || die "--config-only and --gpu-only are mutually exclusive."
(( WITH_GDM == 0 || (GPU_ONLY == 0 && CONFIG_ONLY == 0 && REMOVE == 0) )) || die "--with-gdm cannot be combined with --gpu-only, --config-only or --remove."

if [[ $EUID -eq 0 && -z "${TARKIN_PREFIX:-}" ]]; then
  # Run as root (sudo bash install-hyprland.sh), $HOME is /root: the Hyprland
  # config would be written for root instead of the user who logs in on GDM,
  # and Hyprland --verify-config fails as root. The script calls sudo itself.
  echo "[-] Do not run this with sudo. Run it as your user: bash install-hyprland.sh (it asks for the sudo password itself)." >&2
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
SHIM_DIR="$GPU_ROOT/lib"
BIN_DIR="$GPU_ROOT/bin"
SRC_DIR="$GPU_ROOT/src"
WRAPPER="$PREFIX/usr/local/bin/hyprland-mali"
SESSION="$PREFIX/usr/share/wayland-sessions/hyprland-mali.desktop"
CONSOLE="$PREFIX/usr/local/libexec/tarkin/console"
TARKIN_SESSION_BIN="$PREFIX/usr/local/bin/tarkin-session"
CONSOLE_ENV="$PREFIX/etc/tarkin/console.env"

WORK_TMP=""
MALI_TMP=""
CHROMEOS_MNT=""

cleanup() {
  if [[ -n "$CHROMEOS_MNT" ]] && mountpoint -q "$CHROMEOS_MNT" 2>/dev/null; then
    umount "$CHROMEOS_MNT" 2>/dev/null || "${SUDO[@]}" umount "$CHROMEOS_MNT" 2>/dev/null || true
  fi
  if [[ -n "$CHROMEOS_MNT" ]]; then
    rmdir "$CHROMEOS_MNT" 2>/dev/null || true
  fi
  if [[ -n "$MALI_TMP" ]]; then
    rm -rf "$MALI_TMP"
  fi
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

will_install_packages() {
  (( ! GPU_ONLY && ! NO_PACKAGES )) && [[ -z "$PREFIX" ]]
}

check_build_tools() {
  command -v readelf >/dev/null 2>&1 || die "readelf is missing (binutils)."
  command -v gcc >/dev/null 2>&1 || die "gcc is missing: sudo pacman -S gcc"
  [[ -f /usr/include/EGL/egl.h && -f /usr/include/EGL/eglext.h ]] || die "EGL headers are missing: sudo pacman -S libglvnd"
  [[ -f /usr/include/libdrm/drm.h ]] || die "DRM headers are missing: sudo pacman -S libdrm"
}

check_environment() {
  [[ "$(uname -m)" == "aarch64" ]] || die "This is not an aarch64 machine."
  command -v pacman >/dev/null 2>&1 || die "pacman not found: this must run inside the Arch system."
  local compat
  compat="$(tr '\0' ' ' 2>/dev/null < /proc/device-tree/compatible || true)"
  if [[ -n "$compat" && "$compat" != *google,tarkin* && "${FORCE_BOARD:-0}" != 1 ]]; then
    die "This is not a google,tarkin board (compatible: $compat). Set FORCE_BOARD=1 to override."
  fi
  if (( ! CONFIG_ONLY && ! REMOVE )); then
    [[ -e /dev/mali0 ]] || die "The Mali kernel driver is missing (/dev/mali0 does not exist). This kernel build has no KBase support."
    # gcc, binutils, libglvnd and libdrm are installed by the package step; check them now only
    # when that step will not run (main() checks them again right after it).
    if ! will_install_packages; then
      check_build_tools
    fi
  fi
  if [[ -n "$MALI_SRC" && ! -f "$MALI_SRC" ]]; then
    die "--mali-source: no such file: $MALI_SRC"
  fi
  if (( ! DRY_RUN && ! CONFIG_ONLY && ! REMOVE )) && [[ -z "$PREFIX" ]]; then
    sudo -v || die "sudo needs your password (the one chosen during the install; sticks made before v1.50: alarm unless you changed it)."
  fi
}

install_packages() {
  command -v pacman >/dev/null 2>&1 || die "pacman not found: this must run inside the Arch system."
  getent hosts mirror.archlinuxarm.org >/dev/null 2>&1 || die "No network (cannot resolve mirror.archlinuxarm.org). Connect first: sudo tarkin-wifi \"NetworkName\"."
  local free_kb
  free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  (( free_kb >= 3145728 )) || die "Only $((free_kb / 1024)) MiB free on / (GNOME + Hyprland need about 3 GiB). Free some space with: sudo pacman -Scc"
  info "Refreshing the package database and upgrading the system (the ChromeOS kernel packages are ignored; this can take a while)..."
  sys pacman -Syu --noconfirm --noprogressbar --ignore linux-aarch64,linux-aarch64-headers
  local want=() avail=() p
  local base=(hyprland xdg-desktop-portal-hyprland gcc libglvnd mesa libc++ libc++abi libdrm python-pip)
  local apps=(waybar fuzzel swaybg mako foot brightnessctl papirus-icon-theme adw-gtk-theme inter-font noto-fonts noto-fonts-emoji pcmanfm)
  # Sound (v1.39.2): without PipeWire nothing plays (browsers use the PulseAudio
  # API); tarkin-audio.service needs pactl (libpulse), alsaucm and amixer (alsa-utils),
  # and python for the headphone jack watcher (v1.50).
  local audio=(pipewire wireplumber pipewire-pulse libpulse alsa-utils alsa-ucm-conf python)
  for p in "${base[@]}" "${apps[@]}" "${audio[@]}"; do
    if [[ "$p" == pipewire-pulse ]] && pacman -Q pulseaudio >/dev/null 2>&1; then
      # pipewire-pulse conflicts with pulseaudio; with --noconfirm pacman answers
      # "no" to removing it and aborts the whole transaction.
      warn "pulseaudio is installed, so pipewire-pulse is skipped (browsers may stay silent). Replace it with: sudo pacman -S pipewire-pulse (answer y to remove pulseaudio)."
      continue
    fi
    if ! pacman -Q "$p" >/dev/null 2>&1; then
      want+=("$p")
    fi
  done
  # The whole "gnome" group is not installed: on Arch Linux ARM some members
  # (gnome-books, gnome-boxes) depend on webkit2gtk/libsoup2, which no longer
  # exist, and pacman then aborts the whole transaction. A desktop-only list
  # is used instead; every package is checked for availability AND resolvable
  # dependencies, so one broken package is skipped instead of failing all.
  local gnome_core=(gnome-shell gnome-session gnome-settings-daemon gnome-control-center gdm gnome-keyring xdg-desktop-portal-gnome xdg-user-dirs-gtk gnome-backgrounds gnome-menus)
  local gnome_apps=(nautilus gnome-console gnome-text-editor gnome-system-monitor gnome-disk-utility gnome-calculator gnome-font-viewer gvfs loupe)
  for p in "${gnome_core[@]}" "${gnome_apps[@]}"; do
    if ! pacman -Q "$p" >/dev/null 2>&1; then
      want+=("$p")
    fi
  done
  for p in "${want[@]}"; do
    if ! pacman -Si "$p" >/dev/null 2>&1; then
      warn "$p is not available for this architecture (skipped)."
    elif ! pacman -Sp --print-format '%n' "$p" </dev/null >/dev/null 2>&1; then
      warn "$p has dependencies that cannot be installed on this architecture (skipped)."
    else
      avail+=("$p")
    fi
  done
  if (( ${#avail[@]} )); then
    info "Installing: ${avail[*]}"
    sys pacman -S --needed --noconfirm --noprogressbar "${avail[@]}"
  else
    info "All packages are already installed."
  fi
  local c
  for c in Hyprland start-hyprland gdm gnome-shell gcc; do
    command -v "$c" >/dev/null 2>&1 || die "$c is missing after the package step; see the pacman output above."
  done
}

lib_has_relr_abi() {
  readelf -V "$1" 2>/dev/null | grep -q GLIBC_ABI_DT_RELR
}

find_lief_python() {
  local p
  for p in python3 "$HOME/.venvs/lief/bin/python" "$HOME/.local/share/tarkin-gpu/venv/bin/python"; do
    if command -v "$p" >/dev/null 2>&1 || [[ -x "$p" ]]; then
      if "$p" -c 'import lief' >/dev/null 2>&1; then
        echo "$p"
        return 0
      fi
    fi
  done
  return 1
}

ensure_lief_python() {
  local p venv="$HOME/.local/share/tarkin-gpu/venv"
  if p="$(find_lief_python)"; then
    echo "$p"
    return 0
  fi
  warn "LIEF is not available yet; trying: python3 -m pip install --user lief"
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m pip install --user --break-system-packages --disable-pip-version-check --quiet lief >/dev/null 2>&1; then
      echo "python3"
      return 0
    fi
    if python3 -m venv "$venv" >/dev/null 2>&1 && "$venv/bin/pip" install --disable-pip-version-check --quiet lief >/dev/null 2>&1; then
      echo "$venv/bin/python"
      return 0
    fi
  fi
  return 1
}

write_relr_patcher() {
  cat > "$1" <<'PYRELR_EOF'
import sys
from pathlib import Path
import lief

def elf_hash(name):
    h = 0
    for c in name.encode():
        h = (h << 4) + c
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
            h &= ~g
    return h & 0xFFFFFFFF

src, dst = sys.argv[1:3]
binary = lief.ELF.parse(src)
if binary is None or not binary.has(lief.ELF.DynamicEntry.TAG.RELR):
    sys.exit("libmali has no DT_RELR sections; this copy cannot be patched")
requirements = {r.name: r for r in binary.symbols_version_requirement}
libc = requirements.get("libc.so.6")
if libc is None:
    sys.exit("libmali has no libc.so.6 version requirement")
if any(a.name == "GLIBC_ABI_DT_RELR" for a in libc.get_auxiliary_symbols()):
    sys.exit("GLIBC_ABI_DT_RELR is already present")
used = {a.other for r in requirements.values() for a in r.get_auxiliary_symbols()}
aux = lief.ELF.SymbolVersionAuxRequirement()
aux.name = "GLIBC_ABI_DT_RELR"
aux.hash = elf_hash(aux.name)
aux.flags = 0
aux.other = max(used) + 1
libc.add_auxiliary_requirement(aux)
Path(dst).parent.mkdir(parents=True, exist_ok=True)
binary.write(dst)
PYRELR_EOF
}

patch_relr() {
  local src="$1" dst="$2" py
  if ! py="$(ensure_lief_python)"; then
    die "LIEF is unavailable, so libmali cannot be patched for Arch's glibc.
    Get a libmali.so that already carries GLIBC_ABI_DT_RELR (for example the one in ~/gpu-test)
    and pass it with: --mali-source /path/to/libmali.so"
  fi
  echo "== Patching libmali (adding the GLIBC_ABI_DT_RELR version dependency) with LIEF..."
  "$py" "$WORK_TMP/patch-relr.py" "$src" "$dst" || die "The RELR patch failed."
  lib_has_relr_abi "$dst" || die "The patched libmali still misses GLIBC_ABI_DT_RELR."
}

pick_mali_source() {
  local f
  if [[ -n "$MALI_SRC" ]]; then
    [[ -f "$MALI_SRC" ]] || die "--mali-source: no such file: $MALI_SRC"
    realpath -e "$MALI_SRC"
    return 0
  fi
  if [[ -f "$MALI_LIB/libmali.so.0.54.1" ]]; then
    echo "$MALI_LIB/libmali.so.0.54.1"
    return 0
  fi
  for f in "$HOME/gpu-test/mali/lib/libmali.so.0.54.1.relr" \
           "$HOME/gpu-test/mali/libmali.so.0.54.1.relr" \
           "$HOME/gpu-test/mali/lib/libmali.so.0.54.1" \
           "$HOME/gpu-test/mali/libmali.so.0.54.1" \
           "$HOME/gpu-test/mali/libmali.so.0.54.1.orig"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  find_mali_in_chromeos
}

find_mali_in_chromeos() {
  if (( DRY_RUN )) || [[ -n "$PREFIX" ]]; then
    return 1
  fi
  local part mnt hit dst
  if [[ -z "$CHROMEOS_MNT" ]]; then
    CHROMEOS_MNT="$(mktemp -d /tmp/tarkin-chromeos.XXXXXX)"
  fi
  mnt="$CHROMEOS_MNT"
  for part in /dev/disk/by-partlabel/ROOT-A /dev/disk/by-partlabel/ROOT-B; do
    if [[ ! -e "$part" ]]; then
      continue
    fi
    if mountpoint -q "$mnt" 2>/dev/null; then
      umount "$mnt" 2>/dev/null || true
    fi
    if ! "${SUDO[@]}" mount -o ro,noload "$part" "$mnt" 2>/dev/null; then
      warn "Could not mount $part read-only; skipping it."
      continue
    fi
    hit="$("${SUDO[@]}" find "$mnt/usr/lib64" "$mnt/usr/lib" -name 'libmali.so.0.54*' -not -type l 2>/dev/null | sort | tail -1)"
    if [[ -z "$hit" ]]; then
      hit="$("${SUDO[@]}" find "$mnt/usr/lib64" "$mnt/usr/lib" -name 'libmali.so*' -not -type l 2>/dev/null | sort | tail -1)"
    fi
    dst=""
    if [[ -n "$hit" ]]; then
      # Copy while the partition is still mounted; this function's stdout is the path only.
      echo "[+] Found libmali on $part: $hit (copied read-only, the partition is never written to)" >&2
      MALI_TMP="$(mktemp -d /tmp/tarkin-mali.XXXXXX)"
      dst="$MALI_TMP/libmali.so"
      if ! "${SUDO[@]}" cat "$hit" > "$dst" || [[ ! -s "$dst" ]]; then
        warn "Could not copy $hit; skipping $part."
        rm -rf "$MALI_TMP"; MALI_TMP=""; dst=""
      fi
    fi
    umount "$mnt" 2>/dev/null || "${SUDO[@]}" umount "$mnt" 2>/dev/null || true
    if [[ -n "$dst" ]]; then
      rmdir "$mnt" 2>/dev/null || true
      echo "$dst"
      return 0
    fi
  done
  rmdir "$mnt" 2>/dev/null || true
  return 1
}

write_shim() {
  cat > "$1" <<'SHIM_C_EOF'
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef EGL_DRM_RENDER_NODE_FILE_EXT
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377
#endif

static const char *EXTRA_CLIENT = " EGL_EXT_device_base EGL_EXT_device_enumeration EGL_EXT_device_query"
                                  " EGL_EXT_platform_device EGL_KHR_platform_gbm EGL_MESA_platform_gbm";
static EGLDeviceEXT FAKE_DEVICE = (EGLDeviceEXT)(void *)0x51a1c0de;
static char client_ext[4096];
static int trace;

#define REAL(name) static __typeof__(name) *real_##name; if (!real_##name) real_##name = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)
#define LOG(...) do { if (trace) fprintf(stderr, "[egl-mali-shim] " __VA_ARGS__); } while (0)

__attribute__((constructor)) static void shim_init(void) {
  trace = getenv("QUIGON_EGL_SHIM_TRACE") != NULL;
  char exe[512] = {0};
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  const char *base = n > 0 ? strrchr(exe, '/') : NULL;
  base = base ? base + 1 : exe;
  const char *want = getenv("QUIGON_EGL_SHIM_EXE");
  if (!strcmp(base, want ? want : "Hyprland")) {
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");
    LOG("active in %s (pid %d), cleared LD_PRELOAD/LD_LIBRARY_PATH for children\n", base, getpid());
  }
}

static EGLDisplay default_display(void) {
  static __typeof__(eglGetDisplay) *real_get;
  if (!real_get) real_get = (__typeof__(eglGetDisplay) *)dlsym(RTLD_NEXT, "eglGetDisplay");
  return real_get ? real_get(EGL_DEFAULT_DISPLAY) : EGL_NO_DISPLAY;
}

const char *eglQueryString(EGLDisplay dpy, EGLint name) {
  REAL(eglQueryString);
  const char *s = real_eglQueryString(dpy, name);
  if (dpy == EGL_NO_DISPLAY && name == EGL_EXTENSIONS) {
    if (!client_ext[0]) snprintf(client_ext, sizeof client_ext, "%s%s", s ? s : "", EXTRA_CLIENT);
    return client_ext;
  }
  return s;
}

EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native, const EGLAttrib *attrs) {
  (void)native; (void)attrs;
  LOG("eglGetPlatformDisplay(0x%x) -> default display\n", platform);
  return default_display();
}

EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native, const EGLint *attrs) {
  (void)native; (void)attrs;
  LOG("eglGetPlatformDisplayEXT(0x%x) -> default display\n", platform);
  return default_display();
}

EGLBoolean eglQueryDevicesEXT(EGLint max, EGLDeviceEXT *devices, EGLint *num) {
  if (!num) return EGL_FALSE;
  if (devices && max > 0) devices[0] = FAKE_DEVICE;
  *num = 1;
  return EGL_TRUE;
}

const char *eglQueryDeviceStringEXT(EGLDeviceEXT dev, EGLint name) {
  if (dev != FAKE_DEVICE) return NULL;
  const char *primary = getenv("QUIGON_DRM_PRIMARY"), *render = getenv("QUIGON_DRM_RENDER");
  switch (name) {
  case EGL_EXTENSIONS: return "EGL_EXT_device_drm EGL_EXT_device_drm_render_node";
  case EGL_DRM_DEVICE_FILE_EXT: return primary ? primary : "/dev/dri/card0";
  case EGL_DRM_RENDER_NODE_FILE_EXT: return render ? render : "/dev/dri/renderD128";
  default: return NULL;
  }
}

EGLBoolean eglQueryDeviceAttribEXT(EGLDeviceEXT dev, EGLint attr, EGLAttrib *value) {
  (void)dev; (void)attr; (void)value;
  return EGL_FALSE;
}

EGLBoolean eglQueryDisplayAttribEXT(EGLDisplay dpy, EGLint attr, EGLAttrib *value) {
  (void)dpy;
  if (attr == EGL_DEVICE_EXT && value) { *value = (EGLAttrib)FAKE_DEVICE; return EGL_TRUE; }
  return EGL_FALSE;
}

static EGLint stub_eglDebugMessageControlKHR(void *cb, const EGLAttrib *attrs) { (void)cb; (void)attrs; return EGL_SUCCESS; }

__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name) {
  REAL(eglGetProcAddress);
  static const struct { const char *n; void *f; } ours[] = {
    {"eglGetPlatformDisplay", (void *)eglGetPlatformDisplay},
    {"eglGetPlatformDisplayEXT", (void *)eglGetPlatformDisplayEXT},
    {"eglQueryDevicesEXT", (void *)eglQueryDevicesEXT},
    {"eglQueryDeviceStringEXT", (void *)eglQueryDeviceStringEXT},
    {"eglQueryDeviceAttribEXT", (void *)eglQueryDeviceAttribEXT},
    {"eglQueryDisplayAttribEXT", (void *)eglQueryDisplayAttribEXT},
    {"eglQueryString", (void *)eglQueryString},
  };
  for (size_t i = 0; i < sizeof ours / sizeof ours[0]; i++)
    if (!strcmp(name, ours[i].n)) return (__eglMustCastToProperFunctionPointerType)ours[i].f;
  __eglMustCastToProperFunctionPointerType p = real_eglGetProcAddress(name);
  if (!p && !strcmp(name, "eglDebugMessageControlKHR")) p = (__eglMustCastToProperFunctionPointerType)stub_eglDebugMessageControlKHR;
  if (!p) LOG("eglGetProcAddress(%s) = NULL\n", name);
  return p;
}
SHIM_C_EOF
}

write_shim_probe() {
  cat > "$1" <<'PROBE_SHIM_EOF'
#include <stdio.h>
#include <string.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif

int main(void) {
    const char *ext = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    printf("Client extensions: %s\n", ext ? ext : "NULL");
    if (!ext || !strstr(ext, "EGL_EXT_platform_device")) {
        puts("FAIL: EGL_EXT_platform_device is missing");
        return 1;
    }
    PFNEGLQUERYDEVICESEXTPROC queryDevices =
        (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC queryString =
        (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    PFNEGLGETPLATFORMDISPLAYEXTPROC getDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!queryDevices || !queryString || !getDisplay) {
        puts("FAIL: an EGL function is missing");
        return 1;
    }
    EGLDeviceEXT device;
    EGLint count = 0;
    if (!queryDevices(1, &device, &count) || count != 1) {
        puts("FAIL: no EGL device found");
        return 1;
    }
    printf("DRM primary: %s\n", queryString(device, EGL_DRM_DEVICE_FILE_EXT));
    printf("DRM render: %s\n", queryString(device, EGL_DRM_RENDER_NODE_FILE_EXT));
    EGLDisplay display = getDisplay(EGL_PLATFORM_GBM_KHR, (void *)device, NULL);
    EGLint major, minor;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
        printf("FAIL: eglInitialize: 0x%x\n", eglGetError());
        return 1;
    }
    printf("EGL: %d.%d\n", major, minor);
    printf("Vendor: %s\n", eglQueryString(display, EGL_VENDOR));
    puts("SHIM TEST: PASS");
    eglTerminate(display);
    return 0;
}
PROBE_SHIM_EOF
}

write_mali_probe() {
  cat > "$1" <<'PROBE_MALI_EOF'
#define EGL_EGLEXT_PROTOTYPES 1
#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
#define CHECK(c, m) do { if (!(c)) { fprintf(stderr, "FAIL: %s (egl 0x%x gl 0x%x)\n", m, eglGetError(), glGetError()); return 1; } } while (0)

int main(int argc, char **argv) {
  int frames = argc > 1 ? atoi(argv[1]) : 100;
  const char *ce = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  printf("client extensions: %s\n", ce ? ce : "(none)");
  EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  CHECK(dpy != EGL_NO_DISPLAY, "eglGetDisplay");
  EGLint maj, min;
  CHECK(eglInitialize(dpy, &maj, &min), "eglInitialize");
  printf("EGL %d.%d vendor=%s version=%s\nclient APIs: %s\ndisplay extensions: %s\n", maj, min,
         eglQueryString(dpy, EGL_VENDOR), eglQueryString(dpy, EGL_VERSION),
         eglQueryString(dpy, EGL_CLIENT_APIS), eglQueryString(dpy, EGL_EXTENSIONS));
  CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
  EGLint cattr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, cattr);
  if (ctx == EGL_NO_CONTEXT) {
    EGLint ca[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE}, n; EGLConfig cfg;
    eglChooseConfig(dpy, ca, &cfg, 1, &n);
    ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, cattr);
  }
  CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext");
  CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "eglMakeCurrent surfaceless");
  printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\nGLSL=%s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER),
         glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
  printf("GL extensions: %s\n", glGetString(GL_EXTENSIONS));

  GLuint tex, fbo; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "fbo complete");
  glClearColor(0.0f, 1.0f, 0.0f, 1.0f); glClear(GL_COLOR_BUFFER_BIT);
  uint8_t px[4] = {0}; glReadPixels(10, 10, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
  printf("fbo clear readback: %u %u %u %u -> %s\n", px[0], px[1], px[2], px[3], px[1] == 255 && px[0] == 0 ? "PASS" : "FAIL");

  int drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
  CHECK(drm >= 0, "open card0");
  struct drm_mode_create_dumb cd = {.width = 1920, .height = 1200, .bpp = 32};
  CHECK(ioctl(drm, DRM_IOCTL_MODE_CREATE_DUMB, &cd) == 0, "CREATE_DUMB");
  struct drm_prime_handle ph = {.handle = cd.handle, .flags = DRM_CLOEXEC | DRM_RDWR};
  CHECK(ioctl(drm, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph) == 0, "PRIME_HANDLE_TO_FD");
  EGLint iattr[] = {EGL_WIDTH, 1920, EGL_HEIGHT, 1200, EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_XRGB8888,
                    EGL_DMA_BUF_PLANE0_FD_EXT, ph.fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                    EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)cd.pitch, EGL_NONE};
  EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, iattr);
  CHECK(img != EGL_NO_IMAGE_KHR, "eglCreateImageKHR dmabuf");
  GLuint rb, fbo2; glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
  glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, img);
  glGenFramebuffers(1, &fbo2); glBindFramebuffer(GL_FRAMEBUFFER, fbo2);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "dmabuf fbo complete");
  struct drm_mode_map_dumb md = {.handle = cd.handle};
  CHECK(ioctl(drm, DRM_IOCTL_MODE_MAP_DUMB, &md) == 0, "MAP_DUMB");
  uint32_t *map = mmap(NULL, cd.size, PROT_READ, MAP_SHARED, drm, md.offset);
  CHECK(map != MAP_FAILED, "mmap dumb");
  int bad = 0; double t0 = now_ms();
  for (int f = 0; f < frames; f++) {
    float r = (f % 3 == 0), g = (f % 3 == 1), b = (f % 3 == 2);
    glViewport(0, 0, 1920, 1200); glClearColor(r, g, b, 1.0f); glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    uint32_t want = (r ? 0xff0000 : 0) | (g ? 0x00ff00 : 0) | (b ? 0x0000ff : 0);
    uint32_t got = map[(600 * cd.pitch / 4) + 960] & 0xffffff;
    if (got != want) { if (bad < 5) fprintf(stderr, "frame %d: got %06x want %06x\n", f, got, want); bad++; }
  }
  double dt = now_ms() - t0;
  printf("dmabuf render: %d frames, %d bad, %.2f ms/frame -> %s\n", frames, bad, dt / frames, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}
PROBE_MALI_EOF
}

run_gpu_probes() {
  local d="$1"
  if (( SKIP_GPU_TEST )); then
    warn "Skipping the GPU probe (--skip-gpu-test)."
    return 0
  fi
  echo "== GPU probe: EGL + GLES through libmali, DMA-BUF render into a DRM dumb buffer (10 frames)..."
  if ! env LD_LIBRARY_PATH="$d" "$d/mali-probe" 10; then
    die "The Mali GPU probe failed; nothing was installed. Check: tarkin-gpu-check, dmesg | grep -i mali, and that this user is in the video and render groups."
  fi
  echo "== Shim probe: the EGL device/platform extensions Hyprland and Aquamarine need..."
  if ! env LD_LIBRARY_PATH="$d" LD_PRELOAD="$d/egl-mali-shim.so" "$d/shim-probe"; then
    die "The EGL shim probe failed; nothing was installed."
  fi
}

write_wrapper() {
  cat > "$1" <<'WRAPPER_EOF'
#!/bin/sh
set -eu
GPU="@GPU@"
MALI="@MALI@"
SHIM="@SHIM@"
unset WLR_RENDERER WLR_NO_HARDWARE_CURSORS LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER_ALLOW_SOFTWARE
card="${TARKIN_GPU_CARD:-}"
if [ -z "$card" ]; then
  for c in /sys/class/drm/card[0-9]; do
    if [ -e "$c" ]; then
      case "$(readlink -f "$c/device/driver" 2>/dev/null)" in
        *mediatek*) card="/dev/dri/$(basename "$c")"; break ;;
      esac
    fi
  done
fi
card="${card:-/dev/dri/card0}"
render="/dev/dri/renderD128"
for r in "/sys/class/drm/$(basename "$card")/device/drm"/renderD*; do
  if [ -e "$r" ]; then
    render="/dev/dri/$(basename "$r")"
    break
  fi
done
export LD_LIBRARY_PATH="$MALI"
export LD_PRELOAD="$SHIM"
export HYPRLAND_EGL_NO_MODIFIERS=1 AQ_NO_MODIFIERS=1 GBM_ALWAYS_SOFTWARE=1
export QUIGON_DRM_PRIMARY="$card" QUIGON_DRM_RENDER="$render" QUIGON_EGL_SHIM_EXE=Hyprland
export XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=Hyprland XDG_CURRENT_DESKTOP=Hyprland
start="${TARKIN_START_HYPRLAND:-/usr/bin/start-hyprland}"
[ -x "$start" ] || start="/usr/bin/Hyprland"
exec "$start" "$@"
WRAPPER_EOF
  sed -i "s|@GPU@|$GPU_ROOT|g; s|@MALI@|$MALI_LIB|g; s|@SHIM@|$SHIM_DIR/egl-mali-shim.so|g" "$1"
}

write_session_file() {
  cat > "$1" <<'SESSION_EOF'
[Desktop Entry]
Name=Hyprland (Mali GPU)
Comment=Hyprland on the Mali-G57 GPU
Exec=@WRAPPER@
TryExec=@WRAPPER@
Type=Application
DesktopNames=Hyprland
Keywords=tiling;wayland;compositor;
SESSION_EOF
  sed -i "s|@WRAPPER@|$WRAPPER|g" "$1"
}

install_gpu_files() {
  local d="$1"
  if (( DRY_RUN )); then
    echo "   [dry-run] install the GPU stack into $GPU_ROOT, the launcher into $WRAPPER and the session into $SESSION"
    return 0
  fi
  sys install -d -m 755 "$GPU_ROOT" "$MALI_LIB" "$SHIM_DIR" "$BIN_DIR" "$SRC_DIR"
  sys install -m 755 "$d/libmali.so.0.54.1" "$MALI_LIB/libmali.so.0.54.1"
  sys ln -sfn libmali.so.0.54.1 "$MALI_LIB/libmali.so.0"
  sys ln -sfn libmali.so.0 "$MALI_LIB/libEGL.so.1"
  sys ln -sfn libmali.so.0 "$MALI_LIB/libGLESv1_CM.so.1"
  sys ln -sfn libmali.so.0 "$MALI_LIB/libGLESv2.so.2"
  sys install -m 755 "$d/egl-mali-shim.so" "$SHIM_DIR/egl-mali-shim.so"
  sys install -m 755 "$d/shim-probe" "$d/mali-probe" "$BIN_DIR/"
  sys install -m 644 "$d/egl-mali-shim.c" "$d/shim-probe.c" "$d/mali-probe.c" "$d/patch-relr.py" "$SRC_DIR/"
  sys install -m 755 "$d/hyprland-mali" "$WRAPPER"
  sys install -D -m 644 "$d/hyprland-mali.desktop" "$SESSION"
  lib_has_relr_abi "$MALI_LIB/libmali.so.0.54.1" || die "The installed libmali is missing GLIBC_ABI_DT_RELR."
  ok "GPU stack installed in $GPU_ROOT"
  ok "Launcher installed: $WRAPPER"
  ok "Session installed: $SESSION"
}

install_gpu_stack() {
  local src
  info "Locating the ChromeOS libmali (Mali-G57 userspace driver)..."
  if ! src="$(pick_mali_source)"; then
    die "No libmali found. Copy it from the ChromeOS root partition (mount -o ro,noload) or pass: --mali-source /path/to/libmali.so"
  fi
  echo "[+] Source: $src"
  case "$src" in /tmp/tarkin-mali.*/libmali.so) MALI_TMP="$(dirname "$src")" ;; esac
  if ! readelf -h "$src" 2>/dev/null | grep -q 'Machine:.*AArch64'; then
    die "$src is not an AArch64 ELF shared library."
  fi
  WORK_TMP="$(mktemp -d /tmp/tarkin-hyprland.XXXXXX)"
  trap cleanup EXIT
  write_relr_patcher "$WORK_TMP/patch-relr.py"
  if lib_has_relr_abi "$src"; then
    echo "[+] libmali already carries GLIBC_ABI_DT_RELR; using it as is."
    cp -L "$src" "$WORK_TMP/libmali.so.0.54.1"
  else
    patch_relr "$src" "$WORK_TMP/libmali.so.0.54.1"
  fi
  chmod 755 "$WORK_TMP/libmali.so.0.54.1"
  ln -sfn libmali.so.0.54.1 "$WORK_TMP/libmali.so.0"
  ln -sfn libmali.so.0.54.1 "$WORK_TMP/libmali.so"
  echo "== Compiling the EGL shim and the GPU probes..."
  write_shim "$WORK_TMP/egl-mali-shim.c"
  write_shim_probe "$WORK_TMP/shim-probe.c"
  write_mali_probe "$WORK_TMP/mali-probe.c"
  gcc -O2 -shared -fPIC -o "$WORK_TMP/egl-mali-shim.so" "$WORK_TMP/egl-mali-shim.c" -ldl
  gcc -O2 -o "$WORK_TMP/shim-probe" "$WORK_TMP/shim-probe.c" -L"$WORK_TMP" -lmali -ldl
  gcc -O2 -o "$WORK_TMP/mali-probe" "$WORK_TMP/mali-probe.c" -L"$WORK_TMP" -lmali -ldl -I/usr/include/libdrm
  run_gpu_probes "$WORK_TMP"
  write_wrapper "$WORK_TMP/hyprland-mali"
  write_session_file "$WORK_TMP/hyprland-mali.desktop"
  install_gpu_files "$WORK_TMP"
}

write_console_files() {
  if (( DRY_RUN )); then
    echo "   [dry-run] write the GPU-aware console into $CONSOLE and the session switcher into $TARKIN_SESSION_BIN"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/console" <<'TARKIN_CONSOLE_EOF'
#!/bin/bash
set -u
cd "$HOME" || exit 1
uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/$uid"
n=0
while [[ ! -d "$XDG_RUNTIME_DIR" && $n -lt 60 ]]; do
  sleep 1; n=$((n+1))
done
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
  echo "tarkin-console: $XDG_RUNTIME_DIR missing after ${n}s (user manager not running? check linger)" >&2
  exit 1
fi
# This is a *system* service, not a logind session: export the user D-Bus so
# GTK/portal apps started from the terminal or the desktop can reach it.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export LIBSEAT_BACKEND=seatd SEATD_VTBOUND=0
export LANG=C.UTF-8
n=0
until ls /dev/dri/card[0-9] >/dev/null 2>&1 || (( n >= 20 )); do sleep 1; n=$((n+1)); done
card=/dev/dri/card0
for c in /sys/class/drm/card[0-9]; do
  [[ -e "$c" && -e "/dev/dri/$(basename "$c")" ]] || continue
  if [[ "$(readlink -f "$c/device/driver" 2>/dev/null)" == *mediatek* ]]; then card="/dev/dri/$(basename "$c")"; break; fi
done
unset WAYLAND_DISPLAY DISPLAY
[[ -f /etc/tarkin/console.env ]] && . /etc/tarkin/console.env
export XKB_DEFAULT_LAYOUT="${XKB_DEFAULT_LAYOUT:-us}"
export AQ_DRM_DEVICES="$card" XDG_SESSION_TYPE=wayland
session="${TARKIN_SESSION:-terminal}"
echo "tarkin-console: display $card, keyboard layout $XKB_DEFAULT_LAYOUT, session $session"

# The on-screen terminal (cage + foot) is wlroots. There is no working EGL for
# this display, so letting wlroots probe GLES2 stalls or fails (long black
# screen, restart loop). Pin it like the earlier working release did: pixman
# renderer, software cursor, MediaTek display node. Hyprland unsets WLR_RENDERER.
run_terminal() {
  unset LD_PRELOAD LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER_ALLOW_SOFTWARE AQ_NO_MODIFIERS
  export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 WLR_DRM_DEVICES="$card"
  exec cage -- foot
}

if [[ "$session" != desktop ]]; then
  run_terminal
fi

gpu_cmd=()
default_cmd=()
[[ -x /usr/local/bin/hyprland-mali ]] && gpu_cmd=(/usr/local/bin/hyprland-mali)
if command -v start-hyprland >/dev/null 2>&1; then
  default_cmd=(start-hyprland)
elif command -v Hyprland >/dev/null 2>&1; then
  default_cmd=(Hyprland)
fi
if (( ${#gpu_cmd[@]} == 0 && ${#default_cmd[@]} == 0 )); then
  echo "tarkin-console: session desktop requested but Hyprland is not installed (run ~/install-desktop.sh); showing the terminal." >&2
  run_terminal
fi

render="${TARKIN_HYPR_RENDER:-auto}"
case "$render" in
  gpu|default|software) ;;
  *) render=auto ;;
esac
modes=()
case "$render" in
  gpu)
    if (( ${#gpu_cmd[@]} )); then
      modes=(gpu)
    else
      echo "tarkin-console: TARKIN_HYPR_RENDER=gpu but /usr/local/bin/hyprland-mali is missing; trying the default renderer then software." >&2
      if (( ${#default_cmd[@]} )); then modes=(default software); else modes=(software); fi
    fi
    ;;
  default)
    if (( ${#default_cmd[@]} )); then
      modes=(default)
    else
      echo "tarkin-console: TARKIN_HYPR_RENDER=default but Hyprland is missing; trying software." >&2
      modes=(software)
    fi
    ;;
  software)
    modes=(software)
    ;;
  *)
    if (( ${#gpu_cmd[@]} )); then modes+=(gpu); fi
    if (( ${#default_cmd[@]} )); then modes+=(default); fi
    modes+=(software)
    ;;
esac

set_hypr_env() {
  unset LD_PRELOAD LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER WLR_RENDERER_ALLOW_SOFTWARE AQ_NO_MODIFIERS
  export XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland AQ_DRM_DEVICES="$card"
}

for mode in "${modes[@]}"; do
  set_hypr_env
  cmd=()
  case "$mode" in
    gpu)
      cmd=("${gpu_cmd[@]}")
      echo "tarkin-console: starting Hyprland on the Mali GPU (hyprland-mali)." >&2
      ;;
    default)
      cmd=("${default_cmd[@]}")
      echo "tarkin-console: starting ${cmd[0]} with the default renderer." >&2
      ;;
    software)
      cmd=("${default_cmd[@]}")
      if (( ${#cmd[@]} == 0 )); then cmd=(Hyprland); fi
      echo "tarkin-console: starting ${cmd[0]} with software rendering." >&2
      export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_LOADER_DRIVER_OVERRIDE=kms_swrast AQ_NO_MODIFIERS=1 WLR_RENDERER_ALLOW_SOFTWARE=1
      ;;
  esac
  start=$SECONDS
  "${cmd[@]}"
  rc=$?
  if (( SECONDS - start >= 15 )); then
    exit "$rc"
  fi
  echo "tarkin-console: Hyprland ($mode) exited after $((SECONDS - start))s (code $rc)." >&2
done
echo "tarkin-console: the desktop does not start; falling back to the terminal. See: sudo tarkin-diag" >&2
run_terminal
TARKIN_CONSOLE_EOF
  cat > "$tmp/tarkin-session" <<'TARKIN_SESSION_EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in desktop|terminal) ;; *) echo "Usage: sudo tarkin-session desktop|terminal" >&2; exit 1 ;; esac
[[ $EUID -eq 0 ]] || { echo "Run it with sudo." >&2; exit 1; }
if systemctl is-active --quiet gdm.service 2>/dev/null; then
  echo "GDM owns the display (install-hyprland.sh): pick the session with the gear in GDM." >&2
  echo "To use the on-screen console instead: sudo systemctl disable --now gdm && sudo systemctl enable --now tarkin-console" >&2
  exit 1
fi
f=/etc/tarkin/console.env
mkdir -p /etc/tarkin
touch "$f"
if grep -q '^TARKIN_SESSION=' "$f"; then
  sed -i "s/^TARKIN_SESSION=.*/TARKIN_SESSION=$1/" "$f"
else
  echo "TARKIN_SESSION=$1" >> "$f"
fi
echo "Session set to: $1. Restarting the display now (this window will close)..."
systemctl --no-block restart tarkin-console.service
TARKIN_SESSION_EOF
  sys install -D -m 755 "$tmp/console" "$CONSOLE"
  sys install -D -m 755 "$tmp/tarkin-session" "$TARKIN_SESSION_BIN"
  rm -rf "$tmp"
  ok "Console updated: $CONSOLE (tries hyprland-mali, then Hyprland, then software, then the terminal)"
}

fix_console_env() {
  if [[ ! -f "$CONSOLE_ENV" && ! -e "$CONSOLE" ]]; then
    return 0
  fi
  if (( DRY_RUN )); then
    echo "   [dry-run] set TARKIN_HYPR_RENDER=auto in $CONSOLE_ENV"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$CONSOLE_ENV" ]]; then
    cp "$CONSOLE_ENV" "$tmp"
    sed -i 's/^TARKIN_HYPR_RENDER=.*/TARKIN_HYPR_RENDER=auto/' "$tmp"
  fi
  if ! grep -q '^TARKIN_HYPR_RENDER=' "$tmp"; then
    printf 'TARKIN_HYPR_RENDER=auto\n' >> "$tmp"
  fi
  sys install -D -m 644 "$tmp" "$CONSOLE_ENV"
  rm -f "$tmp"
  ok "TARKIN_HYPR_RENDER=auto in $CONSOLE_ENV (the console prefers the GPU and falls back on its own)"
}

backup_file() {
  if [[ -e "$1" ]]; then
    cp -a "$1" "$1.bak.$(date +%s)"
  fi
}

write_hyprland_config() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  local lua="$cfg/hypr/hyprland.lua"
  local conf="$cfg/hypr/hyprland.conf"
  local kblayout
  mkdir -p "$cfg/hypr"
  if ! command -v Hyprland >/dev/null 2>&1; then
    die "Hyprland is not installed; run this script without --config-only (or --gpu-only)."
  fi
  if [[ -f "$lua" && $RESET_CONFIG -eq 0 ]]; then
    if Hyprland --verify-config >/dev/null 2>&1; then
      ok "Keeping the existing $lua (it verifies)."
      return 0
    fi
    warn "$lua has errors; backing it up and writing a known-good config."
  elif [[ -f "$lua" ]]; then
    warn "--reset-config: backing up the existing config and writing a known-good one."
  fi
  backup_file "$lua"
  backup_file "$conf"
  kblayout="$(sed -n 's/^XKB_DEFAULT_LAYOUT=//p' /etc/tarkin/console.env 2>/dev/null | head -1 || true)"
  kblayout="${kblayout:-us}"
  cat > "$lua" <<EOF
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "1",
})

hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 1,
        col = {
            active_border   = "rgba(4cc2ffff)",
            inactive_border = "rgba(3a3a3aff)",
        },
    },
    decoration = {
        rounding = 8,
        blur   = { enabled = false },
        shadow = { enabled = false },
    },
    animations = {
        enabled = false,
    },
    input = {
        kb_layout    = "$kblayout",
        follow_mouse = 1,
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            tap_and_drag         = true,
            clickfinger_behavior = true,
            disable_while_typing = true,
            scroll_factor        = 0.6,
        },
    },
    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
    },
    cursor = {
        no_hardware_cursors = 1,
    },
})

hl.on("hyprland.start", function()
    hl.exec_cmd("swaybg -c 0b3d91")
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
end)

local mod = "SUPER"

hl.bind(mod .. " + D",         hl.dsp.exec_cmd("fuzzel"))
hl.bind(mod .. " + Return",    hl.dsp.exec_cmd("foot"))
hl.bind(mod .. " + E",         hl.dsp.exec_cmd("pcmanfm"))
hl.bind(mod .. " + Q",         hl.dsp.window.close())
hl.bind(mod .. " + F",         hl.dsp.window.fullscreen())
hl.bind(mod .. " + V",         hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())
hl.bind(mod .. " + left",      hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right",     hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",        hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",      hl.dsp.focus({ direction = "down" }))
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%- --min-value=1"), { locked = true, repeating = true })
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true })
hl.bind("F13", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("F14", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
EOF
  cat > "$conf" <<EOF
monitor = , preferred, auto, 1

\$mod = SUPER

input {
    kb_layout = $kblayout
    follow_mouse = 1
    touchpad {
        natural_scroll = true
        tap-to-click = true
        tap-and-drag = true
        clickfinger_behavior = true
        disable_while_typing = true
        scroll_factor = 0.6
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 1
    col.active_border = rgba(4cc2ffff)
    col.inactive_border = rgba(3a3a3aff)
}

decoration {
    rounding = 8
    blur {
        enabled = false
    }
}

animations {
    enabled = false
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
}

cursor {
    no_hardware_cursors = true
}

exec-once = swaybg -c 0b3d91
exec-once = waybar
exec-once = mako

bind = \$mod, D, exec, fuzzel
bind = \$mod, Return, exec, foot
bind = \$mod, E, exec, pcmanfm
bind = \$mod, Q, killactive
bind = \$mod SHIFT, E, exit
bind = \$mod, F, fullscreen
bind = \$mod, V, togglefloating
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
bindm = \$mod, mouse:272, movewindow
bindm = \$mod, mouse:273, resizewindow
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%- --min-value=1
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , F13, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindel = , F14, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
EOF
  local verify_out
  if ! verify_out="$(Hyprland --verify-config 2>&1)"; then
    printf '%s\n' "$verify_out" | tail -n 20 >&2
    die "The generated config does not verify; Hyprland reported the errors above. Check $lua"
  fi
  ok "Wrote $lua and $conf; Hyprland verifies them."
}

# The USB installer writes TARKIN_SESSION=terminal; without desktop the console
# never tries Hyprland and only shows the terminal.
set_console_session_desktop() {
  if (( DRY_RUN )); then
    echo "   [dry-run] set TARKIN_SESSION=desktop in $CONSOLE_ENV"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$CONSOLE_ENV" ]]; then
    cp "$CONSOLE_ENV" "$tmp"
    sed -i 's/^TARKIN_SESSION=.*/TARKIN_SESSION=desktop/' "$tmp"
  fi
  if ! grep -q '^TARKIN_SESSION=' "$tmp"; then
    printf 'TARKIN_SESSION=desktop\n' >> "$tmp"
  fi
  sys install -D -m 644 "$tmp" "$CONSOLE_ENV"
  rm -f "$tmp"
  ok "TARKIN_SESSION=desktop in $CONSOLE_ENV (the console starts Hyprland, not just the terminal)"
}

has_console_unit() {
  [[ -e /usr/lib/systemd/system/tarkin-console.service || -e /etc/systemd/system/tarkin-console.service ]]
}

# Default display setup (v1.39): no display manager; tarkin-console starts
# hyprland-mali on its own at boot (then Hyprland, software, terminal).
enable_console_display() {
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  if ! has_console_unit; then
    warn "tarkin-console.service is not installed on this system; falling back to GDM (the greeter may go black on the CM1406)."
    enable_gdm
    DISPLAY_MODE=gdm
    return 0
  fi
  if systemctl is-enabled gdm.service >/dev/null 2>&1; then
    sys systemctl disable gdm.service
    ok "gdm.service disabled (GNOME stays installed; use --with-gdm to get the login screen back)."
  fi
  local dm
  dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  if [[ -n "$dm" && "$(basename "$dm")" == "gdm.service" ]]; then
    sys rm -f /etc/systemd/system/display-manager.service
  fi
  set_console_session_desktop
  sys systemctl enable tarkin-console.service
  sys systemctl set-default multi-user.target
  ok "tarkin-console.service enabled: Hyprland (Mali GPU) starts by itself at boot."
  DISPLAY_MODE=console
}

enable_gdm() {
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  local dm
  if systemctl is-enabled gdm.service >/dev/null 2>&1; then
    ok "gdm.service is already enabled."
  else
    dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
    if [[ -n "$dm" && "$(basename "$dm")" != "gdm.service" && -e "$dm" ]]; then
      warn "Another display manager is enabled ($(basename "$dm")); switching the default to GDM (GNOME stays installed)."
      sys systemctl --force enable gdm.service
    else
      sys systemctl enable gdm.service
    fi
    ok "gdm.service enabled."
  fi
  if has_console_unit; then
    if systemctl is-enabled tarkin-console.service >/dev/null 2>&1; then
      sys systemctl disable tarkin-console.service
      ok "tarkin-console.service disabled: GDM owns the display at boot. To go back to the console:"
      echo "      bash install-hyprland.sh --no-packages   (or: sudo systemctl disable gdm && sudo systemctl enable tarkin-console && sudo systemctl set-default multi-user.target)"
    fi
  fi
  sys systemctl set-default graphical.target
}

# Sound (v1.39.2, v1.50): PipeWire runs in the user session; tarkin-audio.service
# (user unit) selects the pro-audio profile, turns the speaker route on, sets a
# first volume and follows the headset jack (speakers <-> headphones).
enable_audio() {
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  if ! command -v pipewire >/dev/null 2>&1 || ! command -v wireplumber >/dev/null 2>&1; then
    warn "PipeWire or WirePlumber is not installed: no sound. Install them with: sudo pacman -S --needed pipewire wireplumber pipewire-pulse libpulse alsa-utils alsa-ucm-conf python"
    return 0
  fi
  if (( DRY_RUN )); then
    echo "   [dry-run] systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service"
  elif ! systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1; then
    warn "Could not enable PipeWire in your session now; it starts at the next boot. If there is no sound then: systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service"
  fi
  if [[ -f /etc/systemd/user/tarkin-audio.service || -f /usr/lib/systemd/user/tarkin-audio.service ]]; then
    if [[ -e /etc/systemd/user/default.target.wants/tarkin-audio.service ]] || sys systemctl --global enable tarkin-audio.service >/dev/null 2>&1; then
      if (( ! DRY_RUN )); then
        systemctl --user --no-block restart tarkin-audio.service >/dev/null 2>&1 || true
      fi
      ok "Sound: PipeWire enabled and tarkin-audio.service set up (speakers, headphone jack switching). Check it with: tarkin-audio-test"
    else
      warn "Could not enable tarkin-audio.service; run: sudo systemctl --global enable tarkin-audio.service"
    fi
  else
    warn "tarkin-audio.service is missing (old stick?): PipeWire runs, but the speakers may stay off. Copy from this release: rootfs/etc/systemd/user/tarkin-audio.service, rootfs/etc/tarkin/audio.conf, rootfs/usr/local/libexec/tarkin/audio-profile and audio-jack, rootfs/usr/local/bin/tarkin-audio-test (CHANGELOG.md, \"Updating a stick made before v1.50\")."
  fi
}

# v1.50: a successful run (first-boot service or by hand) settles the first-boot setup, so that the
# terminal stops announcing it and the service does not run it a second time.
clear_firstboot_markers() {
  local d=/var/lib/tarkin
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  if [[ -e "$d/firstboot.pending" || -e "$d/firstboot.failed" ]]; then
    sys rm -f "$d/firstboot.pending" "$d/firstboot.failed" "$d/firstboot.attempts"
    sys touch "$d/firstboot.done"
    sys systemctl disable tarkin-firstboot.service >/dev/null 2>&1 || true
    ok "First-boot setup marked as done."
  fi
}

test_wrapper() {
  local out
  echo "== Sanity check: the launcher must reach Hyprland with the Mali stack..."
  if ! out="$("$WRAPPER" -- --version 2>&1)"; then
    echo "$out" >&2
    die "$WRAPPER -- --version failed; the launcher cannot reach Hyprland."
  fi
  echo "$out" | grep -m1 -E '^Hyprland' || echo "$out" | head -3
}

remove_files() {
  if [[ -n "$PREFIX" ]]; then
    warn "TARKIN_PREFIX is set; nothing is removed in staging mode."
    return 0
  fi
  echo "== Removing the Hyprland (Mali GPU) session..."
  sys rm -f "$SESSION" "$WRAPPER"
  if (( PURGE_GPU )); then
    sys rm -rf "$GPU_ROOT"
    ok "Removed $GPU_ROOT"
  fi
  ok "Removed $SESSION and $WRAPPER. GNOME and GDM are untouched."
  echo "    The on-screen console keeps working (it falls back to Hyprland, software, then the terminal)."
}

main() {
  check_environment

  if (( REMOVE )); then
    remove_files
    exit 0
  fi

  if (( CONFIG_ONLY )); then
    write_hyprland_config
    exit 0
  fi

  if (( DRY_RUN )); then
    info "Dry run: checking what would be done."
    if will_install_packages; then
      info "Would run: pacman -Syu, then install hyprland xdg-desktop-portal-hyprland gcc libglvnd mesa libc++ libc++abi libdrm python-pip waybar fuzzel swaybg mako foot brightnessctl papirus-icon-theme adw-gtk-theme inter-font noto-fonts noto-fonts-emoji pcmanfm, the sound stack (pipewire wireplumber pipewire-pulse libpulse alsa-utils alsa-ucm-conf python) and the GNOME desktop packages (gnome-shell, gdm, nautilus, ...; only the missing and installable ones)."
    fi
    if (( ! GPU_ONLY )); then
      if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua" ]]; then
        info "Config: $(if Hyprland --verify-config >/dev/null 2>&1; then echo "the existing ~/.config/hypr/hyprland.lua verifies and would be KEPT"; else echo "the existing ~/.config/hypr/hyprland.lua has errors and would be REPLACED (backup kept)"; fi)"
      else
        info "Config: ~/.config/hypr/hyprland.lua is missing and would be written (with hyprland.conf)."
      fi
    fi
    local src=""
    if src="$(pick_mali_source)"; then
      if lib_has_relr_abi "$src"; then
        info "GPU: would install libmali from $src (already patched for Arch's glibc)."
      else
        info "GPU: would install libmali from $src and patch it with LIEF (GLIBC_ABI_DT_RELR)."
      fi
    else
      info "GPU: no libmali found yet; at install time the ChromeOS partitions would be searched read-only."
    fi
    info "Would write: $WRAPPER, $SESSION and (if a tarkin-console exists) the GPU-aware console."
    if [[ -z "$PREFIX" ]] && (( ! GPU_ONLY )); then
      if (( WITH_GDM )) || ! has_console_unit; then
        info "Would enable gdm.service, disable tarkin-console.service and set graphical.target."
      else
        info "Would disable gdm.service, enable tarkin-console.service (Hyprland starts by itself) and set multi-user.target."
      fi
    fi
    if [[ -z "$PREFIX" ]] && (( ! GPU_ONLY )); then
      info "Would enable PipeWire in your session and tarkin-audio.service (speakers, headphone jack switching), and mark the first-boot setup as done."
    fi
    info "Dry run finished; nothing was changed."
    exit 0
  fi

  if will_install_packages; then
    install_packages
    check_build_tools
  fi

  install_gpu_stack

  if [[ -e "$PREFIX/usr/local/bin/tarkin-session" || -e "$CONSOLE" ]]; then
    write_console_files
    fix_console_env
  fi

  if (( ! GPU_ONLY )); then
    write_hyprland_config
  fi

  DISPLAY_MODE=unchanged
  if (( ! GPU_ONLY )); then
    if (( WITH_GDM )); then
      enable_gdm
      DISPLAY_MODE=gdm
    else
      enable_console_display
    fi
    enable_audio
  fi

  test_wrapper

  if (( ! GPU_ONLY )); then
    clear_firstboot_markers
  fi

  echo
  echo "=================================================="
  echo "[+] Hyprland (Mali GPU) is installed (GNOME stays installed)."
  echo "    Session   : Hyprland (Mali GPU)"
  echo "    Launcher  : $WRAPPER"
  echo "    GPU stack : $GPU_ROOT (libmali + EGL shim + probes)"
  if [[ -z "$PREFIX" ]] && (( GPU_ONLY )); then
    echo "    Display   : unchanged (--gpu-only: GDM and tarkin-console were not touched)"
    echo "    The GPU-aware tarkin-console tries $WRAPPER first; with GDM, pick \"Hyprland (Mali GPU)\" with the gear."
  elif [[ -z "$PREFIX" && "$DISPLAY_MODE" == "console" ]]; then
    echo "    Display   : tarkin-console (no login screen; GDM is disabled)"
    echo
    echo "    Next:"
    echo "      1. Reboot: Hyprland (Mali GPU) starts by itself."
    echo "      2. Check the GPU afterwards with: tarkin-gpu-check (or sudo tarkin-diag)"
    echo "      3. Check the sound with: tarkin-audio-test"
    echo "      4. Terminal only: sudo tarkin-session terminal (back: sudo tarkin-session desktop)"
  elif [[ -z "$PREFIX" ]]; then
    echo "    Display   : GDM (GNOME is untouched; tarkin-console is disabled)"
    echo
    echo "    Next:"
    echo "      1. Reboot (or log out). In GDM, click the gear and pick \"Hyprland (Mali GPU)\"."
    echo "      2. GNOME is still there: pick \"GNOME\" any time."
    echo "      3. Check the GPU afterwards with: tarkin-gpu-check (or sudo tarkin-diag)"
  else
    echo "    (staging prefix: $PREFIX - systemd and packages were not touched)"
  fi
  echo "=================================================="
}

main "$@"
