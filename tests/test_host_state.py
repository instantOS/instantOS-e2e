"""Exercise preservation snapshots on an isolated filesystem, without a VM."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'etc').mkdir()

    def snapshot(self):
        return subprocess.check_output(
            ['bash', '-c', 'source "$1"; snapshot_host_config "$2" | LC_ALL=C sort',
             'snapshot', str(ROOT / 'assets/host-state.sh'), str(self.root)], text=True)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_target_setup_files_are_protected(self):
        for name in ('group', 'gshadow', 'vconsole.conf', 'locale.conf', 'locale.gen',
                     'mkinitcpio.conf', 'default/grub'):
            with self.subTest(name=name):
                path = self.write(f'etc/{name}', 'original')
                before = self.snapshot()
                path.write_text('installer change')
                self.assertNotEqual(before, self.snapshot())

    def test_configuration_entries_and_installer_state_are_protected(self):
        for directory in ('pacman.d', 'pacman.d/hooks', 'apt/sources.list.d',
                          'systemd/network', 'sudoers.d', 'instant'):
            with self.subTest(directory=directory):
                before = self.snapshot()
                path = self.write(f'etc/{directory}/added.conf', 'new configuration')
                created = self.snapshot()
                self.assertNotEqual(before, created)
                path.write_text('changed configuration')
                self.assertNotEqual(created, self.snapshot())
                path.unlink()
                self.assertNotEqual(created, self.snapshot())
        before = self.snapshot()
        self.write('var/log/instantos/install.log', 'host installer state')
        self.assertNotEqual(before, self.snapshot())

    def test_symlink_target_and_target_contents_are_protected(self):
        first = self.write('usr/share/zoneinfo/first', 'first timezone')
        second = self.write('usr/share/zoneinfo/second', 'first timezone')
        link = self.root / 'etc/localtime'
        link.symlink_to(first)
        before = self.snapshot()
        link.unlink()
        link.symlink_to(second)
        self.assertNotEqual(before, self.snapshot())
        before = self.snapshot()
        second.write_text('changed timezone')
        self.assertNotEqual(before, self.snapshot())
        second.unlink()
        self.assertIn('symlink  /etc/localtime', self.snapshot())

    def test_unrelated_runtime_changes_are_excluded(self):
        before = self.snapshot()
        self.write('var/log/journal/runtime', 'new log')
        self.write('etc/unrelated', 'outside the protected set')
        self.assertEqual(before, self.snapshot())

    def test_file_permissions_are_protected(self):
        path = self.write('etc/shadow', 'protected')
        before = self.snapshot()
        path.chmod(0o600)
        self.assertNotEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
