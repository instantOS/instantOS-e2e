"""Expected failures must never conceal infrastructure or preservation failures."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('classifier', ROOT / 'tools/classify_ubuntu_failure.py')
classifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(classifier)


class UbuntuFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.json('vars.json', {'E2E_FLOW': 'host-ubuntu', 'E2E_TARGET_DISK': '/dev/vdb'})
        self.json('autoinst-status.json', {'status': 'finished'})
        self.json('testresults/test_order.json', [{'name': 'host_boot'}, {'name': 'host_install'}])
        self.json('testresults/result-host_boot.json', {'result': 'ok', 'details': []})
        self.json('testresults/result-host_install.json', {'result': 'fail', 'details': [
            {'result': 'fail', 'title': 'Failed', 'text': 'failure.txt'}]})
        self.text('testresults/failure.txt', '# Test died: /dev/vdb is no longer blank\n--- # stack trace\n')
        for phase in ('pre', 'dryrun', 'post'):
            self.text(f'ulogs/{phase}-host-config.sha', 'unchanged protected configuration\n')
        self.text('ulogs/dryrun.log', 'DRYRUN_RC=0\n')
        self.text('ulogs/install.log', 'Warning: You appear to be running on ubuntu\n'
                  'Failed to read /etc/pacman.conf\nNo such file or directory (os error 2)\n'
                  'INSTALL_RC=1\n')

    def text(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def json(self, name, value):
        self.text(name, json.dumps(value))

    def known(self, rc=101):
        return classifier.known_ubuntu_gap(self.root, rc)

    def test_only_the_documented_gap_is_recognized(self):
        self.assertTrue(self.known())
        for rc in (0, 1, 2, 125, 130, 143):
            self.assertFalse(self.known(rc))

    def test_preservation_failures_remain_fatal(self):
        self.text('ulogs/post-host-config.sha', 'host changed')
        self.assertFalse(self.known())

    def test_unrelated_guest_failures_remain_fatal(self):
        for error in ('installer changed the running host configuration',
                      'command timed out', 'no foreign-distro warning',
                      'installer changed /etc/group'):
            self.text('testresults/failure.txt', f'# Test died: {error}\n')
            self.assertFalse(self.known())

    def test_success_or_other_product_errors_are_not_expected(self):
        path = self.root / 'ulogs/install.log'
        original = path.read_text()
        for log in (original.replace('INSTALL_RC=1', 'INSTALL_RC=0'),
                    original.replace('Failed to read /etc/pacman.conf', 'Failed to download packages'),
                    original + 'Successfully installed packages\n',
                    original + 'Refusing to execute an invalid configuration\n'):
            path.write_text(log)
            self.assertFalse(self.known())

    def test_failed_boot_and_extra_failures_are_not_expected(self):
        self.json('testresults/result-host_boot.json', {'result': 'fail', 'details': []})
        self.assertFalse(self.known())
        self.json('testresults/result-host_boot.json', {'result': 'ok', 'details': []})
        self.json('testresults/result-other.json', {'result': 'fail', 'details': []})
        self.assertFalse(self.known())

    def test_missing_or_malformed_evidence_is_not_expected(self):
        for name in ('ulogs/pre-host-config.sha', 'ulogs/dryrun-host-config.sha',
                     'ulogs/post-host-config.sha', 'ulogs/install.log', 'ulogs/dryrun.log',
                     'testresults/failure.txt', 'autoinst-status.json'):
            path = self.root / name
            contents = path.read_bytes()
            path.unlink()
            self.assertFalse(self.known())
            path.write_bytes(contents)
        self.text('vars.json', 'not json')
        self.assertFalse(self.known())

    def test_failed_dryrun_or_invalid_json_shape_is_not_expected(self):
        self.text('ulogs/dryrun.log', 'DRYRUN_RC=1\n')
        self.assertFalse(self.known())
        self.text('ulogs/dryrun.log', 'DRYRUN_RC=0\n')
        self.json('vars.json', [])
        self.assertFalse(self.known())

    def test_incomplete_run_is_not_expected(self):
        self.json('autoinst-status.json', {'status': 'running'})
        self.assertFalse(self.known())


if __name__ == '__main__':
    unittest.main()
