#!/usr/bin/env python3
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ComfortTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.home = self.path / "home"
        self.home.mkdir()
        self.runtime = self.path / "runtime"
        self.runtime.mkdir()
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "WAYLAND_DISPLAY": "wayland-test",
            "TARKIN_PREFIX": str(self.path / "prefix"),
            "CALLS": str(self.path / "calls"),
            "HYPR_VERSION": "0.57.0",
        }
        self.mock("Hyprland", """#!/bin/bash
if [[ "${VERIFY_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "${VERIFY_APPENDED_FAIL:-0}" == 1 ]] && grep -q tarkin-comfort-start "$XDG_CONFIG_HOME/hypr/hyprland.lua"; then exit 1; fi
echo verified
""")
        self.mock("hyprctl", """#!/bin/bash
if [[ "$1" == version ]]; then echo "Hyprland ${HYPR_VERSION} built from branch test"; exit "${VERSION_RC:-0}"; fi
printf '%s\\n' "$*" >> "$CALLS"
echo "${DISPATCH_OUT:-ok}"
exit "${DISPATCH_RC:-0}"
""")
        release = self.path / "release"
        release.mkdir()
        (release / "rootfs").symlink_to(ROOT / "rootfs", target_is_directory=True)
        source = (ROOT / "install-hyprland.sh").read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = release / "install-hyprland.sh"
        self.source.write_text(source)

    def mock(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)
        return p

    def shell(self, text, **env):
        return subprocess.run(["bash", "-c", 'script="$1"; shift; source "$script"; ' + text, "_", str(self.source)],
                              env=self.env | env, text=True, capture_output=True)

    def helper(self, name, *args, **env):
        return subprocess.run([str(ROOT / "rootfs/usr/local/bin" / name), *args],
                              env=self.env | env, text=True, capture_output=True)

    def config(self, suffix, text):
        p = Path(self.env["XDG_CONFIG_HOME"]) / "hypr" / ("hyprland." + suffix)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def test_defaults_and_idempotence(self):
        self.config("lua", 'hl.config({})\n')
        conf = self.config("conf", 'monitor = , preferred, auto, 1\n')
        result = self.shell("configure_comfort; configure_comfort")
        self.assertEqual(result.returncode, 0, result.stderr)
        lua = conf.with_suffix(".lua")
        self.assertEqual(lua.read_text().count('hl.bind("SUPER + L"'), 1)
        self.assertEqual(conf.read_text().count("bind = SUPER, L"), 1)
        idle = conf.with_name("hypridle.conf").read_text()
        self.assertIn("timeout = 300", idle)
        self.assertIn("timeout = 330", idle)
        self.assertNotIn("suspend", idle)
        self.assertNotIn("loginctl", idle)

    def test_existing_dotfiles_kept(self):
        lua = self.config("lua", 'hl.bind(mod .. " + L", custom)\n')
        idle = lua.with_name("hypridle.conf")
        idle.write_text("custom idle\n")
        lock = self.home / ".config/swaylock/config"
        lock.parent.mkdir()
        lock.write_text("custom lock\n")
        before = lua.read_bytes()
        result = self.shell("configure_comfort")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lua.read_bytes(), before)
        self.assertEqual(idle.read_text(), "custom idle\n")
        self.assertEqual(lock.read_text(), "custom lock\n")
        self.assertIn("Keeping existing", result.stderr)

    def test_external_includes_not_modified(self):
        for suffix, text in [("lua", 'dofile("my-binds.lua")\n'),
                             ("conf", "source = ~/.config/hypr/binds.conf\n")]:
            p = self.config(suffix, text)
            result = self.shell("configure_comfort")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(p.read_text(), text)

    def test_invalid_lua_preserved(self):
        lua = self.config("lua", "broken config\n")
        result = self.shell("write_hyprland_config", VERIFY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lua.read_text(), "broken config\n")
        self.assertIn("preserved", result.stderr)

    def test_legacy_config_kept(self):
        conf = self.config("conf", "monitor = , preferred, auto, 1\n")
        result = self.shell("write_hyprland_config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(conf.read_text().startswith("monitor = , preferred"))
        self.assertFalse(conf.with_suffix(".lua").exists())
        self.assertIn("bind = SUPER, L", conf.read_text())

    def test_verify_rollback(self):
        lua = self.config("lua", "hl.config({})\n")
        result = self.shell("configure_comfort", VERIFY_APPENDED_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lua.read_text(), "hl.config({})\n")
        self.assertIn("restored", result.stderr)

    def test_config_only_dry_run_writes_nothing(self):
        result = self.shell("DRY_RUN=1; CONFIG_ONLY=1; check_environment() { :; }; main")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / ".config").exists())

    def test_install_files_staged_and_custom_preserved(self):
        result = self.shell("install_comfort_files")
        self.assertEqual(result.returncode, 0, result.stderr)
        target = Path(self.env["TARKIN_PREFIX"]) / "usr/local/bin/tarkin-lock"
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        audio = Path(self.env["TARKIN_PREFIX"]) / "usr/local/libexec/tarkin/audio-profile"
        self.assertEqual(audio.stat().st_mode & 0o777, 0o755)
        target.write_text("custom\n")
        audio.write_text("custom audio\n")
        result = self.shell("install_comfort_files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(), "custom\n")
        self.assertEqual(audio.read_text(), "custom audio\n")
        self.assertIn("Keeping customized", result.stderr)

    def test_dpms_modern_and_legacy(self):
        result = self.helper("tarkin-dpms", "on")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('dispatch hl.dsp.dpms({ action = "on" })', Path(self.env["CALLS"]).read_text())
        result = self.helper("tarkin-dpms", "on", HYPR_VERSION="0.56.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(Path(self.env["CALLS"]).read_text().endswith("dispatch dpms on\n"))

    def test_dpms_fails_closed(self):
        for overrides in [{"VERSION_RC": "1"}, {"HYPR_VERSION": "unknown"},
                          {"DISPATCH_RC": "1"}, {"DISPATCH_OUT": "error: failed"}]:
            result = self.helper("tarkin-dpms", "on", **overrides)
            self.assertNotEqual(result.returncode, 0, result.stdout)
        result = self.helper("tarkin-dpms", "off")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing", result.stderr)

    def test_stale_marker_never_blanks_screen(self):
        (self.runtime / "tarkin-lock.ready").write_text(str(os.getpid()))
        (self.runtime / "tarkin-lock.flock").touch()
        result = self.helper("tarkin-dpms", "off")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(self.env["CALLS"]).exists())

    def test_lock_readiness_and_unlock_cleanup(self):
        import select
        self.mock("swaylock", """#!/usr/bin/env python3
import os,sys
os.write(int(sys.argv[2]), b"\\n")
print("ready", flush=True)
sys.stdin.read()
""")
        child = subprocess.Popen([str(ROOT / "rootfs/usr/local/bin/tarkin-lock")],
                                 env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.assertTrue(select.select([child.stdout], [], [], 5)[0])
        self.assertEqual(child.stdout.readline(), b"ready\n")
        child.stdin.close()
        child.wait(timeout=5)
        self.assertEqual(child.returncode, 0, child.stderr.read())
        child.stdout.close()
        child.stderr.close()
        self.assertFalse((self.runtime / "tarkin-lock.ready").exists())

    def test_confirmed_lock_allows_off(self):
        (self.runtime / "tarkin-lock.ready").write_text(str(os.getpid()))
        with (self.runtime / "tarkin-lock.flock").open("w") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            result = self.helper("tarkin-dpms", "off")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_locker_failure_never_marks_ready(self):
        self.mock("swaylock", "#!/bin/sh\nexit 1\n")
        result = self.helper("tarkin-lock")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.runtime / "tarkin-lock.ready").exists())
        self.assertIn("did not confirm", result.stderr)

    def test_bluetooth_enable_errors_are_not_success(self):
        self.mock("systemctl", "#!/bin/sh\nexit 1\n")
        self.mock("bluetoothctl", "#!/bin/sh\necho 'Controller AA test'\n")
        result = self.shell('PREFIX=""; SUDO=(); enable_bluetooth')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[+] Bluetooth enabled", result.stdout)
        self.mock("systemctl", "#!/bin/sh\nexit 0\n")
        self.mock("bluetoothctl", "#!/bin/sh\n[ \"$1\" = list ] && { echo 'Controller AA test'; exit 0; }\nexit 1\n")
        result = self.shell('PREFIX=""; SUDO=(); enable_bluetooth')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rfkill", result.stderr)

    def test_firstboot_completes_when_bluetooth_fails(self):
        steps = ["check_environment", "install_gpu_stack", "install_display_tools", "write_console_files", "fix_console_env",
                 "install_comfort_files", "write_hyprland_config", "assert_display_owner",
                 "enable_console_display", "enable_audio", "test_wrapper", "clear_firstboot_markers"]
        stubs = " ".join("%s() { echo CALL:%s; };" % (n, n) for n in steps)
        cases = [
            ("power", "#!/bin/sh\nexit 0\n",
             "#!/bin/sh\n[ \"$1\" = list ] && { echo 'Controller AA test'; exit 0; }\necho 'org.bluez.Error.Blocked' >&2; exit 1\n", "rfkill"),
            ("service", "#!/bin/sh\nexit 1\n", "#!/bin/sh\necho 'Controller AA test'\n", "bluetooth.service"),
            ("tools", "#!/bin/sh\nexit 0\n", None, "Bluetooth tools missing"),
        ]
        for label, systemctl, bluetoothctl, hint in cases:
            with self.subTest(label):
                self.mock("systemctl", systemctl)
                target = self.bin / "bluetoothctl"
                if bluetoothctl is None:
                    target.unlink(missing_ok=True)
                    env = {"PATH": str(self.bin) + ":/usr/bin:/bin"}
                    if any((Path(d) / "bluetoothctl").exists() for d in ("/usr/bin", "/bin")):
                        continue
                else:
                    self.mock("bluetoothctl", bluetoothctl)
                    env = {}
                result = self.shell(stubs + ' will_install_packages() { return 1; }; PREFIX=""; SUDO=(); DRY_RUN=0; GPU_ONLY=0; WITH_GDM=0; main', **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [line[5:] for line in result.stdout.splitlines() if line.startswith("CALL:")]
                for step in ("enable_audio", "test_wrapper", "clear_firstboot_markers"):
                    self.assertIn(step, calls)
                self.assertLess(calls.index("enable_audio"), calls.index("test_wrapper"))
                self.assertLess(calls.index("test_wrapper"), calls.index("clear_firstboot_markers"))
                self.assertIn(hint, result.stderr)
                self.assertIn("Bluetooth is not ready", result.stderr)
                self.assertNotIn("[+] Bluetooth enabled", result.stdout)

    def test_bluetooth_without_adapter_is_explicit(self):
        self.mock("systemctl", "#!/bin/sh\nexit 0\n")
        self.mock("bluetoothctl", "#!/bin/sh\nexit 0\n")
        result = self.shell('PREFIX=""; SUDO=(); enable_bluetooth')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("[+] Bluetooth enabled", result.stdout)
        self.assertIn("no Bluetooth adapter", result.stderr)

    def test_audio_keeps_selected_bluetooth_sink(self):
        source = (ROOT / "rootfs/usr/local/libexec/tarkin/audio-profile").read_text()
        start = source.index("select_local_sink() {")
        end = source.index("\nroute()", start)
        self.mock("pactl", """#!/bin/bash
if [[ "$1" == get-default-sink ]]; then echo "${DEFAULT_SINK}"; exit 0; fi
echo "$*" >> "$CALLS"
""")
        script = "log() { echo \"$*\" >&2; }; " + source[start:end] + '\nselect_local_sink alsa_output.test'
        result = subprocess.run(["bash", "-c", script], env=self.env | {"DEFAULT_SINK": "bluez_output.TEST.1"},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env["CALLS"]).exists())
        result = subprocess.run(["bash", "-c", script], env=self.env | {"DEFAULT_SINK": "alsa_output.old"},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set-default-sink alsa_output.test", Path(self.env["CALLS"]).read_text())

    def test_audio_route_keeps_bluetooth_microphone(self):
        source = (ROOT / "rootfs/usr/local/libexec/tarkin/audio-profile").read_text()
        start = source.index("select_local_sink() {")
        end = source.index("\njack_state()", start)
        self.mock("pactl", """#!/bin/bash
case "$1" in
get-default-sink) echo bluez_output.TEST.1 ;;
get-default-source) echo bluez_input.TEST.0 ;;
*) echo "$*" >> "$CALLS" ;;
esac
""")
        script = '''log() { echo "$*" >&2; }
ucm() { :; }
has_node() { return 0; }
LOCK="$XDG_RUNTIME_DIR/route.lock"
SINK_HP=alsa_output.hp; SINK_SPK=alsa_output.spk
SRC_HS=alsa_input.hs; SRC_INT=alsa_input.int
''' + source[start:end] + "\nroute 1 1"
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env["CALLS"]).exists())

    def test_comfort_starts_idle_without_systemd(self):
        self.config("conf", "")
        (self.home / ".config/hypr/hypridle.conf").write_text("custom\n")
        self.mock("pgrep", '#!/bin/sh\ncase "$*" in *blueman-applet*) exit 0;; *) exit 1;; esac\n')
        self.mock("hypridle", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n')
        result = self.helper("tarkin-comfort-start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hypridle.conf", Path(self.env["CALLS"]).read_text())

    def test_comfort_keeps_existing_idle(self):
        self.mock("pgrep", "#!/bin/sh\nexit 0\n")
        self.mock("hypridle", '#!/bin/sh\necho wrong >> "$CALLS"\n')
        result = self.helper("tarkin-comfort-start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env["CALLS"]).exists())
        self.assertIn("keeping", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
