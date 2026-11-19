#!/usr/bin/env python3
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "rootfs/usr/local/bin"
LIBEXEC = ROOT / "rootfs/usr/local/libexec/tarkin"


class Base(unittest.TestCase):
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
        self.calls = self.path / "calls"
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "CALLS": str(self.calls),
        }

    def mock(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)
        return p

    def run_cmd(self, args, **env):
        return subprocess.run([str(a) for a in args], env=self.env | env, text=True, capture_output=True)

    def logged(self):
        return self.calls.read_text() if self.calls.exists() else ""


class KeyboardBacklight(Base):
    def setUp(self):
        super().setUp()
        self.leds = self.path / "leds"
        self.leds.mkdir()
        self.level = self.path / "level"
        self.mock("brightnessctl", """#!/bin/bash
echo "$*" >> "$CALLS"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    get) cat "$LEVEL"; exit 0 ;;
    max) echo 3; exit 0 ;;
    set) echo "${args[$((i + 1))]}" > "$LEVEL"; exit 0 ;;
  esac
done
""")
        self.env |= {"TARKIN_LEDS_DIR": str(self.leds), "LEVEL": str(self.level)}

    def toggle(self):
        return self.run_cmd([BIN / "tarkin-kbd-backlight"])

    def test_toggle_off_then_back_to_the_previous_level(self):
        (self.leds / "cros_ec::kbd_backlight").mkdir()
        self.level.write_text("2\n")
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(self.level.read_text().strip(), "0")
        self.assertIn("-d cros_ec::kbd_backlight", self.logged())
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(self.level.read_text().strip(), "2")

    def test_off_without_memory_turns_on_at_max(self):
        (self.leds / "white:kbd_backlight").mkdir()
        self.level.write_text("0\n")
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(self.level.read_text().strip(), "3")

    def test_no_led_is_quiet(self):
        result = self.toggle()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertEqual(self.logged(), "")

    def test_no_brightnessctl_is_quiet(self):
        (self.leds / "cros_ec::kbd_backlight").mkdir()
        result = self.run_cmd(["/bin/bash", BIN / "tarkin-kbd-backlight"], PATH="/usr/bin:/bin")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_device_not_hardcoded(self):
        text = (BIN / "tarkin-kbd-backlight").read_text()
        self.assertNotIn("cros_ec", text)
        self.assertIn("*kbd_backlight*", text)


