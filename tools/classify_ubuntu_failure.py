#!/usr/bin/env python3
"""Recognize only the documented foreign-host gate gap, for CI on older refs.

The VM assertions remain failing. A match requires a completed harness run,
successful boot/dry-run and host preservation, and exactly the blank-disk failure
following the known missing-pacman.conf error. Missing evidence is not a match.
"""
import json
from pathlib import Path
import re
import sys


def known_ubuntu_gap(harness: Path, exit_code: int) -> bool:
    if exit_code != 101:  # isotovideo's test-result failure, never a Docker error
        return False
    try:
        variables = json.loads((harness / 'vars.json').read_text())
        if (variables.get('E2E_FLOW') != 'host-ubuntu'
                or variables.get('E2E_TARGET_DISK') != '/dev/vdb'
                or variables.get('E2E_SMOKE')):
            return False
        if json.loads((harness / 'autoinst-status.json').read_text()).get('status') != 'finished':
            return False
        results = harness / 'testresults'
        order = json.loads((results / 'test_order.json').read_text())
        if [module['name'] for module in order] != ['host_boot', 'host_install']:
            return False
        if {path.name for path in results.glob('result-*.json')} != {
                'result-host_boot.json', 'result-host_install.json'}:
            return False
        boot = json.loads((results / 'result-host_boot.json').read_text())
        install = json.loads((results / 'result-host_install.json').read_text())
        if boot['result'] != 'ok' or install['result'] != 'fail':
            return False
        if any(detail.get('result') == 'fail' for detail in boot['details']):
            return False
        failures = [detail for detail in install['details'] if detail.get('result') == 'fail']
        if len(failures) != 1 or failures[0].get('title') != 'Failed':
            return False
        text_name = failures[0]['text']
        if Path(text_name).name != text_name:
            return False
        failure = (results / text_name).read_text()
        if not failure.startswith('# Test died: /dev/vdb is no longer blank\n'):
            return False
        logs = harness / 'ulogs'
        baseline = (logs / 'pre-host-config.sha').read_bytes()
        if not baseline or any((logs / f'{phase}-host-config.sha').read_bytes() != baseline
                               for phase in ('dryrun', 'post')):
            return False
        log = (logs / 'install.log').read_text()
        if (not re.search(r'^INSTALL_RC=1$', log, re.M)
                or 'You appear to be running on' not in log
                or 'Failed to read /etc/pacman.conf' not in log
                or 'No such file or directory (os error 2)' not in log
                or 'Successfully installed packages' in log
                or 'invalid configuration' in log):
            return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: classify_ubuntu_failure.py HARNESS EXIT_CODE')
    sys.exit(0 if known_ubuntu_gap(Path(sys.argv[1]), int(sys.argv[2])) else 1)
