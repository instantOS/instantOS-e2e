#!/usr/bin/env bash
# End-to-end installer tests: boots the Arch ISO in the official isotovideo
# container, injects `ins` built from an instantCLI checkout, installs,
# reboots from disk and verifies the installed system.
#
# Usage: ./run.sh [extra isotovideo vars ...]
#   E2E_MEDIA_DIR   where the Arch ISO lives (default ~/e2e-media)
#   E2E_ISO_NAME    ISO file name              (default archlinux-x86_64.iso)
#   INSTANTCLI_DIR  instantCLI checkout to build/test (default ../instantCLI)
#
# Useful extra vars:
#   E2E_SMOKE=1            boot + in-VM dry-run only (~4 min, no install)
#   QEMUCPUS=4             vCPU count (TCG; match your cores)
#   KVM available? drop qemu_no_kvm=1 by editing below or pass the vars you need.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
E2E_MEDIA_DIR="${E2E_MEDIA_DIR:-$HOME/e2e-media}"
E2E_ISO_NAME="${E2E_ISO_NAME:-archlinux-x86_64.iso}"
INSTANTCLI_DIR="${INSTANTCLI_DIR:-$(cd "$REPO_ROOT/.." && pwd)/instantCLI}"

if [ ! -f "$INSTANTCLI_DIR/Cargo.toml" ]; then
    echo "instantCLI checkout not found at $INSTANTCLI_DIR" >&2
    echo "set INSTANTCLI_DIR to a checkout of instantOS/instantCLI" >&2
    exit 1
fi

# isotovideo reuses/rewrites vars.json in the casedir; start fresh every run.
rm -f casedir/vars.json
rm -rf casedir/testresults casedir/raid

# Build the binary injected into the guest from the paired instantCLI checkout.
# Always run: cargo is incremental, so an unchanged checkout is a no-op — and
# this prevents silently testing a stale assets/ins after source changes.
echo "building ins from $INSTANTCLI_DIR (incremental)" >&2
(cd "$INSTANTCLI_DIR" && cargo build --release --bin ins)
cp "$INSTANTCLI_DIR/target/release/ins" assets/ins

# Serve assets to the guest (slirp NAT: guest reaches the host at 10.0.2.2;
# --network host makes that this machine). Port 8000.
if ! curl -fsS -o /dev/null http://127.0.0.1:8000/ins; then
    echo "starting http server for guest asset injection on :8000" >&2
    (cd assets && python3 -m http.server 8000 >/dev/null 2>&1 &)
    sleep 1
fi

# shellcheck disable=SC2086
set +e
docker run --rm -w /tests --network host \
    -v "$REPO_ROOT/casedir:/tests" \
    -v "$E2E_MEDIA_DIR:/media:ro" \
    registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
    --exit-status-from-test-results \
    qemu_no_kvm=1 casedir=/tests \
    "iso=/media/$E2E_ISO_NAME" \
    distri=arch version=202609 flavor=medium \
    QEMUCPUS=8 QEMURAM=4096 HDDSIZEGB=20 BOOTFROM=d \
    PASSWORD=correct-horse-battery-staple \
    "$@"
rc=$?
set -e

# The container runs as root; give artifacts back to the invoking user.
sudo chown -R "${USER}:$(id -gn)" casedir 2>/dev/null || true
exit "$rc"
