#!/usr/bin/env bash
# Boot the instantOS live ISO under isotovideo (diagnostic harness; the main
# suite's run.sh is unaffected). Screenshots + serial logs land in this
# directory's testresults/, virtio_console.log, serial0.
#
# Usage: ./run.sh [VAR=VALUE ...]   e.g. ./run.sh QEMURAM=8192
#
#   Offline spike (Phase 0, offlineiso.md): boot the xorriso-injected ISO
#   and assert the bundle + offline wiring inside the live session:
#     E2E_MEDIA_DIR=../../instantOS/iso/build/iso \
#     E2E_ISO_NAME=instantos-YYYY.MM.DD-offline.iso ./run.sh E2E_OFFLINE=1
#
#   UEFI spike: OVMF boot of the default systemd-boot entry (no menu
#   interaction, desktop-needle asserts only — see tests/liveiso.pm header):
#     E2E_ISO_NAME=... ./run.sh UEFI=1 [E2E_OFFLINE=1]
set -euo pipefail
cd "$(dirname "$0")"

E2E_MEDIA_DIR="${E2E_MEDIA_DIR:-$HOME/e2e-media}"
E2E_ISO_NAME="${E2E_ISO_NAME:-instantos-2026.08.24-x86_64.iso}"

# Container output is root-owned (os-autoinst writes as root), so cleanup
# needs sudo; chown back afterwards so the next run can clean up unprivileged.
sudo rm -rf testresults raid vars.json

# NEEDLES_DIR points at the main suite's needles so this harness shares them
# (it currently uses none; bootcap-style needles can be added later).
# Run the container without `exec` so we can chown the root-owned output
# back (otherwise the next run's `sudo rm` would be the only way to clean up).
rc=0
docker run --rm -w /tests --network host \
    -v "$PWD":/tests \
    -v "$PWD/../../casedir":/casedir:ro \
    -v "$E2E_MEDIA_DIR":/media:ro \
    registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
    --exit-status-from-test-results \
    qemu_no_kvm=1 casedir=/tests \
    NEEDLES_DIR=/casedir/needles \
    iso="/media/$E2E_ISO_NAME" \
    QEMUCPUS=8 QEMURAM=4096 HDDSIZEGB=20 BOOTFROM=d \
    PASSWORD=instantos "$@" || rc=$?
sudo chown -R "$(id -u):$(id -g)" testresults raid 2>/dev/null || true
exit "$rc"
