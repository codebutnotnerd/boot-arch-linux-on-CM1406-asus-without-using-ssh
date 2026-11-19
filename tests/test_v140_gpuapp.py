#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "install-gpuapp.sh"
UPSTREAM_PATCH_SHA256 = "f4ae1ba7a575e1bfac06120f52f404d932d9c955b309539912483e295b3f82db"
WSI_COMMIT = "f5148d4f8c541f8aeddc88170b9e2dbbea2e8b43"
GPU_VARS = ("VK_DRIVER_FILES", "VK_ADD_IMPLICIT_LAYER_PATH", "MESA_LOADER_DRIVER_OVERRIDE", "SDL_VIDEODRIVER")
RENDERER = "zink Vulkan 1.4(Mali-G57 (ARM_PROPRIETARY))"
NEW_FILES = {
    "usr/local/lib/tarkin-gpu/vulkan/mali_icd.json",
    "usr/local/lib/tarkin-gpu/vulkan/layer/libVkLayer_window_system_integration.so",
    "usr/local/lib/tarkin-gpu/vulkan/layer/VkLayer_window_system_integration.json",
    "usr/local/lib/tarkin-gpu/vulkan/layer/vulkan-wsi-layer-quigon.patch",
    "usr/local/lib/tarkin-gpu/vulkan/layer/SOURCE",
    "usr/local/bin/gpuapp",
    "etc/udev/rules.d/70-tarkin-dma-heap.rules",
}
FIREFOX_ENTRY = "usr/local/share/applications/firefox-gpu.desktop"


class GpuAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tarkin-zk-test-")
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.home = self.path / "home"
        self.home.mkdir()
        self.runtime = self.path / "runtime"
        self.runtime.mkdir()
        self.prefix = self.path / "prefix"
        self.proc = self.path / "proc"
        self.calls = self.path / "calls"
        self.calls.write_text("")
        self.heap = self.path / "dma_heap_system"
        self.heap.write_text("")
        shutil.copytree(ROOT / "rootfs", self.prefix, symlinks=True)
        self.write("etc/tarkin/console.env", "TARKIN_SESSION=desktop\nXKB_DEFAULT_LAYOUT=fr\nTARKIN_HYPR_RENDER=auto\n")
        self.write("usr/local/bin/hyprland-mali", "#!/bin/sh\nexec /usr/bin/start-hyprland \"$@\"\n", 0o755)
        self.write("usr/local/lib/tarkin-gpu/lib/egl-mali-shim.so", "shim fixture\n", 0o755)
        self.write("usr/local/lib/tarkin-gpu/mali/lib/libmali.so.0.54.1", "libmali fixture, not the proprietary library\n", 0o755)
        (self.prefix / "usr/local/lib/tarkin-gpu/mali/lib/libmali.so.0").symlink_to("libmali.so.0.54.1")
        self.write("usr/local/lib/tarkin-gpu/bin/mali-probe",
                   "#!/bin/bash\n[[ \"${PROBE_FAIL:-0}\" == 1 ]] && { echo 'FAIL: eglInitialize'; exit 1; }\necho GL_RENDERER=Mali-G57\n", 0o755)
        (self.prefix / "etc/udev/rules.d").mkdir(parents=True, exist_ok=True)
        (self.prefix / "usr/local/share").mkdir(parents=True, exist_ok=True)
        (self.proc / "4242").mkdir(parents=True)
        (self.proc / "4242/maps").write_text("7f00-7f01 r-xp 0 00:00 0 /usr/local/lib/tarkin-gpu/mali/lib/libmali.so.0.54.1\n")
        (self.proc / "4343").mkdir(parents=True)
        (self.proc / "4343/maps").write_text("7f00-7f01 r-xp 0 00:00 0 /usr/lib/libgallium-26.2.7.so\n")
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "WAYLAND_DISPLAY": "wayland-test",
            "TARKIN_PREFIX": str(self.prefix),
            "TARKIN_PROC_ROOT": str(self.proc),
            "TARKIN_DMA_HEAP": str(self.heap),
            "TMPDIR": str(self.path),
            "CALLS": str(self.calls),
            "HYPR_PIDS": "4242",
        }
        self.mock("readelf", """#!/bin/bash
[[ "${NO_VK:-0}" == 1 ]] || echo '   12: 0000000000a1b2c3   120 FUNC    GLOBAL DEFAULT   12 vk_icdGetInstanceProcAddr'
echo '   13: 0000000000a1b2d3   120 FUNC    GLOBAL DEFAULT   12 eglGetDisplay'
""")
        self.mock("pgrep", "#!/bin/bash\n[[ -n \"${HYPR_PIDS:-}\" ]] || exit 1\nprintf '%s\\n' $HYPR_PIDS\n")
        self.mock("vulkaninfo", """#!/bin/bash
echo "vulkaninfo VK_DRIVER_FILES=${VK_DRIVER_FILES:-} $*" >> "$CALLS"
[[ "${VULKAN_FAIL:-0}" == 1 ]] && { echo 'ERROR: [Loader Message] Code 0 : no drivers found'; exit 1; }
grep -q '"api_version": "1.3.211"' "$VK_DRIVER_FILES" || exit 1
printf 'GPU0:\\n\\tapiVersion = 1.4.313\\n\\tdeviceName = Mali-G57\\n\\tdriverInfo = r54p1-12eac0\\n'
""")
        self.mock("git", """#!/bin/bash
echo "git $*" >> "$CALLS"
[[ "${GIT_FAIL:-0}" == 1 ]] && { echo 'fatal: unable to access'; exit 128; }
case "$1" in
  clone) mkdir -p "$3" && echo 'set(CMAKE_CXX_FLAGS "-Wall -Werror -pthread")' > "$3/CMakeLists.txt" ;;
  -C) case "$3" in
        checkout) echo "${WRONG_HEAD:-$5}" > "$2/.head" ;;
        rev-parse) cat "$2/.head" ;;
        apply) cp "$4" "$2/applied.patch" ;;
      esac ;;
esac
""")
        self.mock("pkg-config", "#!/bin/bash\nexit 0\n")
        self.mock("cmake", "#!/bin/bash\necho \"cmake $*\" >> \"$CALLS\"\nmkdir -p build\n")
        self.mock("make", """#!/bin/bash
echo "make $*" >> "$CALLS"
[[ "${MAKE_FAIL:-0}" == 1 ]] && { echo 'error: boom in wsialloc_helpers.c'; exit 2; }
grep -q -- '-Werror' "$2/../CMakeLists.txt" && echo "WERROR-KEPT" >> "$CALLS"
sha256sum "$2/../applied.patch" | cut -d' ' -f1 > "$CALLS.patch"
echo 'layer fixture' > "$2/libVkLayer_window_system_integration.so"
echo '{ "file_format_version": "1.0.0", "layer": { "library_path": "./libVkLayer_window_system_integration.so" } }' > "$2/VkLayer_window_system_integration.json"
""")
        self.mock("eglinfo", """#!/bin/bash
if [[ "${MESA_LOADER_DRIVER_OVERRIDE:-}" == zink && -r "${VK_DRIVER_FILES:-}" \\
      && -r "${VK_ADD_IMPLICIT_LAYER_PATH:-}/VkLayer_window_system_integration.json" \\
      && -z "${LIBGL_ALWAYS_SOFTWARE:-}${GALLIUM_DRIVER:-}${GBM_ALWAYS_SOFTWARE:-}" && "${ZINK_BROKEN:-0}" != 1 ]]; then
  r='zink Vulkan 1.4(Mali-G57 (ARM_PROPRIETARY))'
else
  [[ "${MESA_LOADER_DRIVER_OVERRIDE:-}" == zink ]] && echo 'ZINK: vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)' >&2
  r='llvmpipe (LLVM 21.1.6, 128 bits)'
fi
printf 'Wayland platform:\\nEGL API version: 1.5\\nOpenGL core profile vendor: Mesa\\nOpenGL core profile renderer: %s\\n' "$r"
""")

    def write(self, name, text, mode=0o644):
        dest = self.prefix / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        dest.chmod(mode)

    def mock(self, name, text):
        dest = self.bin / name
        dest.write_text(text)
        dest.chmod(0o755)

    def install(self, *args, ok=True, **extra):
        result = subprocess.run(["bash", str(SCRIPT), *args], env=self.env | extra, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def gpuapp(self, *args, env=None, **extra):
        return subprocess.run([str(self.prefix / "usr/local/bin/gpuapp"), *args], env=(env or self.env) | extra,
                              text=True, capture_output=True)

    def snapshot(self, base=None):
        base = base or self.prefix
        result = {}
        for item in sorted(base.rglob("*")):
            rel = str(item.relative_to(base))
            if item.is_symlink():
                result[rel] = ("link", os.readlink(item))
            elif item.is_dir():
                result[rel] = ("dir",)
            else:
                result[rel] = ("file", stat.S_IMODE(item.stat().st_mode), hashlib.sha256(item.read_bytes()).hexdigest())
        return result

    def log(self):
        return self.calls.read_text()

    def test_install_into_prefix_reproduces_the_checked_recipe(self):
        before = self.snapshot()
        result = self.install()
        after = self.snapshot()
        new = {name for name, value in after.items() if name not in before and value[0] == "file"}
        self.assertEqual(new, NEW_FILES)
        mali = str(self.prefix / "usr/local/lib/tarkin-gpu/mali/lib/libmali.so.0")
        icd = json.loads((self.prefix / "usr/local/lib/tarkin-gpu/vulkan/mali_icd.json").read_text())
        self.assertEqual(icd, {"file_format_version": "1.0.0", "ICD": {"library_path": mali, "api_version": "1.3.211"}})
        self.assertEqual((self.prefix / "etc/udev/rules.d/70-tarkin-dma-heap.rules").read_text(),
                         'SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"\n')
        log = self.log()
        self.assertIn("git clone https://gitlab.freedesktop.org/mesa/vulkan-wsi-layer.git ", log)
        self.assertIn(f"checkout -q {WSI_COMMIT}", log)
        self.assertIn("cmake . -Bbuild -DCMAKE_BUILD_TYPE=Release -DBUILD_WSI_HEADLESS=1 -DBUILD_WSI_WAYLAND=1 "
                      "-DSELECT_EXTERNAL_ALLOCATOR=dma_buf_heaps -DWSIALLOC_MEMORY_HEAP_NAME=system "
                      "-DKERNEL_HEADER_DIR=/usr/include\n", log)
        self.assertNotIn("WERROR-KEPT", log)
        self.assertEqual(Path(str(self.calls) + ".patch").read_text().strip(), UPSTREAM_PATCH_SHA256)
        stamp = (self.prefix / "usr/local/lib/tarkin-gpu/vulkan/layer/SOURCE").read_text()
        self.assertIn(f"commit={WSI_COMMIT}\n", stamp)
        self.assertIn(f"patch_sha256={UPSTREAM_PATCH_SHA256}\n", stamp)
        self.assertEqual(after["usr/local/bin/gpuapp"][1], 0o755)
        self.assertEqual(after["usr/local/lib/tarkin-gpu/vulkan/mali_icd.json"][1], 0o644)
        self.assertFalse((self.prefix / "etc/vulkan").exists())
        self.assertEqual(list(self.home.iterdir()), [], "nothing may be left in the home folder")
        self.assertEqual([p.name for p in self.path.glob("tarkin-gpuapp.*")], [], "build folder must be cleaned")
        self.assertIn("gpuapp <program>", result.stdout)

    def test_existing_system_files_stay_byte_identical(self):
        before = self.snapshot()
        self.install()
        after = self.snapshot()
        for name, value in before.items():
            self.assertEqual(after[name], value, name)
        for name in ("usr/local/libexec/tarkin/console", "usr/local/bin/hyprland-mali", "etc/tarkin/console.env",
                     "usr/local/lib/tarkin-gpu/lib/egl-mali-shim.so", "etc/xdg/foot/foot.ini"):
            self.assertIn(name, before)

    def test_embedded_patch_is_the_upstream_file(self):
        text = SCRIPT.read_text()
        body = text.split("<<'WSI_PATCH_EOF'\n", 1)[1].split("WSI_PATCH_EOF\n", 1)[0]
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(), UPSTREAM_PATCH_SHA256)
        self.assertIn(f'WSI_PATCH_SHA256="{UPSTREAM_PATCH_SHA256}"', text)
        self.assertIn("zoan37", text)
        self.assertIn("MIT", text)

    def test_idempotent_and_rebuild(self):
        self.install()
        first = self.snapshot()
        result = self.install()
        self.assertEqual(self.snapshot(), first)
        self.assertEqual(self.log().count("git clone"), 1)
        self.assertIn("not compiled again", result.stdout)
        self.install("--rebuild")
        self.assertEqual(self.log().count("git clone"), 2)
        self.assertEqual(self.snapshot(), first)

    def test_dry_run_changes_nothing(self):
        before = self.snapshot()
        result = self.install("--dry-run")
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn("git clone", self.log())
        self.assertIn("[dry-run]", result.stdout)

    def assert_refused(self, message, *args, **extra):
        before = self.snapshot()
        result = self.install(*args, ok=False, **extra)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.snapshot(), before, "a refused run must not change the tree")
        return result

    def test_refuses_without_libmali(self):
        shutil.rmtree(self.prefix / "usr/local/lib/tarkin-gpu/mali")
        self.assert_refused("libmali is missing")
        self.assertNotIn("git clone", self.log())

    def test_refuses_dangling_libmali_link(self):
        (self.prefix / "usr/local/lib/tarkin-gpu/mali/lib/libmali.so.0.54.1").unlink()
        self.assert_refused("libmali is missing")

    def test_refuses_libmali_without_vulkan_driver(self):
        self.assert_refused("no Vulkan driver", NO_VK="1")

    def test_accepts_a_libmali_with_a_large_symbol_table(self):
        self.mock("readelf", """#!/bin/bash
echo '   12: 0000000000a1b2c3   120 FUNC    GLOBAL DEFAULT   12 vk_icdGetInstanceProcAddr'
exec seq -f '%.0f: 0000000000a1b2c3   120 FUNC    GLOBAL DEFAULT   12 mali_symbol' 13 200000
""")
        result = self.install()
        self.assertIn("libmali with a Vulkan driver", result.stdout)
        self.assertNotIn("no vk_icd symbols", result.stderr)

    def test_vk_icd_check_does_not_stop_reading_readelf_early(self):
        line = next(l for l in SCRIPT.read_text().splitlines() if "readelf --dyn-syms" in l)
        self.assertIn("| grep -c 'vk_icd' >/dev/null", line)
        self.assertNotRegex(line, r"grep\s+(-[A-Za-z]*q|--quiet|-[A-Za-z]*m)")

    def test_package_list_has_pkgconf_for_the_layer_build(self):
        text = SCRIPT.read_text()
        packages = next(l for l in text.splitlines() if l.startswith("PACKAGES=("))
        self.assertIn(" pkgconf ", packages)
        tools = next(l for l in text.splitlines() if l.strip().startswith("for c in git cmake"))
        self.assertIn(" pkg-config ", tools)

    def test_refuses_when_no_hyprland_runs(self):
        self.assert_refused("The desktop is not on the GPU", HYPR_PIDS="")

    def test_refuses_when_hyprland_is_on_software_rendering(self):
        self.assert_refused("The desktop is not on the GPU", HYPR_PIDS="4343")
        self.assertNotIn("git clone", self.log())

    def test_refuses_when_mali_probe_fails(self):
        self.assert_refused("Mali GPU probe failed", PROBE_FAIL="1")

    def test_refuses_when_vulkan_loader_sees_no_mali(self):
        self.assert_refused("does not find the Mali driver", VULKAN_FAIL="1")
        self.assertNotIn("git clone", self.log())

    def test_build_failure_installs_nothing_and_keeps_the_log(self):
        result = self.assert_refused("Building vulkan-wsi-layer failed", MAKE_FAIL="1")
        self.assertIn("boom in wsialloc_helpers.c", result.stderr)
        self.assertIn("boom", (self.home / "install-gpuapp-build.log").read_text())

    def test_download_failure_and_wrong_commit_install_nothing(self):
        self.assert_refused("Building vulkan-wsi-layer failed", GIT_FAIL="1")
        self.assert_refused("Building vulkan-wsi-layer failed", WRONG_HEAD="0" * 40)
        self.assertNotIn("cmake", self.log())

    def test_refuses_root_and_unknown_options(self):
        result = self.install("--bogus", ok=False)
        self.assertIn("Unknown option", result.stderr)
        result = self.install("--remove", "--check", ok=False)
        self.assertIn("mutually exclusive", result.stderr)
        if not shutil.which("unshare") or subprocess.run(["unshare", "-r", "true"], capture_output=True).returncode:
            return
        env = {k: v for k, v in self.env.items() if k != "TARKIN_PREFIX"}
        result = subprocess.run(["unshare", "-r", "bash", str(SCRIPT)], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Do not run this with sudo", result.stderr)

    def test_remove_is_complete(self):
        before = self.snapshot()
        self.write("usr/bin/firefox", "#!/bin/sh\n", 0o755)
        with_firefox = self.snapshot()
        self.install()
        self.assertIn(FIREFOX_ENTRY, self.snapshot())
        self.install("--remove")
        self.assertEqual(self.snapshot(), with_firefox)
        (self.prefix / "usr/bin/firefox").unlink()
        (self.prefix / "usr/bin").rmdir()
        self.assertEqual(self.snapshot(), before)
        self.install("--remove")
        self.assertEqual(self.snapshot(), before)

    def test_remove_keeps_other_menu_entries(self):
        self.write("usr/bin/firefox", "#!/bin/sh\n", 0o755)
        self.write("usr/local/share/applications/other.desktop", "[Desktop Entry]\n")
        self.install()
        self.install("--remove")
        self.assertTrue((self.prefix / "usr/local/share/applications/other.desktop").exists())
        self.assertFalse((self.prefix / FIREFOX_ENTRY).exists())

    def test_firefox_entry_only_when_firefox_is_installed(self):
        self.install()
        self.assertFalse((self.prefix / FIREFOX_ENTRY).exists())
        self.write("usr/bin/firefox", "#!/bin/sh\n", 0o755)
        self.write("usr/share/applications/firefox.desktop", "[Desktop Entry]\nName=Firefox\nExec=/usr/lib/firefox/firefox %u\n")
        normal = (self.prefix / "usr/share/applications/firefox.desktop").read_text()
        self.install()
        entry = (self.prefix / FIREFOX_ENTRY).read_text()
        self.assertIn("Name=Firefox (GPU)\n", entry)
        self.assertIn(f"Exec={self.prefix}/usr/local/bin/gpuapp firefox %u\n", entry)
        self.assertEqual((self.prefix / "usr/share/applications/firefox.desktop").read_text(), normal)
        (self.prefix / "usr/bin/firefox").unlink()
        self.install()
        self.assertFalse((self.prefix / FIREFOX_ENTRY).exists())

    def test_gpuapp_sets_the_variables_for_that_program_only(self):
        self.install()
        vk = self.prefix / "usr/local/lib/tarkin-gpu/vulkan"
        result = self.gpuapp("printenv", LIBGL_ALWAYS_SOFTWARE="1", GALLIUM_DRIVER="llvmpipe", GBM_ALWAYS_SOFTWARE="1",
                             KEEP_ME="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        got = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        self.assertEqual(got["VK_DRIVER_FILES"], str(vk / "mali_icd.json"))
        self.assertEqual(got["VK_ADD_IMPLICIT_LAYER_PATH"], str(vk / "layer"))
        self.assertEqual(got["MESA_LOADER_DRIVER_OVERRIDE"], "zink")
        self.assertEqual(got["SDL_VIDEODRIVER"], "wayland,x11")
        self.assertEqual(got["KEEP_ME"], "yes")
        for name in ("LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER", "GBM_ALWAYS_SOFTWARE", "LD_PRELOAD", "LD_LIBRARY_PATH"):
            self.assertNotIn(name, got)
        self.assertEqual(result.stderr, "")

    def test_gpuapp_passes_arguments_and_exit_status(self):
        self.install()
        result = self.gpuapp("bash", "-c", 'printf "%s|" "$@"; exit 7', "x", "a b", "--check")
        self.assertEqual((result.returncode, result.stdout), (7, "a b|--check|"))
        result = self.gpuapp("--", "printenv", "MESA_LOADER_DRIVER_OVERRIDE")
        self.assertEqual(result.stdout, "zink\n")
        self.assertEqual(self.gpuapp("no-such-program-xyz").returncode, 127)
        self.assertEqual(self.gpuapp().returncode, 2)
        self.assertEqual(self.gpuapp("--help").returncode, 0)
        self.assertEqual(self.gpuapp("--bogus").returncode, 2)

    def test_gpuapp_warns_when_the_heap_is_not_accessible(self):
        self.install()
        result = self.gpuapp("true", TARKIN_DMA_HEAP=str(self.path / "absent"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("is not readable and writable", result.stderr)

    def test_check_says_yes_with_the_renderer(self):
        self.install()
        result = self.gpuapp("--check", LIBGL_ALWAYS_SOFTWARE="1", GALLIUM_DRIVER="llvmpipe")
        self.assertEqual((result.returncode, result.stdout), (0, f"apps on the GPU: yes ({RENDERER})\n"))

    def test_check_finds_the_wayland_socket_by_itself(self):
        import socket
        self.install()
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.runtime / "wayland-1"))
        env = {k: v for k, v in self.env.items() if k != "WAYLAND_DISPLAY"}
        self.assertEqual(self.gpuapp("--check", env=env).returncode, 0)
        os.unlink(self.runtime / "wayland-1")
        result = self.gpuapp("--check", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("apps on the GPU: no (no Wayland session found", result.stdout)

    def test_check_says_no_with_the_reason(self):
        self.install()
        result = self.gpuapp("--check", ZINK_BROKEN="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn("apps on the GPU: no (renderer is llvmpipe", result.stdout)
        self.assertIn("VK_ERROR_INCOMPATIBLE_DRIVER", result.stdout)
        result = self.gpuapp("--check", TARKIN_DMA_HEAP=str(self.path / "absent"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("apps on the GPU: no (", result.stdout)
        self.assertIn("group video, mode 0660", result.stdout)
        (self.bin / "eglinfo").unlink()
        if not shutil.which("eglinfo", path=self.env["PATH"]):
            result = self.gpuapp("--check")
            self.assertIn("apps on the GPU: no (eglinfo is missing", result.stdout)
        shutil.rmtree(self.prefix / "usr/local/lib/tarkin-gpu/vulkan/layer")
        self.assertIn("apps on the GPU: no (the Vulkan Wayland layer is missing", self.gpuapp("--check").stdout)
        shutil.rmtree(self.prefix / "usr/local/lib/tarkin-gpu/mali")
        self.assertIn("apps on the GPU: no (libmali is missing", self.gpuapp("--check").stdout)

    def test_measure_without_glmark2_says_so(self):
        if shutil.which("glmark2-es2-wayland"):
            self.skipTest("glmark2 is installed on this host")
        self.install()
        result = self.gpuapp("--measure")
        self.assertEqual(result.returncode, 2)
        self.assertIn("No speed measured: glmark2-es2-wayland is not installed", result.stdout)
        self.assertIn("without gpuapp: llvmpipe", result.stdout)
        self.assertIn(f"with gpuapp   : {RENDERER}", result.stdout)
        self.assertEqual(self.gpuapp("--mesure").stdout, result.stdout)

    def test_measure_compares_before_and_after(self):
        self.install()
        self.mock("glmark2-es2-wayland", """#!/bin/bash
echo "glmark2 $*" >> "$CALLS"
if [[ "${MESA_LOADER_DRIVER_OVERRIDE:-}" == zink ]]; then s=670; else s=59; fi
[[ "${GLMARK_HANG:-0}" == 1 && $s == 59 ]] && exit 124
printf '=======\\n    glmark2 Score: %s \\n=======\\n' "$s"
""")
        result = self.gpuapp("--measure")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("glmark2 score without gpuapp: 59\n", result.stdout)
        self.assertIn("glmark2 score with gpuapp   : 670\n", result.stdout)
        self.assertIn("ratio: x11.3", result.stdout)
        self.assertEqual(self.log().count("glmark2 "), 2)
        result = self.gpuapp("--measure", GLMARK_HANG="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("none (failed or timed out)", result.stdout)
        text = (self.prefix / "usr/local/bin/gpuapp").read_text()
        self.assertRegex(text, r"timeout 90 .*glmark2-es2-wayland")
        self.assertRegex(text, r"timeout 20 .*eglinfo")

    def test_installer_check_mode(self):
        result = self.install("--check", ok=False)
        self.assertIn("apps on the GPU: no (gpuapp is not installed", result.stdout)
        self.install()
        before = self.snapshot()
        result = self.install("--check")
        self.assertIn(f"apps on the GPU: yes ({RENDERER})", result.stdout)
        self.assertNotIn("[no]", result.stdout)
        self.write("etc/vulkan/icd.d/mali.json", '{"ICD": {"library_path": "/x/libmali.so.0"}}\n')
        result = self.install("--check", ok=False)
        self.assertIn("system-wide Vulkan file points to libmali", result.stdout)
        shutil.rmtree(self.prefix / "etc/vulkan")
        self.assertEqual(self.snapshot(), before, "--check is read-only")
        (self.prefix / "usr/local/lib/tarkin-gpu/vulkan/mali_icd.json").unlink()
        self.install("--check", ok=False)

    def test_variables_never_reach_hyprland_or_the_console(self):
        self.write("usr/bin/firefox", "#!/bin/sh\n", 0o755)
        before = self.snapshot()
        self.install()
        after = self.snapshot()
        added = {name for name in after if name not in before and after[name][0] != "dir"}
        self.assertEqual(added, NEW_FILES | {FIREFOX_ENTRY})
        pattern = re.compile("|".join(GPU_VARS[:2]) + "|zink|gpuapp")
        carriers = {name for name in added
                    if pattern.search((self.prefix / name).read_bytes().decode("utf-8", "replace"))}
        self.assertEqual(carriers, {"usr/local/bin/gpuapp", FIREFOX_ENTRY})
        for name in added:
            self.assertFalse(name.startswith(("etc/vulkan", "etc/environment", "etc/profile", "etc/tarkin", "etc/xdg",
                                              "usr/share/vulkan", "usr/share/wayland-sessions")), name)
        self.assertEqual(list(self.home.iterdir()), [])
        desktop_side = [ROOT / "install-hyprland.sh", ROOT / "install-xfce.sh", ROOT / "scripts/install-desktop.sh"]
        desktop_side += [p for p in (ROOT / "rootfs").rglob("*") if p.is_file() and p.name != "tarkin-diag"]
        for item in desktop_side:
            text = item.read_bytes().decode("utf-8", "replace")
            self.assertIsNone(pattern.search(text), item)
        console = (ROOT / "rootfs/usr/local/libexec/tarkin/console").read_text()
        self.assertEqual(console.count("MESA_LOADER_DRIVER_OVERRIDE WLR_RENDERER"), 2)

    def test_without_the_script_the_system_tree_has_no_gpuapp(self):
        names = [str(p.relative_to(ROOT / "rootfs")) for p in (ROOT / "rootfs").rglob("*")]
        for name in names:
            self.assertNotRegex(name, r"gpuapp|vulkan|dma-heap|firefox-gpu")
        for item in (ROOT / "install-hyprland.sh", ROOT / "rootfs/usr/local/libexec/tarkin/firstboot",
                     ROOT / "scripts/install-desktop.sh", ROOT / "install.sh", ROOT / "install/go.sh"):
            self.assertNotIn("install-gpuapp", item.read_text(), item)
        usb = [line for line in (ROOT / "install/install-usb.sh").read_text().splitlines() if "install-gpuapp" in line]
        self.assertEqual(len(usb), 2)
        self.assertTrue(usb[0].startswith('install -m 755 "$REPO_ROOT/install-gpuapp.sh" "$MNT/home/alarm/'))
        self.assertTrue(usb[1].startswith("chown "))

    def test_diag_line_is_guarded(self):
        lines = [line.strip() for line in (ROOT / "rootfs/usr/local/bin/tarkin-diag").read_text().splitlines()
                 if "gpuapp" in line and not line.strip().startswith("#")]
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('[[ -x /usr/local/bin/gpuapp ]] && sh_ "runuser -u $user -- '), lines[0])
        self.assertTrue(lines[0].endswith('/usr/local/bin/gpuapp --check"'))


if __name__ == "__main__":
    unittest.main()
