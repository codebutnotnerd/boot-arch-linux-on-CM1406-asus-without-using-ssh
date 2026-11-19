#!/usr/bin/env python3
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tarkin-display-test-")
        self.root = Path(self.tmp.name)
        self.root.chmod(0o755)
        for name in ("bash", "cat", "mkdir", "flock", "readlink", "grep", "cp", "rm",
                     "mktemp", "sed", "chmod", "mv", "ln", "df", "awk", "id", "date"):
            binary = Path(shutil.which(name)).resolve()
            dest = self.root / "usr/bin" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary, dest)
            linked = subprocess.run(["ldd", str(binary)], capture_output=True, text=True).stdout
            for lib in re.findall(r"(/[^\s()]+)", linked):
                src = Path(lib)
                if src.is_file():
                    target = self.root / str(src).lstrip("/")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, target)
        (self.root / "bin").symlink_to("usr/bin")
        self.write("/dev/null", "")
        os.chmod(self.root / "dev/null", 0o666)
        for name in ("tarkin-display", "tarkin-session"):
            self.write("/usr/local/bin/" + name,
                       (REPO / "rootfs/usr/local/bin" / name).read_text(), 0o755)
        self.write("/usr/local/libexec/tarkin/console",
                   (REPO / "rootfs/usr/local/libexec/tarkin/console").read_text(), 0o755)
        self.write("/usr/local/libexec/tarkin/display-guard",
                   (REPO / "rootfs/usr/local/libexec/tarkin/display-guard").read_text(), 0o755)
        self.write("/install-xfce.sh", (REPO / "install-xfce.sh").read_text(), 0o755)
        self.write("/etc/systemd/system/tarkin-console.service", "[Service]\n")
        for unit in ("sddm.service", "gdm.service", "multi-user.target", "graphical.target"):
            self.write("/usr/lib/systemd/system/" + unit, "[Unit]\n")
        for cmd in ("cage", "foot", "Hyprland", "Xorg", "sddm", "xfce4-session", "startxfce4"):
            self.write("/usr/bin/" + cmd, "#!/bin/bash\nexit 0\n", 0o755)
        self.write("/etc/tarkin/console.env", "TARKIN_SESSION=desktop\nXKB_DEFAULT_LAYOUT=fr\nTARKIN_HYPR_RENDER=gpu\n")
        self.write("/etc/sddm.conf.d/90-tarkin-xfce.conf", "[General]\nDisplayServer=x11\n")
        self.write("/var/lib/sddm/state.conf", "[Last]\nSession=/usr/share/xsessions/xfce.desktop\n")
        self.write("/usr/share/xsessions/xfce.desktop", "[Desktop Entry]\nExec=startxfce4\n")
        self.write("/etc/passwd", "alarm:x:1000:1000::/home/alarm:/bin/bash\n")
        self.write("/calls", "", 0o666)
        self.write("/usr/bin/systemctl", """#!/bin/bash
echo "systemctl $*" >> /calls
case "$1" in
 show) cat /mock-state ;;
 is-active|is-enabled)
   file=/mock-active
   [[ "$1" != is-enabled ]] || file=/mock-enabled
   shift
   [[ -f "$file" ]] || exit 1
   for arg in "$@"; do
     [[ "$arg" == --* ]] || { grep -Fxq "$arg" "$file" && exit 0; }
   done
   exit 1 ;;
 daemon-reload) [[ ! -e /mock-reload-fail ]] ;;
 *) echo "FORBIDDEN systemctl mutation: $*" >&2; exit 99 ;;
esac
""", 0o755)
        self.write("/mock-state", "inactive\n")
        self.link("/etc/systemd/system/multi-user.target.wants/tarkin-console.service",
                  "/etc/systemd/system/tarkin-console.service")
        self.link("/etc/systemd/system/default.target", "/usr/lib/systemd/system/multi-user.target")
        self.write("/usr/bin/sudo", """#!/bin/bash
echo "sudo $*" >> /calls
case "$1" in
 -v|sysctl) exit 0 ;;
 tarkin-update) [[ ! -e /mock-update-fail ]] ;;
 pacman) [[ ! -e /mock-pacman-fail ]] ;;
 *) echo "FORBIDDEN sudo mutation: $*" >&2; exit 99 ;;
esac
""", 0o755)
        self.write("/usr/bin/pacman", "#!/bin/bash\nexit 99\n", 0o755)
        self.write("/usr/bin/tarkin-update", "#!/bin/bash\nexit 99\n", 0o755)
        self.write("/usr/bin/df", "#!/bin/bash\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 99999999 1 99999998 1%% /\\n'\n", 0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text, mode=0o644):
        dest = self.root / name.lstrip("/")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        dest.chmod(mode)

    def link(self, name, target):
        dest = self.root / name.lstrip("/")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.unlink(missing_ok=True)
        dest.symlink_to(target)

    def run_target(self, *args, user=False, ok=True):
        cmd = [shutil.which("chroot")]
        if user:
            cmd += ["--userspec=1000:1000"]
        result = subprocess.run(cmd + [str(self.root), "/bin/bash", *args],
                                capture_output=True, text=True,
                                env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/home/alarm"})
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def read(self, name):
        return (self.root / name.lstrip("/")).read_text()

    def snapshot(self):
        result = {}
        for directory in ("etc",):
            for path in sorted((self.root / directory).rglob("*")):
                if path.is_symlink():
                    result[str(path.relative_to(self.root))] = ("link", os.readlink(path))
                elif path.is_file():
                    result[str(path.relative_to(self.root))] = ("file", path.read_bytes())
        return result

    def select(self, mode, ok=True):
        return self.run_target("/usr/local/bin/tarkin-display", mode, ok=ok)

    def test_round_trip_and_no_live_handoff(self):
        original = self.read("/etc/tarkin/console.env")
        for mode in ("xfce", "terminal", "hyprland", "xfce", "xfce"):
            self.select(mode)
            self.assertEqual(self.read("/etc/tarkin/display-owner").strip(), mode)
            alias = self.root / "etc/systemd/system/display-manager.service"
            console = self.root / "etc/systemd/system/multi-user.target.wants/tarkin-console.service"
            self.assertEqual(alias.is_symlink(), mode == "xfce")
            self.assertEqual(console.is_symlink(), mode != "xfce")
            if mode != "xfce":
                self.assertIn("XKB_DEFAULT_LAYOUT=fr", self.read("/etc/tarkin/console.env"))
                self.assertIn("TARKIN_HYPR_RENDER=gpu", self.read("/etc/tarkin/console.env"))
        self.assertEqual(sorted(original.splitlines()), sorted(self.read("/etc/tarkin/console.env").splitlines()))
        self.assertNotRegex(self.read("/calls"), r"systemctl (start|stop|restart|isolate)")

    def test_pending_failed_and_running_firstboot(self):
        for marker in ("pending", "failed"):
            self.write("/var/lib/tarkin/firstboot." + marker, "")
            before = self.snapshot()
            for mode in ("xfce", "terminal", "hyprland"):
                self.select(mode, ok=False)
                self.assertEqual(before, self.snapshot())
            (self.root / ("var/lib/tarkin/firstboot." + marker)).unlink()
        self.write("/mock-state", "activating\n")
        self.select("xfce", ok=False)

    def test_unfamiliar_alias_even_dangling(self):
        for target in ("/usr/lib/systemd/system/lightdm.service", "/custom/sddm.service"):
            self.link("/etc/systemd/system/display-manager.service", target)
            before = self.snapshot()
            for mode in ("xfce", "hyprland", "terminal"):
                self.select(mode, ok=False)
                self.assertEqual(before, self.snapshot())

    def test_regular_alias_and_custom_wants_refused(self):
        self.write("/etc/systemd/system/display-manager.service", "[Service]\n")
        self.select("xfce", ok=False)
        (self.root / "etc/systemd/system/display-manager.service").unlink()
        self.link("/etc/systemd/system/graphical.target.wants/sddm.service", "/custom/sddm.service")
        self.select("xfce", ok=False)

    def test_gdm_return_and_legacy_fallback(self):
        self.link("/etc/systemd/system/display-manager.service", "/usr/lib/systemd/system/gdm.service")
        self.link("/etc/systemd/system/graphical.target.wants/gdm.service", "/usr/lib/systemd/system/gdm.service")
        self.select("terminal")
        self.assertFalse((self.root / "etc/systemd/system/graphical.target.wants/gdm.service").is_symlink())
        self.write("/mock-enabled", "tarkin-dm-fallback.service\n")
        self.select("xfce", ok=False)

    def test_missing_components_and_wrong_session(self):
        for name in ("usr/bin/Xorg", "usr/bin/cage", "usr/share/xsessions/xfce.desktop"):
            p = self.root / name
            text = p.read_text()
            p.unlink()
            before = self.snapshot()
            self.select("xfce", ok=False)
            self.assertEqual(before, self.snapshot())
            self.write("/" + name, text, 0o755)
        self.write("/usr/share/xsessions/xfce.desktop", "Exec=something-else\n")
        self.select("xfce", ok=False)

    def test_config_overrides_refused(self):
        for name in ("/etc/sddm.conf", "/etc/sddm.conf.d/99-other.conf"):
            self.write(name, "[General]\nDisplayServer=wayland\n")
            self.select("xfce", ok=False)
            (self.root / name.lstrip("/")).unlink()

    def test_rollback_on_reload_failure(self):
        before = self.snapshot()
        self.write("/mock-reload-fail", "")
        result = self.select("xfce", ok=False)
        self.assertIn("restoring", result.stderr)
        after = {k: v for k, v in self.snapshot().items() if ".display-backup." not in k}
        self.assertEqual(before, after)
        self.assertNotIn("Prepared xfce", result.stdout)

    def test_failed_start_and_active_black_no_automatic_claim(self):
        self.select("xfce")
        for state in ("sddm.service\n", ""):
            self.write("/mock-active", state)
            self.select("terminal")
            self.assertIn("TARKIN_SESSION=terminal", self.read("/etc/tarkin/console.env"))
            self.select("xfce")
        self.assertNotRegex(self.read("/calls"), r"systemctl (start|stop|restart)")

    def test_generated_copies_identical_and_guard_refuses_alias(self):
        console = self.read("/usr/local/libexec/tarkin/console")
        session = self.read("/usr/local/bin/tarkin-session")
        for name in ("install-hyprland.sh", "scripts/install-desktop.sh"):
            text = (REPO / name).read_text()
            for label, expected in (("TARKIN_CONSOLE_EOF", console), ("TARKIN_SESSION_EOF", session)):
                embedded = text.split("<<'" + label + "'\n")[1].split("\n" + label)[0] + "\n"
                self.assertEqual(expected, embedded)
        self.select("xfce")
        result = self.run_target("/usr/local/libexec/tarkin/console", ok=False)
        self.assertIn("owns or reserves", result.stderr)
        self.run_target("/usr/local/libexec/tarkin/display-guard", ok=False)
        self.assertIn("ExecCondition=/usr/local/libexec/tarkin/display-guard",
                      (REPO / "rootfs/etc/systemd/system/tarkin-console.service").read_text())
        self.run_target("/usr/local/bin/tarkin-session", "terminal")
        self.assertIn("TARKIN_SESSION=terminal", self.read("/etc/tarkin/console.env"))
        self.run_target("/usr/local/libexec/tarkin/display-guard")

    def test_installer_failure_paths_never_select_display(self):
        for marker in ("/mock-update-fail", "/mock-pacman-fail"):
            self.write(marker, "")
            self.write("/calls", "", 0o666)
            before = self.snapshot()
            self.run_target("/install-xfce.sh", user=True, ok=False)
            self.assertEqual(before, self.snapshot())
            calls = self.read("/calls")
            self.assertIn("sudo tarkin-update\n", calls)
            self.assertEqual("sudo pacman" in calls, marker == "/mock-pacman-fail")
            self.assertNotIn("tarkin-display ", calls)
            (self.root / marker.lstrip("/")).unlink()
        self.run_target("/install-xfce.sh", ok=False)
        (self.root / "usr/bin/tarkin-update").unlink()
        self.run_target("/install-xfce.sh", user=True, ok=False)

    def test_hyprland_and_gdm_owner_preflight(self):
        text = (REPO / "install-hyprland.sh").read_text()
        helper = text.split("assert_display_owner() {")[1].split("\nenable_console_display()")[0]
        self.write("/preflight", 'die() { echo "$*" >&2; exit 1; }\nPREFIX=""\nassert_display_owner() {' + helper + '\nassert_display_owner "$1"\n', 0o755)
        self.run_target("/preflight", "console")
        self.select("xfce")
        for mode in ("console", "gdm"):
            self.run_target("/preflight", mode, ok=False)
        self.select("hyprland")
        self.run_target("/preflight", "gdm")
        self.link("/etc/systemd/system/display-manager.service", "/custom/gdm.service")
        self.run_target("/preflight", "gdm", ok=False)

    def test_installer_missing_component_after_package_success(self):
        (self.root / "usr/bin/Xorg").unlink()
        result = self.run_target("/install-xfce.sh", user=True, ok=False)
        self.assertIn("Xorg is missing after package install", result.stderr)
        self.assertIn("sudo tarkin-update\n", self.read("/calls"))
        self.assertIn("sudo pacman -S", self.read("/calls"))
        self.assertFalse((self.root / "etc/tarkin/display-owner").exists())

    def test_installer_firstboot_guard_before_update(self):
        self.write("/var/lib/tarkin/firstboot.pending", "")
        result = self.run_target("/install-xfce.sh", user=True, ok=False)
        self.assertIn("First boot is pending", result.stderr)
        self.assertNotIn("sudo tarkin-update", self.read("/calls"))

    def test_service_guard_for_active_or_enabled_dm_without_alias(self):
        for name in ("/mock-active", "/mock-enabled"):
            for dm in ("gdm.service", "sddm.service"):
                self.write(name, dm + "\n")
                self.run_target("/usr/local/libexec/tarkin/display-guard", ok=False)
                self.run_target("/usr/local/libexec/tarkin/console", ok=False)
            (self.root / name.lstrip("/")).unlink()


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Use a disposable worker and sudo python3 tests/test-display.py; mock chroot requires root.")
    unittest.main(verbosity=2)