class SmoothMode(Base):
    def setUp(self):
        super().setUp()
        self.sys = self.path / "sys"
        self.gpu = self.sys / "class/devfreq/13000000.gpu"
        self.gpu.mkdir(parents=True)
        (self.gpu / "available_frequencies").write_text("390000000 422000000 457000000 492000000 526000000 1100000000\n")
        (self.gpu / "min_freq").write_text("390000000\n")
        (self.gpu / "max_freq").write_text("1100000000\n")
        (self.gpu / "cur_freq").write_text("390000000\n")
        self.state = self.path / "state"
        self.mock("pgrep", '#!/bin/bash\n[[ "$*" == "-x Hyprland" ]] && echo 4242\n')
        self.mock("uclampset", '#!/bin/bash\necho "uclampset $*" >> "$CALLS"\n[[ "$*" == "-p 4242" ]] && echo "current util clamp for pid 4242 is: 512:1024"\nexit "${UCLAMP_RC:-0}"\n')
        self.mock("systemctl", '#!/bin/bash\necho "systemctl $*" >> "$CALLS"\ncase "$1" in is-enabled) echo disabled; exit 1 ;; is-active) echo inactive; exit 3 ;; esac\n')
        self.env |= {"TARKIN_SYSFS": str(self.sys), "TARKIN_SMOOTH_STATE": str(self.state)}

    def helper(self, *args, **env):
        return self.run_cmd([LIBEXEC / "smooth", *args], **env)

    def min_freq(self):
        return (self.gpu / "min_freq").read_text().strip()

    def test_apply_and_stop_restore_the_factory_values(self):
        result = self.helper("apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.min_freq(), "526000000")
        self.assertIn("uclampset -a -R -m 512 -p 4242", self.logged())
        self.assertEqual(self.helper("apply").returncode, 0)
        self.assertEqual((self.state / "smooth.gpu-min").read_text().split()[1], "390000000")
        result = self.helper("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.min_freq(), "390000000")
        self.assertIn("uclampset -a -R -m 0 -p 4242", self.logged())
        self.assertFalse((self.state / "smooth.gpu-min").exists())

    def test_frequency_must_be_listed(self):
        (self.gpu / "available_frequencies").write_text("390000000 1100000000\n")
        result = self.helper("apply")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.min_freq(), "390000000")
        self.assertIn("not listed", result.stdout)

    def test_higher_user_minimum_is_left_alone(self):
        (self.gpu / "min_freq").write_text("1100000000\n")
        self.assertEqual(self.helper("apply").returncode, 0)
        self.assertEqual(self.min_freq(), "1100000000")
        self.assertEqual(self.helper("stop").returncode, 0)
        self.assertEqual(self.min_freq(), "1100000000")

    def test_no_gpu_node_and_no_uclamp_are_not_errors(self):
        result = self.helper("apply", TARKIN_SYSFS=str(self.path / "empty"), UCLAMP_RC="1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("no GPU devfreq node", result.stdout)

    def test_other_gpu_node_name_is_found(self):
        other = self.sys / "class/devfreq/fb000000.mali"
        self.gpu.rename(other)
        self.gpu = other
        self.assertEqual(self.helper("apply").returncode, 0)
        self.assertEqual(self.min_freq(), "526000000")

    def test_command_needs_root_and_shows_status(self):
        if os.geteuid() == 0:
            self.skipTest("runs as a normal user")
        result = self.run_cmd([BIN / "tarkin-smooth", "on"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sudo tarkin-smooth on", result.stderr)
        self.assertNotIn("systemctl enable", self.logged())
        result = self.run_cmd([BIN / "tarkin-smooth", "status"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("smooth mode: off", result.stdout)
        self.assertIn("GPU 13000000.gpu: min 390000000 Hz", result.stdout)
        self.assertIn("512:1024", result.stdout)

    @unittest.skipUnless(os.geteuid() == 0, "needs root (disposable machine)")
    def test_on_and_off_as_root(self):
        env = {"TARKIN_SMOOTH_HELPER": str(LIBEXEC / "smooth")}
        result = self.run_cmd([BIN / "tarkin-smooth", "on"], **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl enable tarkin-smooth.service", self.logged())
        self.assertIn("systemctl restart tarkin-smooth.service", self.logged())
        self.helper("apply")
        result = self.run_cmd([BIN / "tarkin-smooth", "off"], **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl disable --now tarkin-smooth.service", self.logged())
        self.assertEqual(self.min_freq(), "390000000")

    def test_unit_is_opt_in(self):
        unit = (ROOT / "rootfs/etc/systemd/system/tarkin-smooth.service").read_text()
        self.assertIn("ExecStart=/usr/local/libexec/tarkin/smooth run", unit)
        self.assertIn("ExecStopPost=/usr/local/libexec/tarkin/smooth stop", unit)
        self.assertEqual(list(ROOT.joinpath("rootfs").rglob("*.wants/tarkin-smooth.service")), [])
        self.assertNotIn("tarkin-smooth on", (ROOT / "install/install-usb.sh").read_text())
        self.assertNotIn("tarkin-smooth on", (LIBEXEC / "firstboot").read_text())


class Installer(Base):
    def setUp(self):
        super().setUp()
        self.prefix = self.path / "prefix"
        self.env |= {"TARKIN_PREFIX": str(self.prefix)}
        self.mock("Hyprland", '#!/bin/bash\n[[ "${VERIFY_FAIL:-0}" == 1 ]] && exit 1\nexit 0\n')
        release = self.path / "release"
        release.mkdir()
        (release / "rootfs").symlink_to(ROOT / "rootfs", target_is_directory=True)
        source = (ROOT / "install-hyprland.sh").read_text().rsplit('\nmain "$@"', 1)[0]
        self.source = release / "install-hyprland.sh"
        self.source.write_text(source)

    def shell(self, text, **env):
        return subprocess.run(["bash", "-c", 'script="$1"; shift; source "$script"; ' + text, "_", str(self.source)],
                              env=self.env | env, text=True, capture_output=True)

    def config(self, suffix, text):
        p = self.home / ".config/hypr" / ("hyprland." + suffix)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p


class Keys(Installer):
    def blocks(self, name):
        text = (ROOT / name).read_text()
        lua = re.search(r'\nhl\.monitor\(\{.*?\nEOF\n', text, re.S).group(0)
        conf = re.search(r'\nmonitor = , preferred, auto, 1\n.*?\nEOF\n', text, re.S).group(0)
        return lua, conf

    def test_generated_configs_bind_the_keys(self):
        for name in ("install-hyprland.sh", "scripts/install-desktop.sh"):
            with self.subTest(name):
                lua, conf = self.blocks(name)
                for key in ("F6", "F7", "F8", "F13", "F14"):
                    self.assertEqual(lua.count('hl.bind("%s",' % key), 1, key)
                    self.assertEqual(len(re.findall(r'^bind[a-z]* = , %s, ' % key, conf, re.M)), 1, key)
                self.assertIn('hl.bind("F6", hl.dsp.exec_cmd("brightnessctl set 5%- --min-value=1")', lua)
                self.assertIn('hl.bind("F7", hl.dsp.exec_cmd("brightnessctl set 5%+")', lua)
                self.assertIn('hl.bind("F8", hl.dsp.exec_cmd("/usr/local/bin/tarkin-kbd-backlight")', lua)
                self.assertIn('hl.bind("F13", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")', lua)
                self.assertIn('hl.bind("F14", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+")', lua)
                for keysym in ("XF86MonBrightnessUp", "XF86MonBrightnessDown", "XF86AudioRaiseVolume",
                               "XF86AudioLowerVolume", "XF86AudioMute", "XF86KbdLightOnOff"):
                    self.assertIn('hl.bind("%s",' % keysym, lua)
                    self.assertIn(", %s, " % keysym, conf)
                for line in lua.splitlines():
                    if line.startswith("hl.bind("):
                        self.assertRegex(line, r'^hl\.bind\((mod \.\. )?"[^"]+",\s+hl\.dsp\.')
                self.assertNotIn('hl.bind("",', lua)
                self.assertNotIn("gpuapp", lua + conf)
                self.assertNotIn("kitty", lua + conf)

    def test_existing_configs_get_the_keys_once(self):
        lua = self.config("lua", "hl.config({})\n")
        conf = self.config("conf", "monitor = , preferred, auto, 1\n")
        result = self.shell("configure_keys; configure_keys")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lua.read_text().count('hl.bind("F8"'), 1)
        self.assertEqual(lua.read_text().count('hl.bind("F6"'), 1)
        self.assertEqual(conf.read_text().count("bindl = , F8, exec"), 1)
        self.assertTrue(lua.with_name("hyprland.lua.before-tarkin-keys").exists())

    def test_own_f_keys_and_includes_are_kept(self):
        for suffix, text in [("lua", 'hl.bind("F8", hl.dsp.exec_cmd("mine"))\n'),
                             ("conf", "bind = , F7, exec, mine\n"),
                             ("lua", 'dofile("binds.lua")\n'),
                             ("conf", "source = ~/.config/hypr/binds.conf\n")]:
            with self.subTest(text):
                p = self.config(suffix, text)
                result = self.shell("configure_keys")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(p.read_text(), text)
                p.unlink()

    def test_rejected_keys_are_rolled_back_without_stopping(self):
        lua = self.config("lua", "hl.config({})\n")
        result = self.shell("configure_keys; echo after", VERIFY_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lua.read_text(), "hl.config({})\n")
        self.assertIn("restored", result.stderr)
        self.assertIn("after", result.stdout)

    def test_fresh_config_written_with_keys(self):
        result = self.shell("write_hyprland_config")
        self.assertEqual(result.returncode, 0, result.stderr)
        lua = (self.home / ".config/hypr/hyprland.lua").read_text()
        self.assertEqual(lua.count('hl.bind("F8"'), 1)
        self.assertEqual(lua.count('hl.bind("F7"'), 1)


class OldSticks(Installer):
    def test_display_tools_installed_from_the_release(self):
        result = self.shell("install_display_tools")
        self.assertEqual(result.returncode, 0, result.stderr)
        for f in ("usr/local/bin/tarkin-display", "usr/local/libexec/tarkin/display-guard",
                  "etc/systemd/system/tarkin-console.service"):
            self.assertEqual((self.prefix / f).read_bytes(), (ROOT / "rootfs" / f).read_bytes())
        self.assertEqual((self.prefix / "usr/local/bin/tarkin-display").stat().st_mode & 0o777, 0o755)
        unit = self.prefix / "etc/systemd/system/tarkin-console.service"
        unit.write_text("[Service]\nExecStart=/usr/local/libexec/tarkin/console\n")
        result = self.shell("install_display_tools")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("display-guard", unit.read_text())
        self.assertIn("ExecStart=/usr/local/libexec/tarkin/console",
                      unit.with_name("tarkin-console.service.before-v150").read_text())

    def test_session_relay_needs_tarkin_display(self):
        old = self.prefix / "usr/local/bin/tarkin-session"
        old.parent.mkdir(parents=True)
        old.write_text("#!/bin/bash\necho old\n")
        result = self.shell("write_console_files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(old.read_text(), "#!/bin/bash\necho old\n")
        self.assertIn("tarkin-display is missing", result.stderr)
        result = self.shell("install_display_tools; write_console_files")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(old.read_text(), (ROOT / "rootfs/usr/local/bin/tarkin-session").read_text())

    def legacy(self, enabled, active="", owner_file=False):
        self.mock("systemctl", """#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$1" in
  is-enabled) list="$ENABLED" ;;
  is-active) list="$ACTIVE" ;;
  *) exit 0 ;;
esac
for a in "$@"; do [[ " $list " == *" $a "* ]] && exit 0; done
exit 1
""")
        return {"ENABLED": enabled, "ACTIVE": active}

    def test_gdm_from_an_old_stick_is_migrated(self):
        if Path("/etc/tarkin/display-owner").exists() or Path("/etc/systemd/system/display-manager.service").exists():
            self.skipTest("this machine has its own display owner files")
        env = self.legacy("gdm.service", "gdm.service")
        result = self.shell('PREFIX=""; assert_display_owner console; echo "LEGACY=$LEGACY_GDM"', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LEGACY=1", result.stdout)
        result = self.shell('PREFIX=""; SUDO=(echo RUN); DRY_RUN=0; has_console_unit() { :; }; enable_console_display', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RUN systemctl disable gdm.service", result.stdout)
        self.assertIn("RUN rm -f /etc/systemd/system/display-manager.service", result.stdout)
        self.assertIn("/etc/tarkin/display-owner", result.stdout)
        self.assertIn("RUN systemctl enable tarkin-console.service", result.stdout)
        self.assertNotRegex(self.logged(), r"systemctl (stop|start|restart)")

    def test_sddm_or_gdm_request_are_not_migrated(self):
        if Path("/etc/tarkin/display-owner").exists() or Path("/etc/systemd/system/display-manager.service").exists():
            self.skipTest("this machine has its own display owner files")
        env = self.legacy("gdm.service sddm.service")
        result = self.shell('PREFIX=""; assert_display_owner console', **env)
        self.assertNotEqual(result.returncode, 0)
        env = self.legacy("")
        result = self.shell('PREFIX=""; assert_display_owner console; echo "LEGACY=$LEGACY_GDM"', **env)
        self.assertIn("LEGACY=0", result.stdout)

    def test_missing_lock_tools_do_not_stop_the_install(self):
        if any(Path(d, "hypridle").exists() for d in os.environ["PATH"].split(os.pathsep)):
            self.skipTest("hypridle is installed here")
        lua = self.config("lua", "hl.config({})\n")
        result = self.shell('PREFIX=""; SUDO=(echo RUN); install_comfort_files; configure_desktop_extras; echo "READY=$COMFORT_READY"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("READY=0", result.stdout)
        self.assertIn("screen lock (Super+L, idle lock) is skipped", result.stderr)
        self.assertNotIn("tarkin-comfort-start", lua.read_text())
        self.assertIn('hl.bind("F8"', lua.read_text())

    def packages(self, with_gdm):
        self.mock("getent", "#!/bin/bash\nexit 0\n")
        self.mock("df", "#!/bin/bash\nprintf 'F 1 U A C M\\nx 1 1 99999999 1%% /\\n'\n")
        self.mock("pacman", """#!/bin/bash
echo "pacman $*" >> "$CALLS"
case "$1" in
  -Q) exit 1 ;;
  -Si|-Sp|-Syu) exit 0 ;;
  -S) [[ "$*" == *" hyprland "* ]] && exit 1; exit 0 ;;
esac
""")
        for c in ("Hyprland", "start-hyprland", "gcc"):
            if c != "Hyprland":
                self.mock(c, "#!/bin/bash\nexit 0\n")
        path = str(self.bin) + ":/usr/bin:/bin"
        return self.shell('PREFIX=""; SUDO=(); DRY_RUN=0; WITH_GDM=%d; install_packages' % with_gdm, PATH=path)

    def test_one_bad_package_and_missing_gnome_do_not_stop(self):
        if any(Path(d, "gdm").exists() for d in ("/usr/bin", "/bin")):
            self.skipTest("gdm is installed here")
        result = self.packages(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("one by one", result.stderr)
        self.assertIn("gdm is not installed (optional", result.stderr)
        self.assertRegex(self.logged(), r"pacman -S --needed --noconfirm --noprogressbar waybar\n")
        result = self.packages(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gdm is missing after the package step", result.stderr)

    def test_cage_is_in_the_package_list(self):
        self.assertRegex((ROOT / "install-hyprland.sh").read_text(), r"local apps=\([^)]*\bcage\b")


class FirstBoot(Installer):
    def test_installer_records_the_failed_step(self):
        step = self.path / "step"
        result = self.shell('step "GPU driver"; die "No usable libmali found."', TARKIN_STEP_FILE=str(step))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(step.read_text(), "GPU driver\nNo usable libmali found.\n")
        result = self.shell('f() { step "installing packages"; false; echo never; }; f', TARKIN_STEP_FILE=str(step))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("never", result.stdout)
        self.assertEqual(step.read_text(), "installing packages\ncommand failed: false\n")
        result = self.shell('step "a"; x="$(die inner)"', TARKIN_STEP_FILE=str(step))
        self.assertEqual(step.read_text(), "a\ninner\n")
        result = self.shell('step "a"; echo fine')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_main_names_every_step(self):
        text = (ROOT / "install-hyprland.sh").read_text()
        main = text.split("\nmain() {")[1]
        for name in ("checking the system", "installing packages", "GPU driver", "console and display tools",
                     "Hyprland config, keys and screen lock", "display at boot, sound and Bluetooth", "launcher check"):
            self.assertIn('step "%s' % name, main)

    def firstboot(self, script_rc, reason=""):
        root = self.path / "root"
        for d in ("var/lib/tarkin", "var/log", "etc/sudoers.d", "etc/tarkin", "dev/pts", "home/alarm"):
            (root / d).mkdir(parents=True, exist_ok=True)
        (root / "var/lib/tarkin/firstboot.pending").write_text("x\n")
        (root / "etc/tarkin/firstboot.conf").write_text("FIRSTBOOT_REBOOT=0\n")
        (root / "dev/pts/0").write_text("")
        (root / "home/alarm/install-hyprland.sh").write_text(
            'printf "%s\\n%s\\n" "GPU driver (libmali, EGL shim, GPU probes)" "' + reason + '" > "$TARKIN_STEP_FILE"\nexit ' + str(script_rc) + "\n")
        self.mock("id", "#!/bin/bash\necho 1000\n")
        self.mock("getent", '#!/bin/bash\n[[ "$1" == passwd ]] && echo "alarm:x:1000:1000::%s:/bin/bash"\nexit 0\n' % (root / "home/alarm"))
        self.mock("runuser", '#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\nexec "$@"\n')
        self.mock("visudo", "#!/bin/bash\nexit 0\n")
        self.mock("systemctl", '#!/bin/bash\necho "systemctl $*" >> "$CALLS"\n')
        self.mock("sleep", "#!/bin/bash\nexit 0\n")
        self.mock("chown", "#!/bin/bash\nexit 0\n")
        self.mock("stat", "#!/bin/bash\necho alarm\n")
        result = self.run_cmd([LIBEXEC / "firstboot"], TARKIN_ROOT=str(root))
        return root, result

    def test_failure_names_the_step_and_the_command(self):
        root, result = self.firstboot(1, "No usable libmali found. Pass --mali-source /path/libmali.so")
        self.assertEqual(result.returncode, 1)
        lib = root / "var/lib/tarkin"
        reason = (lib / "firstboot.reason").read_text()
        self.assertIn("step=GPU driver (libmali, EGL shim, GPU probes)", reason)
        self.assertIn("reason=No usable libmali found.", reason)
        self.assertIn("fix=fix the cause above, then: sudo systemctl restart tarkin-firstboot", reason)
        self.assertIn("step=GPU driver", (lib / "firstboot.failed").read_text())
        self.assertIn("FAILED at step: GPU driver", (root / "var/log/tarkin-firstboot.log").read_text())
        self.assertIn("First-boot setup FAILED at step: GPU driver", (root / "dev/pts/0").read_text())
        self.assertFalse((root / "etc/sudoers.d/99-tarkin-firstboot").exists())
        notice = (LIBEXEC / "shell-notice").read_text().replace("/var/lib/tarkin", str(lib))
        shown = subprocess.run(["bash", "-c", notice], text=True, capture_output=True).stdout
        self.assertIn("Failed step: GPU driver (libmali, EGL shim, GPU probes)", shown)
        self.assertIn("Reason     : No usable libmali found.", shown)
        self.assertIn("What to do : fix the cause above", shown)

    def test_last_attempt_says_to_run_the_installer(self):
        root = self.path / "root"
        (root / "var/lib/tarkin").mkdir(parents=True)
        (root / "var/lib/tarkin/firstboot.attempts").write_text("2\n")
        root, result = self.firstboot(1)
        lib = root / "var/lib/tarkin"
        self.assertFalse((lib / "firstboot.pending").exists())
        self.assertIn("bash ~/install-hyprland.sh", (lib / "firstboot.reason").read_text())
        notice = (LIBEXEC / "shell-notice").read_text().replace("/var/lib/tarkin", str(lib))
        shown = subprocess.run(["bash", "-c", notice], text=True, capture_output=True).stdout
        self.assertIn("FAILED and stopped retrying", shown)
        self.assertIn("Failed step: GPU driver", shown)

    def test_success_clears_the_reason(self):
        root = self.path / "root"
        (root / "var/lib/tarkin").mkdir(parents=True)
        (root / "var/lib/tarkin/firstboot.reason").write_text("step=old\n")
        root, result = self.firstboot(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lib = root / "var/lib/tarkin"
        self.assertFalse((lib / "firstboot.reason").exists())
        self.assertTrue((lib / "firstboot.done").exists())
        self.assertIn("systemctl --no-block restart tarkin-console.service", self.logged())

    def test_missing_installer_is_explained(self):
        root = self.path / "root"
        root, result = self.firstboot(0)
        (root / "var/lib/tarkin/firstboot.pending").write_text("x\n")
        (root / "home/alarm/install-hyprland.sh").unlink()
        result = self.run_cmd([LIBEXEC / "firstboot"], TARKIN_ROOT=str(root))
        self.assertEqual(result.returncode, 1)
        reason = (root / "var/lib/tarkin/firstboot.reason").read_text()
        self.assertIn("step=finding install-hyprland.sh", reason)
        self.assertIn("is missing", reason)


class Release(unittest.TestCase):
    def test_version(self):
        self.assertEqual((ROOT / "VERSION").read_text().strip(), "1.50")
        for name in ("install-hyprland.sh", "install-gpuapp.sh"):
            self.assertIn("(boot-arch-linux-on-CM1406 v1.50)", (ROOT / name).read_text())
        self.assertIn("## v1.50", (ROOT / "CHANGELOG.md").read_text())

    def test_new_files_have_no_comments(self):
        for f in (BIN / "tarkin-kbd-backlight", BIN / "tarkin-smooth", LIBEXEC / "smooth",
                  ROOT / "rootfs/etc/systemd/system/tarkin-smooth.service"):
            lines = f.read_text().splitlines()
            for line in lines[1:]:
                self.assertFalse(line.lstrip().startswith("#"), (f, line))

    def test_pkgconf_fix_kept(self):
        self.assertRegex((ROOT / "install-gpuapp.sh").read_text(), r"PACKAGES=\([^)]*\bpkgconf\b")

    def test_firefox_gpu_entry_unchanged_and_no_new_gpu_shortcuts(self):
        self.assertIn("Name=Firefox (GPU)", (ROOT / "install-gpuapp.sh").read_text())
        for name in ("install-hyprland.sh", "scripts/install-desktop.sh"):
            text = (ROOT / name).read_text()
            self.assertIsNone(re.search(r"gpuapp kitty|\brofi\b", text), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
