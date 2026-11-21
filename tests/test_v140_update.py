import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'rootfs/usr/local/bin'
loader = importlib.machinery.SourceFileLoader('widevine', str(BIN / 'tarkin-firefox-widevine'))
spec = importlib.util.spec_from_loader(loader.name, loader)
w = importlib.util.module_from_spec(spec)
loader.exec_module(w)


def cdm(path, version='4.10.2710.0'):
    path.mkdir(parents=True, exist_ok=True)
    (path / 'manifest.json').write_text(json.dumps({'version': version}))
    (path / 'libwidevinecdm.so').write_bytes(b'test fixture, not a proprietary library')
    return path


class Updater(unittest.TestCase):
    def invoke(self, status=0, listing=None, query_status=0, args=()):
        if os.geteuid() != 0:
            self.skipTest('Root-only updater tested in isolated worker; do not sudo this test suite on a live host')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            listing = listing if listing is not None else ('local-cm1406 /usr/lib/modules/6.6-test/kernel/foo.ko\n'
                'my-headers /usr/src/linux-tarkin/include/foo.h\nordinary /usr/share/doc/readme\n')
            (path / 'files').write_text(listing)
            (path / 'pacman').write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$LOG"\n'
                'if [[ $1 == -Ql ]]; then cat "$FILES"; exit "$QUERY_STATUS"; fi\nexit "$STATUS"\n')
            (path / 'pacman').chmod(0o755)
            env = dict(os.environ, PATH=f'{path}:/usr/bin:/bin', LOG=str(path / 'log'), FILES=str(path / 'files'), STATUS=str(status), QUERY_STATUS=str(query_status))
            result = subprocess.run(['bash', str(BIN / 'tarkin-update'), *args], env=env, text=True, capture_output=True)
            log = (path / 'log').read_text() if (path / 'log').exists() else ''
            return result, log

    def test_custom_package_owners_and_interactive_full_upgrade(self):
        result, log = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-Syu --ignore linux,linux-*,linux-aarch64,linux-aarch64-headers,local-cm1406,my-headers', log)
        self.assertNotIn('ordinary', log)
        self.assertNotIn('--noconfirm', log)
        self.assertNotIn('--overwrite', log)
        self.assertNotIn('--force', log)

    def test_pacman_status_propagated(self):
        result, _ = self.invoke(status=37)
        self.assertEqual(result.returncode, 37)
        self.assertIn('pacman exit 37', result.stderr)
        self.assertNotIn('completed', result.stdout)

    def test_query_failure_aborts(self):
        result, log = self.invoke(query_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('-Syu', log)

    def test_no_options(self):
        result, log = self.invoke(args=('--noconfirm',))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(log, '')

    def test_legacy_paths_and_images(self):
        result, log = self.invoke(listing='legacy-kernel /lib/modules/old/foo.ko\ncustom-image /boot/Image\n')
        self.assertEqual(result.returncode, 0)
        self.assertIn('custom-image,legacy-kernel', log)


class Widevine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = cdm(self.root / 'system-installed')
        self.profile = self.root / 'profile'
        self.profile.mkdir()

    def test_dereferences_and_uses_manifest_version(self):
        lib = self.source / 'libwidevinecdm.so'
        lib.rename(self.source / 'real-library')
        lib.symlink_to('real-library')
        w.copy_profile(self.profile, self.source)
        target = self.profile / 'gmp-widevinecdm/4.10.2710.0'
        self.assertTrue((target / 'libwidevinecdm.so').is_file())
        self.assertFalse((target / 'libwidevinecdm.so').is_symlink())

    def test_same_or_newer_never_replaced(self):
        for version in ('4.10.2710.0', '4.10.9999.0', '5.0'):
            with self.subTest(version=version):
                profile = self.profile / version
                profile.mkdir()
                target = cdm(profile / 'gmp-widevinecdm' / version, version)
                marker = target / 'keep'
                marker.write_text('keep')
                before = (target / 'manifest.json').read_bytes()
                w.copy_profile(profile, self.source)
                self.assertFalse((profile / 'gmp-widevinecdm/4.10.2710.0').exists()) if version != '4.10.2710.0' else None
                self.assertEqual((target / 'manifest.json').read_bytes(), before)
                self.assertTrue(marker.exists())

    def test_incomplete_target_fails_without_deletion(self):
        target = self.profile / 'gmp-widevinecdm/4.10.2710.0'
        target.mkdir(parents=True)
        (target / 'keep').touch()
        with self.assertRaises(w.SetupError):
            w.copy_profile(self.profile, self.source)
        self.assertTrue((target / 'keep').exists())

    def test_invalid_newer_does_not_block_valid_source(self):
        target = self.profile / 'gmp-widevinecdm/9.0'
        target.mkdir(parents=True)
        w.copy_profile(self.profile, self.source)
        self.assertTrue((self.profile / 'gmp-widevinecdm/4.10.2710.0/manifest.json').exists())

    def test_environment_idempotent_preserves_other_keys(self):
        env = self.root / 'environment'
        env.write_text('# retained\nOTHER=yes\nMOZ_GMP_PATH=old\nexport MOZ_GMP_PATH=older\n')
        w.configure_environment(self.source, env)
        w.configure_environment(self.source, env)
        text = env.read_text()
        self.assertEqual(text.count('MOZ_GMP_PATH='), 1)
        self.assertIn('OTHER=yes', text)
        self.assertIn('# retained', text)
        self.assertIn(str(self.source), text)

    def test_profiles_ini_and_installs_ini_and_new_profile(self):
        base = self.root / '.mozilla/firefox'
        base.mkdir(parents=True)
        (base / 'p1').mkdir()
        (base / 'profiles.ini').write_text('[Profile0]\nPath=p1\nIsRelative=1\n')
        self.assertEqual(w.profiles(self.root), [(base / 'p1').resolve()])
        (base / 'p2').mkdir()
        (base / 'installs.ini').write_text('[InstallABC]\nDefault=p2\n')
        self.assertEqual(len(w.profiles(self.root)), 2)
        for p in w.profiles(self.root):
            w.copy_profile(p, self.source)
            self.assertTrue((p / 'gmp-widevinecdm/4.10.2710.0').is_dir())

    def test_missing_profile_visible(self):
        base = self.root / '.mozilla/firefox'
        base.mkdir(parents=True)
        (base / 'profiles.ini').write_text('[Profile0]\nPath=missing\n')
        with self.assertRaisesRegex(w.SetupError, 'profile is missing'):
            w.profiles(self.root)

    def test_manifest_discovery_from_package_not_hardcoded_version(self):
        source = cdm(self.root / 'firefox/new-layout', '4.11.1.9')
        with patch.object(w, 'run', return_value=subprocess.CompletedProcess([], 0, f'widevine {source}/manifest.json\n')):
            self.assertEqual(w.installed_source(), (source, '4.11.1.9'))

    def test_missing_package_propagates_failure(self):
        with patch.object(w, 'run', side_effect=subprocess.CalledProcessError(1, ['pacman'])):
            with self.assertRaises(subprocess.CalledProcessError):
                w.installed_source()

    def test_build_revision_must_be_full_sha(self):
        with patch.object(w, 'run') as run:
            with self.assertRaises(w.SetupError):
                w.build(self.root, 'main')
            run.assert_not_called()

    def test_build_refuses_dirty_and_wrong_revision(self):
        (self.root / 'PKGBUILD').touch()
        for head, dirty in [('b' * 40, ''), ('a' * 40, ' M PKGBUILD')]:
            with patch.object(w, 'run', side_effect=[subprocess.CompletedProcess([], 0, head), subprocess.CompletedProcess([], 0, dirty)]) as run:
                with self.assertRaises(w.SetupError):
                    w.build(self.root, 'a' * 40)
                self.assertEqual(run.call_count, 2)

    def test_build_order_interactive_checks_and_no_elevated_makepkg(self):
        (self.root / 'PKGBUILD').touch()
        with patch.object(w, 'run', side_effect=[subprocess.CompletedProcess([], 0, 'a' * 40), subprocess.CompletedProcess([], 0, ''), None, None, None, None]) as run:
            w.build(self.root, 'a' * 40)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[2], ['/usr/bin/sudo', '/usr/local/bin/tarkin-update'])
            self.assertEqual(commands[-2:], [['/usr/bin/makepkg', '--verifysource'], ['/usr/bin/makepkg', '-si']])
            self.assertFalse(any('--noconfirm' in command for command in commands))

    def test_root_cannot_build_or_configure_profiles(self):
        with patch.object(w.os, 'geteuid', return_value=0), patch.object(w.sys, 'argv', ['helper']), patch.object(w, 'installed_source') as source:
            with self.assertRaisesRegex(w.SetupError, 'without sudo'):
                w.main()
            source.assert_not_called()

    def test_update_failure_prevents_build(self):
        (self.root / 'PKGBUILD').touch()
        with patch.object(w, 'run', side_effect=[subprocess.CompletedProcess([], 0, 'a' * 40), subprocess.CompletedProcess([], 0, ''), subprocess.CalledProcessError(37, ['tarkin-update'])]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                w.build(self.root, 'a' * 40)
            self.assertEqual(run.call_count, 3)


if __name__ == '__main__':
    unittest.main()
