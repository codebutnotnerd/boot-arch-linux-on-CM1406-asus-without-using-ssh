import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONSOLE = ROOT / 'rootfs/usr/local/libexec/tarkin/console'
loader = importlib.machinery.SourceFileLoader('widevine_env', str(ROOT / 'rootfs/usr/local/bin/tarkin-firefox-widevine'))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


def console_block(text):
    start = text.index('widevine_gmp_path() {\n')
    end = text.index('if gmp="$(widevine_gmp_path)"; then export MOZ_GMP_PATH="$gmp"; fi\n', start)
    return text[start:end] + 'if gmp="$(widevine_gmp_path)"; then export MOZ_GMP_PATH="$gmp"; fi\n'


class ConsoleWidevineEnvironment(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.skipTest('Needs root-owned fixtures; run only in a disposable worker or container')
        self.tmp = Path(tempfile.mkdtemp(prefix='tarkin_wv_'))
        self.tmp.chmod(0o755)
        self.addCleanup(shutil.rmtree, self.tmp)
        self.env_file = self.tmp / 'etc/environment'
        self.env_file.parent.mkdir()
        self.opt = self.tmp / 'opt/WidevineCdm'
        self.cdm = self.cdm_dir(self.opt / 'firefox/gmp-widevinecdm/system-installed')
        self.block = console_block(CONSOLE.read_text())
        self.assertIn('/etc/environment', self.block)
        self.assertIn('/opt/WidevineCdm/', self.block)
        self.block = self.block.replace('/etc/environment', str(self.env_file)).replace('/opt/WidevineCdm/', str(self.opt) + '/')

    def cdm_dir(self, path):
        path.mkdir(parents=True, exist_ok=True)
        (path / 'manifest.json').write_text(json.dumps({'version': '4.10.2710.0'}))
        (path / 'libwidevinecdm.so').write_bytes(b'fixture, not a proprietary library')
        return path

    def write_env(self, text):
        self.env_file.write_text(text)

    def run_console(self, inherited=None):
        env = {'PATH': '/usr/bin:/bin'}
        if inherited is not None:
            env['MOZ_GMP_PATH'] = inherited
        script = 'set -u\n' + self.block + 'printf "%s" "${MOZ_GMP_PATH-<unset>}"\n'
        result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_helper_written_path_is_exported(self):
        self.write_env('LANG=C.UTF-8\n# keep\n')
        helper.configure_environment(self.cdm, self.env_file)
        self.assertEqual(self.run_console(), str(self.cdm))

    def test_absent_or_unrelated_environment_changes_nothing(self):
        self.assertEqual(self.run_console(), '<unset>')
        self.write_env('LANG=C.UTF-8\n')
        self.assertEqual(self.run_console(), '<unset>')

    def test_invalid_lines_are_ignored(self):
        cases = [
            f'MOZ_GMP_PATH={self.cdm}\n',
            f'export MOZ_GMP_PATH="{self.cdm}"\n',
            f'MOZ_GMP_PATH="{self.cdm}"\nMOZ_GMP_PATH="{self.cdm}"\n',
            f'MOZ_GMP_PATH="{self.cdm}" ; touch /tmp/x\n',
            f'MOZ_GMP_PATH="{self.cdm}/../system-installed"\n',
            'MOZ_GMP_PATH="/usr/lib/firefox/gmp"\n',
            f'MOZ_GMP_PATH="{self.opt}/missing"\n',
            'MOZ_GMP_PATH="$(id)"\n',
        ]
        for text in cases:
            with self.subTest(text=text):
                self.write_env(text)
                self.assertEqual(self.run_console(), '<unset>')

    def test_incomplete_or_writable_cdm_refused(self):
        self.write_env(f'MOZ_GMP_PATH="{self.cdm}"\n')
        (self.cdm / 'libwidevinecdm.so').unlink()
        self.assertEqual(self.run_console(), '<unset>')
        self.cdm_dir(self.cdm)
        self.cdm.chmod(0o775)
        self.assertEqual(self.run_console(), '<unset>')
        self.cdm.chmod(0o757)
        self.assertEqual(self.run_console(), '<unset>')
        self.cdm.chmod(0o755)
        os.chown(self.cdm, 1000, 1000)
        self.assertEqual(self.run_console(), '<unset>')
        os.chown(self.cdm, 0, 0)
        self.assertEqual(self.run_console(), str(self.cdm))

    def test_environment_file_must_be_root_owned_regular_file(self):
        self.write_env(f'MOZ_GMP_PATH="{self.cdm}"\n')
        os.chown(self.env_file, 1000, 1000)
        self.assertEqual(self.run_console(), '<unset>')
        os.chown(self.env_file, 0, 0)
        real = self.tmp / 'etc/environment.real'
        self.env_file.rename(real)
        self.env_file.symlink_to(real)
        self.assertEqual(self.run_console(), '<unset>')

    def test_symlinked_layout_follows_root_owned_target_only(self):
        target = self.cdm_dir(self.tmp / 'usr/lib/widevine')
        link = self.opt / 'firefox/gmp-widevinecdm/linked'
        link.symlink_to(target)
        self.write_env(f'MOZ_GMP_PATH="{link}"\n')
        self.assertEqual(self.run_console(), str(link))
        os.chown(target, 1000, 1000)
        self.assertEqual(self.run_console(), '<unset>')

    def test_inherited_value_is_kept_when_file_invalid(self):
        self.write_env('MOZ_GMP_PATH=unquoted\n')
        self.assertEqual(self.run_console(inherited='/inherited'), '/inherited')

    def test_generated_console_copies_carry_the_same_block(self):
        expected = console_block(CONSOLE.read_text())
        for name in ('install-hyprland.sh', 'scripts/install-desktop.sh'):
            text = (ROOT / name).read_text()
            embedded = text.split("<<'TARKIN_CONSOLE_EOF'\n")[1].split('\nTARKIN_CONSOLE_EOF')[0] + '\n'
            self.assertEqual(console_block(embedded), expected, name)


if __name__ == '__main__':
    unittest.main()
