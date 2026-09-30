"""Exercise real entry points with simulated external commands, without a VM."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, urllib.request
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps([name, args]) + '\n')
if name == 'cargo':
    try:
        os.fstat(8)
    except OSError:
        pass
    else:
        sys.exit('Cargo inherited the suite lock')
    target = pathlib.Path(os.environ['CARGO_TARGET_DIR']) / 'release/ins'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b'this checkouts installer')
elif name == 'sudo':
    if 'rm' in args:
        for arg in args[args.index('rm') + 1:]:
            if arg.startswith('-'): continue
            p = pathlib.Path(arg)
            if p.is_dir(): shutil.rmtree(p)
            elif p.exists(): p.unlink()
elif name == 'qemu-img':
    if os.environ.get('CONVERT_RC'): sys.exit(int(os.environ['CONVERT_RC']))
    if args[0] == 'info': print('{"format":"raw"}')
    else: pathlib.Path(args[-1]).write_bytes(b'raw disk')
elif name == 'docker':
    harness = pathlib.Path(next(args[i+1].removesuffix(':/tests')
        for i, a in enumerate(args[:-1]) if a == '-v' and args[i+1].endswith(':/tests')))
    # The launcher must clear stale results and variables before *each* stage.
    for entry in ('vars.json', 'testresults', 'ulogs', 'raid'):
        if (harness / entry).exists(): sys.exit(90)
    variables = dict(a.split('=', 1) for a in args if '=' in a and not a.startswith('-'))
    if 'E2E_ASSET_URL' in variables:
        url = variables['E2E_ASSET_URL'].replace('10.0.2.2', '127.0.0.1') + '/ins'
        assert urllib.request.urlopen(url).read() == b'this checkouts installer'
    for entry in ('testresults', 'ulogs', 'raid'): (harness / entry).mkdir()
    (harness / 'vars.json').write_text('{}')
    (harness / 'raid/hd1').write_bytes(b'qcow disk')
    (harness / 'testresults/current').write_text('this run')
    rc_key = 'VERIFY_RC' if harness.name == 'verifydisk' else 'INSTALL_RC'
    sys.exit(int(os.environ.get(rc_key, '0')))
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'suite'
        self.repo.mkdir()
        shutil.copy(ROOT / 'run.sh', self.repo)
        shutil.copytree(ROOT / 'tools', self.repo / 'tools')
        # Control only the capability probe; execute the real acceleration
        # selection and both entry points for available/unavailable hosts.
        with (self.repo / 'tools/lib/acceleration.sh').open('a') as f:
            f.write('\nkvm_available() { [ "${TEST_KVM_AVAILABLE:-0}" = 1 ]; }\n')
        for directory in ('assets', 'casedir', 'diag/verifydisk', 'diag/liveiso', 'diag/bootcap'):
            (self.repo / directory).mkdir(parents=True)
        for fixture in ROOT.glob('assets/questions-*.toml'):
            shutil.copy(fixture, self.repo / 'assets')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for command in ('cargo', 'docker', 'sudo', 'qemu-img'):
            p = self.bin / command
            p.write_text(STUB)
            p.chmod(0o755)
        product = self.base / 'product'
        product.mkdir()
        (product / 'Cargo.toml').touch()
        media = self.base / 'media'
        media.mkdir()
        (media / 'archlinux-x86_64.iso').touch()
        (media / 'instantos-offline-latest.iso').touch()
        images = self.base / 'work/images'
        for distro in ('arch', 'ubuntu'):
            bundle = images / f'{distro}-host'
            bundle.mkdir(parents=True)
            for file in ('disk.img', 'vmlinuz', 'initrd.img'):
                (bundle / file).write_text('fixture')
        self.env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}',
                    'CALL_LOG': str(self.base / 'calls.jsonl'),
                    'INSTANTCLI_DIR': str(product), 'CARGO_TARGET_DIR': str(product / 'target'),
                    'E2E_MEDIA_DIR': str(media), 'E2E_WORK_DIR': str(self.base / 'work'),
                    'E2E_IMAGE_DIR': str(images)}
        self.env.pop('E2E_ISO_NAME', None)

    def run_suite(self, *args, **env):
        return subprocess.run(['bash', str(self.repo / 'run.sh'), *args],
                              env={**self.env, **env}, text=True, capture_output=True, timeout=20)

    def run_diagnostic(self, harness, *args, **env):
        return subprocess.run(['bash', str(self.repo / 'tools/run-diagnostic.sh'),
                               harness, *map(str, args)], env={**self.env, **env},
                              text=True, capture_output=True, timeout=20)

    def calls(self, command):
        log = self.base / 'calls.jsonl'
        return [args for name, args in map(json.loads, log.read_text().splitlines())
                if name == command] if log.exists() else []

    def stale(self, directory):
        directory = self.repo / directory
        (directory / 'vars.json').write_text('{"stale":true}')
        for name in ('raid', 'ulogs', 'testresults'):
            (directory / name).mkdir()
            (directory / name / 'stale').touch()

    def test_host_full_needs_no_iso_and_resets_both_stages(self):
        self.stale('casedir')
        self.stale('diag/verifydisk')
        result = self.run_suite('--flow', 'host-arch', 'QEMUCPUS=3', 'QEMURAM=2048',
                                E2E_MEDIA_DIR='/does/not/exist')
        self.assertEqual(result.returncode, 0, result.stderr)
        launches = self.calls('docker')
        self.assertEqual(len(launches), 2)
        self.assertFalse(any(a.startswith('BOOTFROM=') for a in launches[0]))
        self.assertIn('QEMUCPUS=3', launches[1])
        self.assertIn('QEMURAM=2048', launches[1])
        self.assertIn('E2E_TARGET_DISK=/dev/vda', launches[1])
        self.assertFalse(any(a.startswith(('KERNEL=', 'INITRD=', 'APPEND=', 'iso=')) for a in launches[1]))
        self.assertEqual(len(self.calls('cargo')), 1)
        self.assertEqual(len(self.calls('qemu-img')), 1)

    def test_host_smoke_and_ubuntu_never_boot_a_second_stage(self):
        for args in (('--flow', 'host-arch', '--smoke'), ('--flow', 'host-ubuntu')):
            with self.subTest(args=args):
                (self.base / 'calls.jsonl').unlink(missing_ok=True)
                result = self.run_suite(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls('docker')), 1)
                self.assertFalse(self.calls('qemu-img'))

    def test_install_failure_stops_before_conversion(self):
        self.stale('diag/verifydisk')
        result = self.run_suite('--flow', 'host-arch', INSTALL_RC='7')
        self.assertEqual(result.returncode, 7)
        self.assertFalse(self.calls('qemu-img'))
        self.assertTrue((self.repo / 'casedir/testresults/current').exists())
        self.assertTrue(self.calls('sudo'))
        self.assertFalse((self.repo / 'diag/verifydisk/testresults').exists())

    def test_variable_names_are_case_normalized(self):
        result = self.run_suite('--flow', 'offline', 'qemucpus=3')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.calls('docker')[0]
        self.assertIn('QEMUCPUS=3', args)
        self.assertNotIn('QEMUCPUS=8', args)

    def test_login_credential_comes_from_the_selected_fixture(self):
        fixture = self.repo / 'assets/questions-full.toml'
        fixture.write_text(fixture.read_text().replace('correct-horse-battery-staple', 'changed-fixture-password'))
        result = self.run_suite('--flow', 'offline', '--profile', 'full')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASSWORD=changed-fixture-password', self.calls('docker')[0])

    def test_encryption_credential_is_independent_from_login(self):
        fixture = self.repo / 'assets/questions-encrypted.toml'
        fixture.write_text(fixture.read_text().replace(
            'EncryptionPassword = "correct-horse-battery-staple"',
            'EncryptionPassword = "encryption-only"'))
        result = self.run_suite('--flow', 'offline', '--profile', 'encrypted')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ENCRYPTION_PASSWORD=encryption-only', self.calls('docker')[0])
        self.assertIn('PASSWORD=correct-horse-battery-staple', self.calls('docker')[0])
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        result = self.run_diagnostic('verifydisk', disk, '--profile', 'encrypted',
                                     'ENCRYPTION_PASSWORD=preserved-disk-password')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ENCRYPTION_PASSWORD=preserved-disk-password', self.calls('docker')[-1])

    def test_invalid_fixture_stops_before_launch(self):
        (self.repo / 'assets/questions-minimal.toml').write_text('invalid toml = [')
        result = self.run_suite('--flow', 'offline')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls('docker'))

    def test_dangling_cargo_cache_symlink_is_created_at_its_target(self):
        link = self.base / 'target-link'
        cache = self.base / 'new-cache'
        link.symlink_to(cache, target_is_directory=True)
        result = self.run_suite('--smoke', CARGO_TARGET_DIR=str(link))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((cache / 'release/ins').is_file())

    def test_host_bundle_cannot_be_replaced_during_a_run(self):
        import fcntl
        lock_path = Path(self.env['E2E_IMAGE_DIR']) / '.arch-host.lock'
        with open(lock_path, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_suite('--flow', 'host-arch')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('being rebuilt', result.stderr)
        self.assertFalse(self.calls('docker'))

    def test_verification_failure_is_returned(self):
        result = self.run_suite('--flow', 'host-arch', VERIFY_RC='8')
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertEqual(len(self.calls('docker')), 2)

    def test_conversion_failure_is_returned(self):
        result = self.run_suite('--flow', 'host-arch', CONVERT_RC='9')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(len(self.calls('docker')), 1)

    def test_offline_is_networkless_and_has_no_build_or_asset_server(self):
        result = self.run_suite('--flow', 'offline', INSTANTCLI_DIR='/absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.calls('docker')[0]
        self.assertIn('OFFLINE_SUT=1', args)
        self.assertIn('E2E_INSTALLER=shipped', args)
        self.assertFalse(any(a.startswith('E2E_ASSET_URL=') for a in args))
        self.assertFalse(self.calls('cargo'))

    def test_release_skips_checkout_build(self):
        result = self.run_suite('--release', INSTANTCLI_DIR='/absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('E2E_INSTALLER=release', self.calls('docker')[0])
        self.assertFalse(self.calls('cargo'))

    def test_invalid_scenarios_and_structural_overrides_fail_before_launch(self):
        for args in (('--flow', 'unknown'), ('--flow', 'host-arch', '--profile', 'full'),
                     ('--flow', 'offline', '--release'), ('E2E_FLOW=host-arch',),
                     ('OFFLINE_SUT=0',), ('PASSWORD=wrong',), ('HDD_1=other',), ('--flow',)):
            with self.subTest(args=args):
                result = self.run_suite(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.calls('docker'))

    def test_diagnostic_resets_stale_state(self):
        self.stale('diag/verifydisk')
        disk = self.base / 'installed.raw'
        disk.write_text('disk')
        result = subprocess.run(['bash', str(self.repo / 'tools/run-diagnostic.sh'),
                                 'verifydisk', str(disk), '--profile', 'encrypted'],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('E2E_PROFILE=encrypted', self.calls('docker')[0])

    def test_diagnostic_rejects_inputs_that_cleanup_would_delete(self):
        for harness in ('verifydisk', 'bootcap'):
            for state in ('raid', 'testresults', 'ulogs'):
                with self.subTest(harness=harness, state=state):
                    directory = self.repo / 'diag' / harness / state
                    directory.mkdir(exist_ok=True)
                    disk = directory / 'preserved.raw'
                    disk.write_bytes(b'preserved disk')
                    # Resolve symlinks too: an external-looking input can still
                    # refer to a file inside the harness's cleanup directories.
                    alias = self.base / 'input.raw'
                    alias.unlink(missing_ok=True)
                    alias.symlink_to(disk)
                    for input_path in (disk, alias):
                        result = self.run_diagnostic(harness, input_path)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('would be deleted', result.stderr)
                        self.assertEqual(disk.read_bytes(), b'preserved disk')
                        self.assertFalse(self.calls('docker'))
                        self.assertFalse(self.calls('sudo'))

    def test_diagnostic_accepts_disk_outside_cleanup_directories(self):
        disk = self.repo / 'diag/verifydisk/raid-preserved/input.raw'
        disk.parent.mkdir()
        disk.write_bytes(b'preserved disk')
        self.stale('diag/verifydisk')
        result = self.run_diagnostic('verifydisk', disk)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(disk.read_bytes(), b'preserved disk')
        self.assertEqual(len(self.calls('docker')), 1)

    def test_shared_overrides_are_normalized_by_both_runners(self):
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        overrides = ('qemucpus=3', 'qemuram=2048', 'hddsizegb=24',
                     'storage_keep_free_gb=5')
        for run in (lambda: self.run_suite('--flow', 'offline', *overrides),
                    lambda: self.run_diagnostic('verifydisk', disk, *overrides)):
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            for override in overrides:
                key, value = override.split('=', 1)
                self.assertIn(f'{key.upper()}={value}', self.calls('docker')[-1])

    def test_unsupported_overrides_fail_in_both_runners(self):
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        for override in ('NUMDISKS=2', 'NICMODEL=e1000', 'KERNEL=other',
                         'INITRD=other', 'APPEND=other', 'QEMU_EXTRA_ARGS=other',
                         'UNKNOWN=1', 'UEFI=1', 'bad-name=1'):
            with self.subTest(override=override):
                for result in (self.run_suite('--flow', 'offline', override),
                               self.run_diagnostic('verifydisk', disk, override)):
                    self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.calls('docker'))

    def test_diagnostic_context_exceptions(self):
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        for harness in ('verifydisk', 'bootcap'):
            result = self.run_diagnostic(harness, disk, 'password=custom')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASSWORD=custom', self.calls('docker')[-1])
        result = self.run_diagnostic('liveiso', 'uefi=1',
                                     E2E_ISO_NAME='instantos-offline-latest.iso')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('UEFI=1', self.calls('docker')[-1])
        result = self.run_diagnostic('liveiso', 'PASSWORD=custom')
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_acceleration_selection_in_both_runners(self):
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        for available, flags, expected_kvm in (
            ('0', (), False), ('1', (), True), ('1', ('--tcg',), False),
            ('1', ('--kvm',), True), ('0', ('--tcg',), False),
        ):
            with self.subTest(available=available, flags=flags):
                results = (
                    self.run_suite('--flow', 'offline', *flags, TEST_KVM_AVAILABLE=available),
                    self.run_diagnostic('verifydisk', disk, *flags, TEST_KVM_AVAILABLE=available),
                )
                for result, args in zip(results, self.calls('docker')[-2:]):
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual('/dev/kvm' in args, expected_kvm)
                    self.assertEqual('qemu_no_kvm=1' in args, not expected_kvm)

    def test_explicit_kvm_fails_before_launch_when_unavailable(self):
        disk = self.base / 'installed.raw'
        disk.write_bytes(b'disk')
        for result in (self.run_suite('--flow', 'offline', '--kvm'),
                       self.run_diagnostic('verifydisk', disk, '--kvm')):
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('KVM requested', result.stderr)
        self.assertFalse(self.calls('docker'))

    def test_host_verification_preserves_selected_acceleration(self):
        result = self.run_suite('--flow', 'host-arch', TEST_KVM_AVAILABLE='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('docker')), 2)
        for args in self.calls('docker'):
            self.assertIn('/dev/kvm', args)
            self.assertNotIn('qemu_no_kvm=1', args)

    def test_lock_prevents_concurrent_runs(self):
        import fcntl
        with open(self.repo / '.e2e.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_suite('--flow', 'offline')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Another VM run', result.stderr)
        self.assertFalse(self.calls('docker'))


if __name__ == '__main__':
    unittest.main()
