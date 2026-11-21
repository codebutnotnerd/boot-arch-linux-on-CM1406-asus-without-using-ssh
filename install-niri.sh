#!/usr/bin/env bash
set -euo pipefail

PREFIX="${TARKIN_PREFIX:-}"
GPU_ROOT="$PREFIX/usr/local/lib/tarkin-gpu"
MALI_LIB="$GPU_ROOT/mali/lib"
SHIM_SRC="$GPU_ROOT/src/egl-mali-shim.c"
NIRI_ROOT="$GPU_ROOT/niri"
NIRI_LIB="$NIRI_ROOT/lib"
NIRI_BIN="$NIRI_ROOT/bin"
NIRI_SRC="$NIRI_ROOT/src"
HYPR_WRAPPER="$PREFIX/usr/local/bin/hyprland-mali"
CONSOLE="$PREFIX/usr/local/libexec/tarkin/console"
CONSOLE_ENV="$PREFIX/etc/tarkin/console.env"
UNIT="$PREFIX/etc/systemd/system/tarkin-console.service"
DROPIN="$UNIT.d/50-tarkin-wm.conf"
START="$PREFIX/usr/local/libexec/tarkin/niri-start"
WM_BIN="$PREFIX/usr/local/bin/tarkin-wm"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
NIRI_DIR="$CFG/niri"
NIRI_CFG="$NIRI_DIR/config.kdl"
BACKUP="$NIRI_CFG.before-tarkin-niri"
STATE="$NIRI_DIR/.installed-by-tarkin-niri"
SHOT_KEY='Mod+Shift+S { screenshot; }'
SHOT_LINE="    $SHOT_KEY"
SHOT_BACKUP="$NIRI_CFG.before-tarkin-screenshot"
SHOT_STATE="$NIRI_DIR/.screenshot-key-by-tarkin-niri"
PACKAGES=(niri xwayland-satellite)

MODE=install
DRY_RUN=0
RESET_CONFIG=0
WORK=""

ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[34m[..]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash install-niri.sh [--dry-run] [--reset-config]   (boot-arch-linux-on-CM1406 v1.60)
       bash install-niri.sh --remove [--dry-run]
       bash install-niri.sh --screenshot-key | --no-screenshot-key [--dry-run]

Installs the niri compositor next to Hyprland, on the Mali GPU through the
same libmali driver as Hyprland. Hyprland stays the default.

After the install:
  sudo tarkin-wm niri       start niri at the next boot (Hyprland if niri fails)
  sudo tarkin-wm hyprland   go back to Hyprland at the next boot
  tarkin-wm status          show what starts at the next boot

  --dry-run       show what would be done, change nothing
  --reset-config  replace ~/.config/niri/config.kdl (a backup is kept)
  --screenshot-key  only add Super+Shift+S (screenshot of a region) to your
                  own config.kdl
  --no-screenshot-key  only take that line out again (--remove does it too)
  --remove        undo everything this script did (packages stay installed)
  -h, --help      show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --remove)       MODE=remove ;;
    --screenshot-key) MODE=keys ;;
    --no-screenshot-key) MODE=nokeys ;;
    --dry-run)      DRY_RUN=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $arg" ;;
  esac
done

if [[ $EUID -eq 0 && -z "$PREFIX" ]]; then
  die "Run this as your normal user, without sudo: bash install-niri.sh (it asks for the password itself)."
fi

if [[ -n "$PREFIX" ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

sys() {
  if (( DRY_RUN )); then
    echo "   [dry-run] ${SUDO[*]:+${SUDO[*]} }$*"
    return 0
  fi
  "${SUDO[@]}" "$@"
}

user_do() {
  if (( DRY_RUN )); then
    echo "   [dry-run] $*"
    return 0
  fi
  "$@"
}

file_sha() {
  sha256sum -- "$1" | cut -d' ' -f1
}

config_is_ours() {
  [[ -f "$NIRI_CFG" && -f "$STATE" ]] || return 1
  [[ "$(file_sha "$NIRI_CFG")" == "$(cat -- "$STATE")" ]]
}

check_system() {
  local arch
  arch="$(uname -m)"
  [[ "$arch" == aarch64 || -n "$PREFIX" ]] || die "This is for the CM1406 (aarch64); this machine is $arch."
  [[ -e "$MALI_LIB/libmali.so.0" ]] ||
    die "The Mali GPU driver is missing ($MALI_LIB/libmali.so.0). Run bash ~/install-hyprland.sh first."
  [[ -f "$SHIM_SRC" ]] ||
    die "The EGL shim source is missing ($SHIM_SRC). Run bash ~/install-hyprland.sh first."
  [[ -x "$HYPR_WRAPPER" ]] ||
    die "$HYPR_WRAPPER is missing. Run bash ~/install-hyprland.sh first."
  grep -q 'TARKIN_START_HYPRLAND' "$HYPR_WRAPPER" ||
    die "$HYPR_WRAPPER is too old (no TARKIN_START_HYPRLAND). Run bash ~/install-hyprland.sh from this release first."
  [[ -x "$CONSOLE" && -f "$UNIT" ]] ||
    die "tarkin-console is missing ($CONSOLE, $UNIT). Run bash ~/install-hyprland.sh first."
  ok "Hyprland on the Mali GPU is installed"
}

install_packages() {
  local p missing=()
  for p in "${PACKAGES[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  command -v gcc >/dev/null 2>&1 || missing+=(gcc)
  if (( ${#missing[@]} == 0 )); then
    ok "Packages already installed: ${PACKAGES[*]}"
    return 0
  fi
  info "Installing ${missing[*]} (sudo asks for your password)"
  if ! sys pacman -S --needed --noconfirm "${missing[@]}"; then
    die "pacman failed. Update first with: sudo tarkin-update, then run bash install-niri.sh again."
  fi
  (( DRY_RUN )) && return 0
  command -v niri >/dev/null 2>&1 || die "niri is still missing after pacman."
  ok "Installed ${missing[*]}"
}

patch_niri_shim() {
  local src="$1" tmp="$1.patched"
  if ! awk '
    BEGIN {
      header = "__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name) {"
      table = "  static const struct { const char *n; void *f; } ours[] = {"
      query = "    {\"eglQueryString\", (void *)eglQueryString},"
      self = "    {\"eglGetProcAddress\", (void *)eglGetProcAddress},"
      expected = header "\n  REAL(eglGetProcAddress);\n" table "\n" \
        "    {\"eglGetPlatformDisplay\", (void *)eglGetPlatformDisplay},\n" \
        "    {\"eglGetPlatformDisplayEXT\", (void *)eglGetPlatformDisplayEXT},\n" \
        "    {\"eglQueryDevicesEXT\", (void *)eglQueryDevicesEXT},\n" \
        "    {\"eglQueryDeviceStringEXT\", (void *)eglQueryDeviceStringEXT},\n" \
        "    {\"eglQueryDeviceAttribEXT\", (void *)eglQueryDeviceAttribEXT},\n" \
        "    {\"eglQueryDisplayAttribEXT\", (void *)eglQueryDisplayAttribEXT},\n" \
        query "\n  };\n"
    }
    {
      lines[NR] = $0
      if (index($0, "eglGetProcAddress(const char *name)")) definitions++
      if ($0 == table) tables++
      if (index($0, "\"eglQueryString\"")) queries++
      if (index($0, "\"eglGetProcAddress\"")) selves++
      if ($0 == header) { headers++; capture = 1 }
      if (capture) {
        if ($0 == table) in_table = 1
        if ($0 != self || !in_table) block = block $0 "\n"
        else patched++
        if ($0 == query) query_line = NR
        if ($0 == "  };") { capture = 0; in_table = 0 }
      }
    }
    END {
      if (definitions != 1 || headers != 1 || tables != 1 || queries != 1 ||
          selves != patched || patched > 1 || capture || block != expected) exit 1
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (!patched && i == query_line) print self
      }
    }
  ' "$src" > "$tmp"; then
    rm -f -- "$tmp"
    die "Unsupported or ambiguous EGL shim source; nothing was installed."
  fi
  mv -f -- "$tmp" "$src"
}

write_probe() {
  cat > "$1" <<'PROBE_EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef void *(*get_proc_t)(const char *);
typedef const char *(*query_string_t)(void *, int32_t);
typedef void *(*platform_display_t)(uint32_t, void *, const int32_t *);
typedef uint32_t (*initialize_t)(void *, int32_t *, int32_t *);
typedef uint32_t (*bind_api_t)(uint32_t);
typedef uint32_t (*choose_config_t)(void *, const int32_t *, void **, int32_t, int32_t *);
typedef void *(*create_context_t)(void *, void *, void *, const int32_t *);
typedef uint32_t (*make_current_t)(void *, void *, void *, void *);
typedef uint32_t (*display_attrib_t)(void *, int32_t, intptr_t *);
typedef const char *(*device_string_t)(void *, int32_t);
typedef const unsigned char *(*gl_string_t)(uint32_t);

static int has_word(const char *list, const char *word) {
  size_t n = strlen(word);
  const char *p = list;
  while (p && (p = strstr(p, word))) {
    if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0')) return 1;
    p += n;
  }
  return 0;
}

static int fail(const char *why) {
  printf("niri-egl-probe: FAIL %s\n", why);
  return 1;
}

int main(void) {
  void *mali = dlopen("libmali.so.0", RTLD_NOW | RTLD_GLOBAL);
  if (!mali) return fail(dlerror());
  void *lib = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return fail(dlerror());
  query_string_t query = (query_string_t)dlsym(lib, "eglQueryString");
  get_proc_t get_proc = (get_proc_t)dlsym(lib, "eglGetProcAddress");
  if (!query || !get_proc) return fail("libEGL.so.1 lacks eglQueryString or eglGetProcAddress");
  Dl_info where;
  if (dladdr((void *)query, &where) && where.dli_fname) printf("niri-egl-probe: libEGL.so.1 = %s\n", where.dli_fname);
  get_proc_t reloaded = (get_proc_t)get_proc("eglGetProcAddress");
  if (!reloaded || reloaded != get_proc) return fail("eglGetProcAddress self-reload bypassed the shim");
  get_proc = reloaded;
  query_string_t reloaded_query = (query_string_t)get_proc("eglQueryString");
  if (!reloaded_query || reloaded_query != query) return fail("eglQueryString reload bypassed the shim");
  query = reloaded_query;
  const char *client = query(NULL, 0x3055);
  if (!client) return fail("no EGL client extensions");
  if (!has_word(client, "EGL_KHR_platform_gbm") && !has_word(client, "EGL_MESA_platform_gbm")) return fail("no GBM platform (shim not active)");
  if (!has_word(client, "EGL_EXT_device_query")) return fail("no EGL_EXT_device_query");
  platform_display_t platform_display = (platform_display_t)get_proc("eglGetPlatformDisplayEXT");
  if (!platform_display) return fail("no eglGetPlatformDisplayEXT");
  static int gbm_stand_in;
  const int32_t none[] = {0x3038};
  void *dpy = platform_display(0x31D7, &gbm_stand_in, none);
  if (!dpy) return fail("GBM platform display refused");
  initialize_t initialize = (initialize_t)dlsym(lib, "eglInitialize");
  int32_t major = 0, minor = 0;
  if (!initialize || !initialize(dpy, &major, &minor)) return fail("eglInitialize failed");
  printf("niri-egl-probe: EGL %d.%d\n", major, minor);
  const char *dext = query(dpy, 0x3055);
  if (!dext || !has_word(dext, "EGL_EXT_image_dma_buf_import")) return fail("no EGL_EXT_image_dma_buf_import");
  if (!has_word(dext, "EGL_KHR_surfaceless_context")) return fail("no EGL_KHR_surfaceless_context");
  if (!has_word(dext, "EGL_EXT_image_dma_buf_import_modifiers")) printf("niri-egl-probe: note: no dmabuf modifiers extension\n");
  display_attrib_t display_attrib = (display_attrib_t)get_proc("eglQueryDisplayAttribEXT");
  device_string_t device_string = (device_string_t)get_proc("eglQueryDeviceStringEXT");
  intptr_t device = 0;
  if (!display_attrib || !device_string || !display_attrib(dpy, 0x322C, &device) || !device) return fail("no EGL device for the display");
  const char *devext = device_string((void *)device, 0x3055);
  if (!devext) return fail("no EGL device extensions");
  if (has_word(devext, "EGL_MESA_device_software")) return fail("software EGL device (niri refuses it)");
  const char *node = device_string((void *)device, 0x3377);
  printf("niri-egl-probe: render node %s\n", node ? node : "(none)");
  bind_api_t bind_api = (bind_api_t)dlsym(lib, "eglBindAPI");
  choose_config_t choose_config = (choose_config_t)dlsym(lib, "eglChooseConfig");
  create_context_t create_context = (create_context_t)dlsym(lib, "eglCreateContext");
  make_current_t make_current = (make_current_t)dlsym(lib, "eglMakeCurrent");
  if (!bind_api || !choose_config || !create_context || !make_current) return fail("core EGL functions missing");
  if (!bind_api(0x30A0)) return fail("eglBindAPI(GLES) failed");
  const int32_t config_attrs[] = {0x3040, 0x40, 0x3038};
  void *config = NULL;
  int32_t count = 0;
  if (!choose_config(dpy, config_attrs, &config, 1, &count) || count < 1) {
    const int32_t es2_attrs[] = {0x3040, 0x4, 0x3038};
    if (!choose_config(dpy, es2_attrs, &config, 1, &count) || count < 1) return fail("no GLES config");
  }
  const int32_t ctx_attrs[] = {0x3098, 3, 0x3038};
  void *ctx = create_context(dpy, config, NULL, ctx_attrs);
  if (!ctx) {
    const int32_t ctx2_attrs[] = {0x3098, 2, 0x3038};
    ctx = create_context(dpy, config, NULL, ctx2_attrs);
  }
  if (!ctx) return fail("eglCreateContext failed");
  if (!make_current(dpy, NULL, NULL, ctx)) return fail("surfaceless eglMakeCurrent failed");
  gl_string_t gl_string = (gl_string_t)get_proc("glGetString");
  if (!gl_string) gl_string = (gl_string_t)dlsym(lib, "glGetString");
  if (!gl_string) return fail("no glGetString");
  const char *renderer = (const char *)gl_string(0x1F01);
  const char *version = (const char *)gl_string(0x1F02);
  const char *glext = (const char *)gl_string(0x1F03);
  printf("niri-egl-probe: renderer %s\n", renderer ? renderer : "(none)");
  printf("niri-egl-probe: version %s\n", version ? version : "(none)");
  if (!renderer || strstr(renderer, "llvmpipe") || strstr(renderer, "softpipe")) return fail("not the GPU");
  if (!glext || !has_word(glext, "GL_EXT_texture_format_BGRA8888")) return fail("no GL_EXT_texture_format_BGRA8888");
  if (!has_word(glext, "GL_OES_EGL_image")) return fail("no GL_OES_EGL_image");
  printf("niri-egl-probe: OK\n");
  return 0;
}
PROBE_EOF
}

write_start() {
  cat > "$1" <<'START_EOF'
#!/bin/bash
set -u
EGL_DIR="@EGL_DIR@"
WAIT="${TARKIN_NIRI_WAIT:-45}"
runtime="${XDG_RUNTIME_DIR:-/tmp}"
log="$runtime/tarkin-niri.log"
failed="$runtime/tarkin-niri.failed"
mali="${LD_LIBRARY_PATH:-}"
shim="${LD_PRELOAD:-}"

say() { echo "tarkin-niri: $*" >&2; }

start_hyprland() {
  unset NIRI_SOCKET
  export LD_LIBRARY_PATH="$mali" QUIGON_EGL_SHIM_EXE=Hyprland XDG_SESSION_DESKTOP=Hyprland XDG_CURRENT_DESKTOP=Hyprland
  if [[ -n "$shim" ]]; then export LD_PRELOAD="$shim"; fi
  local hypr
  hypr="$(command -v start-hyprland || command -v Hyprland || true)"
  if [[ -z "$hypr" ]]; then
    say "Hyprland is missing too."
    exit 1
  fi
  exec "$hypr" "$@"
}

give_up() {
  say "$1 Starting Hyprland for the rest of this boot. Log: $log"
  shift
  : > "$failed"
  start_hyprland "$@"
}

clean() {
  env -u LD_PRELOAD -u LD_LIBRARY_PATH "$@"
}

niri_ready() {
  local sock
  for sock in "$runtime"/niri.*."$1".sock; do
    [[ -S "$sock" ]] || continue
    NIRI_SOCKET="$sock" clean niri msg --json outputs 2>/dev/null | grep -q '"current_mode":[[:space:]]*[0-9]' && return 0
  done
  return 1
}

if [[ -e "$failed" ]]; then
  say "niri already stopped once in this boot."
  start_hyprland "$@"
fi
if ! command -v niri >/dev/null 2>&1; then
  give_up "niri is not installed." "$@"
fi
if [[ ! -r "$EGL_DIR/libEGL.so.1" ]]; then
  give_up "$EGL_DIR/libEGL.so.1 is missing (rerun bash ~/install-niri.sh)." "$@"
fi
if [[ -f "$log" ]]; then mv -f -- "$log" "$log.old"; fi
say "starting niri on the Mali GPU."
(
  unset LD_PRELOAD HYPRLAND_EGL_NO_MODIFIERS AQ_NO_MODIFIERS AQ_DRM_DEVICES NIRI_SOCKET
  export LD_LIBRARY_PATH="$EGL_DIR${mali:+:$mali}" QUIGON_EGL_SHIM_EXE=niri
  export XDG_SESSION_DESKTOP=niri XDG_CURRENT_DESKTOP=niri XDG_SESSION_TYPE=wayland
  export NIRI_DISABLE_SYSTEM_MANAGER_NOTIFY=1
  exec niri --session
) > >(clean tee -a "$log" >&2) 2>&1 &
pid=$!
began=$SECONDS
ready=0
while (( SECONDS - began < WAIT )); do
  kill -0 "$pid" 2>/dev/null || break
  if niri_ready "$pid"; then
    ready=1
    break
  fi
  sleep 1
done
if (( ! ready )); then
  if kill -0 "$pid" 2>/dev/null; then
    say "niri shows no screen after ${WAIT}s; stopping it."
    kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    give_up "niri did not show a screen." "$@"
  fi
  wait "$pid"
  rc=$?
  give_up "niri stopped after $((SECONDS - began))s (code $rc)." "$@"
fi
say "niri is on screen."
wait "$pid"
rc=$?
give_up "niri closed after $((SECONDS - began))s (code $rc)." "$@"
START_EOF
  sed -i "s|@EGL_DIR@|$NIRI_LIB|g" "$1"
}

write_wm() {
  cat > "$1" <<'WM_EOF'
#!/bin/bash
set -euo pipefail
DROPIN="@DROPIN@"
START="@START@"
EGL_DIR="@EGL_DIR@"
HYPR_WRAPPER="@HYPR_WRAPPER@"
UNIT="@UNIT@"
CONSOLE_ENV="@CONSOLE_ENV@"
NEED_ROOT="@NEED_ROOT@"

usage() {
  cat <<'EOF'
Usage: sudo tarkin-wm niri       start niri at the next boot (Hyprland if niri fails)
       sudo tarkin-wm hyprland   start Hyprland at the next boot (default)
       tarkin-wm status          show what starts at the next boot
EOF
}

next_boot() {
  if [[ -f "$DROPIN" ]]; then echo niri; else echo hyprland; fi
}

reload() {
  if [[ "$NEED_ROOT" == 1 ]]; then
    systemctl daemon-reload
  else
    systemctl daemon-reload 2>/dev/null || true
  fi
}

mode="${1:-status}"
case "$mode" in
  niri|hyprland|status) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 1; }

if [[ "$mode" == status ]]; then
  echo "Next boot: $(next_boot)"
  shopt -s nullglob
  for dir in /run/user/*; do
    if [[ -e "$dir/tarkin-niri.failed" ]]; then
      echo "This boot: niri stopped, Hyprland took over. Log: $dir/tarkin-niri.log"
    fi
  done
  exit 0
fi

if [[ "$NEED_ROOT" == 1 && $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

if [[ "$mode" == hyprland ]]; then
  if [[ -f "$DROPIN" ]]; then
    rm -f -- "$DROPIN"
    rmdir -- "$(dirname "$DROPIN")" 2>/dev/null || true
    reload
  fi
  echo "Hyprland starts at the next boot. Restart with: sudo reboot"
  exit 0
fi

command -v niri >/dev/null 2>&1 || { echo "tarkin-wm: niri is not installed. Run bash ~/install-niri.sh" >&2; exit 1; }
[[ -x "$START" && -r "$EGL_DIR/libEGL.so.1" ]] || { echo "tarkin-wm: niri files are missing. Run bash ~/install-niri.sh" >&2; exit 1; }
grep -q 'TARKIN_START_HYPRLAND' "$HYPR_WRAPPER" 2>/dev/null || { echo "tarkin-wm: $HYPR_WRAPPER is missing or too old. Run bash ~/install-hyprland.sh" >&2; exit 1; }
[[ -f "$UNIT" ]] || { echo "tarkin-wm: $UNIT is missing. Run bash ~/install-hyprland.sh" >&2; exit 1; }
mkdir -p -- "$(dirname "$DROPIN")"
tmp="$(mktemp "$(dirname "$DROPIN")/.tarkin-wm.XXXXXX")"
printf '[Service]\nEnvironment=TARKIN_START_HYPRLAND=%s\n' "$START" > "$tmp"
chmod 644 "$tmp"
mv -f -- "$tmp" "$DROPIN"
reload
session="$(sed -n 's/^TARKIN_SESSION=//p' "$CONSOLE_ENV" 2>/dev/null | tail -1 | tr -d '"')"
if [[ "$session" != desktop ]]; then
  echo "Note: the boot is set to the terminal, not the desktop. To get niri: sudo tarkin-display hyprland, then sudo tarkin-wm niri." >&2
fi
echo "niri starts at the next boot (Hyprland if niri fails or is closed). Restart with: sudo reboot"
echo "Back to Hyprland: sudo tarkin-wm hyprland"
WM_EOF
  local need_root=1
  [[ -z "$PREFIX" ]] || need_root=0
  sed -i "s|@DROPIN@|$DROPIN|g; s|@START@|$START|g; s|@EGL_DIR@|$NIRI_LIB|g; s|@HYPR_WRAPPER@|$HYPR_WRAPPER|g; s|@UNIT@|$UNIT|g; s|@CONSOLE_ENV@|$CONSOLE_ENV|g; s|@NEED_ROOT@|$need_root|g" "$1"
}

keyboard_layout() {
  local layout
  layout="$(sed -n 's/^XKB_DEFAULT_LAYOUT=//p' "$CONSOLE_ENV" 2>/dev/null | tail -1 | tr -d '"' || true)"
  [[ "$layout" =~ ^[a-z][a-z0-9_,()-]*$ ]] || layout=us
  echo "$layout"
}

write_config() {
  local layout="$1"
  cat > "$2" <<'KDL_EOF'
input {
    keyboard {
        xkb {
            layout "@LAYOUT@"
        }
    }
    touchpad {
        tap
        natural-scroll
        dwt
        click-method "clickfinger"
        scroll-factor 0.6
    }
    focus-follows-mouse
}

output "eDP-1" {
    scale 1
}

layout {
    gaps 8
    center-focused-column "never"
    default-column-width { proportion 0.5; }
    focus-ring {
        width 2
        active-color "#4cc2ff"
        inactive-color "#3a3a3a"
    }
    border {
        off
    }
}

animations {
    off
}

prefer-no-csd

hotkey-overlay {
    skip-at-startup
}

cursor {
    hide-when-typing
}

debug {
    disable-cursor-plane
}

screenshot-path "~/Pictures/Screenshots/Screenshot-%Y-%m-%d-%H-%M-%S.png"

spawn-at-startup "sh" "-c" r#"if [ -f "$HOME/Pictures/fond.jpg" ]; then exec swaybg -m fill -i "$HOME/Pictures/fond.jpg"; else exec swaybg -c 0b3d91; fi"#
spawn-at-startup "waybar"
spawn-at-startup "mako"
spawn-at-startup "sh" "-c" r#"if [ -x /usr/local/bin/tarkin-comfort-start ]; then exec /usr/local/bin/tarkin-comfort-start; fi"#

binds {
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+Return { spawn "sh" "-c" r#"if command -v kitty >/dev/null 2>&1; then exec kitty; else exec foot; fi"#; }
    Mod+D { spawn "fuzzel"; }
    Mod+E { spawn "pcmanfm"; }
    Mod+Q repeat=false { close-window; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+V { toggle-window-floating; }
    Mod+O repeat=false { toggle-overview; }
    Mod+R { switch-preset-column-width; }
    Mod+Minus { set-column-width "-10%"; }
    Mod+Equal { set-column-width "+10%"; }

    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-up; }
    Mod+Down  { focus-window-down; }
    Mod+Ctrl+Left  { move-column-left; }
    Mod+Ctrl+Right { move-column-right; }
    Mod+Ctrl+Up    { move-window-up; }
    Mod+Ctrl+Down  { move-window-down; }

    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }

    F6 allow-when-locked=true { spawn "brightnessctl" "set" "5%-" "--min-value=1"; }
    F7 allow-when-locked=true { spawn "brightnessctl" "set" "5%+"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "set" "5%-" "--min-value=1"; }
    XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "set" "5%+"; }
    F8 allow-when-locked=true { spawn "/usr/local/bin/tarkin-kbd-backlight"; }
    XF86KbdLightOnOff allow-when-locked=true { spawn "/usr/local/bin/tarkin-kbd-backlight"; }
    F13 allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
    F14 allow-when-locked=true { spawn "wpctl" "set-volume" "-l" "1" "@DEFAULT_AUDIO_SINK@" "5%+"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "-l" "1" "@DEFAULT_AUDIO_SINK@" "5%+"; }
    XF86AudioMute allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
    XF86AudioMicMute allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }

    Print { screenshot; }
    Mod+Shift+S { screenshot; }
    Mod+Shift+P { power-off-monitors; }
    Mod+Shift+E { quit; }
    Ctrl+Alt+Delete { quit skip-confirmation=true; }
}
KDL_EOF
  sed -i "s|@LAYOUT@|$layout|g" "$2"
}

validate_config() {
  local out
  if out="$(niri validate -c "$1" 2>&1)"; then
    return 0
  fi
  printf '%s\n' "$out" | tail -n 15 >&2
  return 1
}

build_gpu_files() {
  if (( DRY_RUN )); then
    echo "   [dry-run] compile $NIRI_LIB/libEGL.so.1 (the Hyprland EGL shim, linked to libmali) and the niri-egl-probe, then run the probe"
    return 0
  fi
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/tarkin-niri.XXXXXX")"
  mkdir -p "$WORK/lib"
  cp -- "$SHIM_SRC" "$WORK/egl-mali-shim.c"
  patch_niri_shim "$WORK/egl-mali-shim.c"
  write_probe "$WORK/niri-egl-probe.c"
  info "Compiling the niri EGL library and the GPU probe"
  gcc -O2 -shared -fPIC -Wl,-soname,libEGL.so.1 -Wl,-Bsymbolic -Wl,--no-as-needed -Wl,-rpath,"$MALI_LIB" \
    -o "$WORK/lib/libEGL.so.1" "$WORK/egl-mali-shim.c" -L"$MALI_LIB" -l:libmali.so.0 -ldl ||
    die "Compiling the niri EGL library failed; nothing was installed."
  gcc -O2 -o "$WORK/niri-egl-probe" "$WORK/niri-egl-probe.c" -ldl ||
    die "Compiling the GPU probe failed; nothing was installed."
  info "Checking that niri's way of loading EGL reaches the Mali GPU"
  local out
  if ! out="$(env -u LD_PRELOAD LD_LIBRARY_PATH="$WORK/lib:$MALI_LIB" GBM_ALWAYS_SOFTWARE=1 timeout 60 "$WORK/niri-egl-probe" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "The GPU probe failed, so niri could not use the GPU. Nothing was installed or changed."
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  ok "The Mali GPU answers through the niri EGL library"
}

install_gpu_files() {
  if (( DRY_RUN )); then
    echo "   [dry-run] install $NIRI_LIB/libEGL.so.1, $NIRI_BIN/niri-egl-probe, $START and $WM_BIN"
    return 0
  fi
  write_start "$WORK/niri-start"
  write_wm "$WORK/tarkin-wm"
  bash -n "$WORK/niri-start" || die "Generated niri-start does not parse."
  bash -n "$WORK/tarkin-wm" || die "Generated tarkin-wm does not parse."
  sys install -d -m 755 "$NIRI_LIB" "$NIRI_BIN" "$NIRI_SRC" "$(dirname "$START")" "$(dirname "$WM_BIN")"
  sys install -m 755 "$WORK/lib/libEGL.so.1" "$NIRI_LIB/libEGL.so.1"
  sys install -m 755 "$WORK/niri-egl-probe" "$NIRI_BIN/niri-egl-probe"
  sys install -m 644 "$WORK/niri-egl-probe.c" "$NIRI_SRC/niri-egl-probe.c"
  sys install -m 755 "$WORK/niri-start" "$START"
  sys install -m 755 "$WORK/tarkin-wm" "$WM_BIN"
  ok "Installed $NIRI_LIB/libEGL.so.1, $START and $WM_BIN"
}

add_screenshot_key() {
  local tmp
  [[ -f "$NIRI_CFG" && ! -L "$NIRI_CFG" ]] || return 0
  if grep -Eiq '^[[:space:]]*(Mod|Super)\+Shift\+S([[:space:]]|\{|$)' "$NIRI_CFG"; then
    ok "Super+Shift+S is already bound in $NIRI_CFG"
    return 0
  fi
  if grep -q 'BEGIN TARKIN NIRI DOCK' "$NIRI_CFG"; then
    warn "The old Tarkin niri dock checks $NIRI_CFG, so Super+Shift+S was not added. Add this line in binds yourself: $SHOT_KEY"
    return 0
  fi
  if [[ "$(grep -c '^binds[[:space:]]*{[[:space:]]*$' "$NIRI_CFG")" != 1 || -n "$(tail -c 1 "$NIRI_CFG")" ]]; then
    warn "Cannot place Super+Shift+S safely in $NIRI_CFG. Add this line in binds yourself: $SHOT_KEY"
    return 0
  fi
  if (( DRY_RUN )); then
    echo "   [dry-run] add \"$SHOT_KEY\" under binds in $NIRI_CFG (copy in $SHOT_BACKUP)"
    return 0
  fi
  tmp="$(mktemp "$NIRI_DIR/.config.kdl.XXXXXX")"
  awk -v line="$SHOT_LINE" '{ print } /^binds[[:space:]]*\{[[:space:]]*$/ { print line }' "$NIRI_CFG" > "$tmp"
  chmod --reference="$NIRI_CFG" "$tmp"
  if command -v niri >/dev/null 2>&1 && ! validate_config "$tmp"; then
    rm -f -- "$tmp"
    warn "niri rejects $NIRI_CFG with Super+Shift+S added; your file was not changed."
    return 0
  fi
  [[ -e "$SHOT_BACKUP" ]] || cp -p -- "$NIRI_CFG" "$SHOT_BACKUP"
  mv -f -- "$tmp" "$NIRI_CFG"
  file_sha "$NIRI_CFG" > "$SHOT_STATE"
  ok "Added Super+Shift+S (screenshot of a region: clipboard + ~/Pictures/Screenshots) to $NIRI_CFG; niri reloads it by itself"
}

remove_screenshot_key() {
  local tmp
  [[ -f "$SHOT_STATE" ]] || return 0
  if [[ -f "$NIRI_CFG" && ! -L "$NIRI_CFG" && "$(grep -cxF "$SHOT_LINE" "$NIRI_CFG")" == 1 ]]; then
    if (( DRY_RUN )); then
      echo "   [dry-run] remove \"$SHOT_KEY\" from $NIRI_CFG"
      return 0
    fi
    tmp="$(mktemp "$NIRI_DIR/.config.kdl.XXXXXX")"
    grep -vxF "$SHOT_LINE" "$NIRI_CFG" > "$tmp" || true
    chmod --reference="$NIRI_CFG" "$tmp"
    mv -f -- "$tmp" "$NIRI_CFG"
    ok "Removed Super+Shift+S from $NIRI_CFG"
  fi
  if (( DRY_RUN )); then
    return 0
  fi
  if [[ -f "$SHOT_BACKUP" ]]; then
    if [[ -f "$NIRI_CFG" ]] && cmp -s -- "$NIRI_CFG" "$SHOT_BACKUP"; then
      rm -f -- "$SHOT_BACKUP"
    else
      warn "$NIRI_CFG changed since Super+Shift+S was added; the copy from before is kept in $SHOT_BACKUP"
    fi
  fi
  rm -f -- "$SHOT_STATE"
}

backup_once() {
  [[ -f "$NIRI_CFG" && ! -e "$BACKUP" ]] || return 0
  user_do cp -p -- "$NIRI_CFG" "$BACKUP"
  ok "Backup of your niri config: $BACKUP"
}

setup_config() {
  local layout tmp
  if [[ -f "$NIRI_CFG" ]] && ! config_is_ours && (( ! RESET_CONFIG )); then
    backup_once
    ok "Keeping your own $NIRI_CFG"
    if (( ! DRY_RUN )) && command -v niri >/dev/null 2>&1 && ! validate_config "$NIRI_CFG"; then
      warn "niri rejects your $NIRI_CFG (errors above). Fix it, or rerun with --reset-config."
      return 0
    fi
    add_screenshot_key
    return 0
  fi
  layout="$(keyboard_layout)"
  if (( DRY_RUN )); then
    echo "   [dry-run] write $NIRI_CFG (keyboard $layout) and check it with niri validate"
    return 0
  fi
  if ! config_is_ours; then
    backup_once
  fi
  mkdir -p -- "$NIRI_DIR"
  tmp="$(mktemp "$NIRI_DIR/.config.kdl.XXXXXX")"
  write_config "$layout" "$tmp"
  if ! validate_config "$tmp"; then
    rm -f -- "$tmp"
    die "niri rejects the generated config (errors above); $NIRI_CFG was not changed."
  fi
  mv -f -- "$tmp" "$NIRI_CFG"
  file_sha "$NIRI_CFG" > "$STATE"
  ok "Wrote $NIRI_CFG (keyboard $layout); niri validate accepts it"
}

remove_all() {
  info "Removing what install-niri.sh added (packages stay installed)"
  remove_screenshot_key
  if [[ -f "$DROPIN" ]]; then
    sys rm -f -- "$DROPIN"
    sys rmdir --ignore-fail-on-non-empty -- "$(dirname "$DROPIN")"
    if [[ -z "$PREFIX" ]]; then
      sys systemctl daemon-reload
    fi
    ok "Hyprland starts at the next boot again"
  fi
  local f
  for f in "$START" "$WM_BIN"; do
    if [[ -e "$f" ]]; then sys rm -f -- "$f"; fi
  done
  if [[ -e "$NIRI_ROOT" ]]; then sys rm -rf -- "$NIRI_ROOT"; fi
  ok "Removed the niri launcher, tarkin-wm and $NIRI_ROOT"
  if config_is_ours; then
    user_do rm -f -- "$NIRI_CFG"
    if [[ -f "$BACKUP" ]]; then
      user_do mv -f -- "$BACKUP" "$NIRI_CFG"
      ok "Restored your previous $NIRI_CFG"
    else
      ok "Removed $NIRI_CFG"
    fi
  elif [[ -f "$NIRI_CFG" ]]; then
    if [[ -f "$BACKUP" ]] && cmp -s -- "$NIRI_CFG" "$BACKUP"; then
      user_do rm -f -- "$BACKUP"
    fi
    ok "Kept $NIRI_CFG (not written by this script, or changed since)"
    if [[ -f "$BACKUP" ]]; then
      warn "Your older config is still in $BACKUP"
    fi
  elif [[ -f "$BACKUP" ]]; then
    user_do mv -f -- "$BACKUP" "$NIRI_CFG"
    ok "Restored your previous $NIRI_CFG"
  fi
  if [[ -f "$STATE" ]]; then user_do rm -f -- "$STATE"; fi
  if (( ! DRY_RUN )) && [[ -d "$NIRI_DIR" ]]; then rmdir -- "$NIRI_DIR" 2>/dev/null || true; fi
  if pgrep -x niri >/dev/null 2>&1; then
    warn "niri is running now; it stays until you restart. Hyprland comes back at the next boot."
  fi
  echo
  echo "To also remove the packages: sudo pacman -Rs ${PACKAGES[*]}"
}

main() {
  if [[ "$MODE" == remove ]]; then
    remove_all
    return 0
  fi
  if [[ "$MODE" == nokeys ]]; then
    if [[ ! -f "$SHOT_STATE" ]]; then
      ok "Super+Shift+S was not added by this script; nothing to do."
      return 0
    fi
    remove_screenshot_key
    return 0
  fi
  if [[ "$MODE" == keys ]]; then
    if [[ ! -f "$NIRI_CFG" ]]; then
      die "No $NIRI_CFG yet. Run bash install-niri.sh first."
    fi
    if config_is_ours; then
      ok "$NIRI_CFG was written by this script; rerun bash install-niri.sh to get the new keys."
      return 0
    fi
    add_screenshot_key
    return 0
  fi
  check_system
  install_packages
  build_gpu_files
  install_gpu_files
  setup_config
  echo
  ok "niri is installed next to Hyprland. Hyprland is still the one that starts."
  echo "    Try niri:          sudo tarkin-wm niri   then   sudo reboot"
  echo "    Back to Hyprland:  sudo tarkin-wm hyprland   then   sudo reboot"
  echo "    If niri fails or you close it, Hyprland opens by itself. Emergency exit from niri: Ctrl+Alt+Delete"
  echo "    In niri: Super+Return terminal, Super+D apps, Super+Q close, Super+1..5 workspaces, Super+Shift+S screenshot of a region, Super+Shift+/ all keys"
}

main
