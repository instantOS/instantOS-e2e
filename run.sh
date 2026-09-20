#!/usr/bin/env bash
# End-to-end installer tests: boots the Arch ISO in the official isotovideo
# container, injects `ins` built from an instantCLI checkout, installs,
# reboots from disk and verifies the installed system.
#
# Results land in casedir/testresults/ (+ console logs in casedir/); exit 0
# means every module passed. See AGENTS.md for interpreting failures.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./run.sh [OPTIONS] [ISOTOVIDEO_VAR=VALUE ...]

Boot the Arch ISO in QEMU and test the `ins` binary built from the
instantCLI checkout at INSTANTCLI_DIR (default: ../instantCLI) — the
working tree as-is, uncommitted changes included.

Modes:
  --smoke        boot + in-VM dry-run only; ~4 min under TCG, no install
  --full         install + reboot + verification; ~35 min under TCG (default)
  --kvm          use /dev/kvm instead of TCG (KVM-capable host; ~10x faster)
  -h, --help     show this help

Profiles (--profile NAME): which questions fixture to install with.
  minimal        default; TTY-only, no instantOS packages (fastest)
  full           instantOS packages + Plymouth + GRUB theme (theming asserts)
  encrypted      full profile + LUKS; verifies the encrypted boot chain and
                 that the Plymouth theme is embedded in the initramfs

Any VAR=VALUE arguments are passed through to isotovideo and override the
defaults, e.g. QEMUCPUS=16, QEMURAM=8192, HDDSIZEGB=40, PASSWORD=...

Environment:
  INSTANTCLI_DIR   instantCLI checkout to build/test (default ../instantCLI)
  E2E_MEDIA_DIR    directory holding the ISO      (default ~/e2e-media)
  E2E_ISO_NAME     ISO file name                   (default archlinux-x86_64.iso)

The suite needs port 8000 on the host to serve assets to the guest; a
healthy server is reused, a conflicting one makes run.sh fail fast.
EOF
}

# --- arguments -------------------------------------------------------------
# Only per-run choices get flags; host config lives in env vars (above) and
# tuning in isotovideo VAR=VALUE passthrough.
MODE=full
KVM=0
PROFILE=minimal
PASSTHROUGH=()
while [ $# -gt 0 ]; do
    case "$1" in
        --smoke)   MODE=smoke ;;
        --full)    MODE=full ;;
        --kvm)     KVM=1 ;;
        --profile) shift
                   [ $# -gt 0 ] || { echo "run.sh: --profile needs a value (minimal|full|encrypted)" >&2; exit 2; }
                   PROFILE=$1 ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; PASSTHROUGH+=("$@"); break ;;
        --*)       echo "run.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
        *=*)       PASSTHROUGH+=("$1") ;;
        *)         echo "run.sh: unexpected argument '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

case "$PROFILE" in
    minimal|full|encrypted) ;;
    *) echo "run.sh: unknown profile '$PROFILE' (minimal|full|encrypted)" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"
E2E_MEDIA_DIR="${E2E_MEDIA_DIR:-$HOME/e2e-media}"
E2E_ISO_NAME="${E2E_ISO_NAME:-archlinux-x86_64.iso}"
INSTANTCLI_DIR="${INSTANTCLI_DIR:-$(cd "$REPO_ROOT/.." && pwd)/instantCLI}"

if [ ! -f "$INSTANTCLI_DIR/Cargo.toml" ]; then
    echo "instantCLI checkout not found at $INSTANTCLI_DIR" >&2
    echo "set INSTANTCLI_DIR to a checkout of instantOS/instantCLI" >&2
    exit 1
fi

# isotovideo reuses/rewrites vars.json in the casedir; start fresh every run.
# Leftovers can be root-owned (container output after a crashed/failed run):
# try non-interactive sudo first, then fall back to user-level rm.
if ! sudo -n rm -rf casedir/testresults casedir/raid 2>/dev/null; then
    rm -rf casedir/testresults casedir/raid
fi
rm -f casedir/vars.json
for leftover in casedir/testresults casedir/raid; do
    if [ -e "$leftover" ]; then
        echo "ERROR: cannot remove $leftover (root-owned?); run: sudo rm -rf $leftover" >&2
        exit 1
    fi
done

# Build the binary injected into the guest from the paired instantCLI checkout.
# Always run: cargo is incremental, so an unchanged checkout is a no-op — and
# this prevents silently testing a stale assets/ins after source changes.
echo "building ins from $INSTANTCLI_DIR (incremental)" >&2
(cd "$INSTANTCLI_DIR" && cargo build --release --bin ins)
cp "$INSTANTCLI_DIR/target/release/ins" assets/ins

# Serve assets to the guest (slirp NAT: guest reaches the host at 10.0.2.2;
# --network host makes that this machine). Port 8000 must serve assets/.
HTTP_PID=""
cleanup() { [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

if curl -fsS -o /dev/null http://127.0.0.1:8000/ins; then
    echo "reusing http server already serving assets on :8000" >&2
elif curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8000/ 2>/dev/null; then
    echo "ERROR: port 8000 is taken by a server that does not serve assets/ins" >&2
    echo "       usually a stale server from another checkout; free the port:" >&2
    echo "       fuser -k 8000/tcp   (or: ss -ltnp | grep 8000; kill <pid>)" >&2
    exit 1
else
    echo "starting http server for guest asset injection on :8000" >&2
    (cd assets && exec python3 -m http.server 8000) >/dev/null 2>&1 &
    HTTP_PID=$!
    sleep 1
    if ! curl -fsS -o /dev/null http://127.0.0.1:8000/ins; then
        echo "ERROR: asset server on :8000 did not come up (check 'ss -ltnp | grep 8000')" >&2
        exit 1
    fi
fi

# --- isotovideo invocation -------------------------------------------------
# Explicitly deduped/overridden in bash — passthrough always wins over the
# defaults below, regardless of how isotovideo treats duplicate keys.
declare -A VARS=(
    [casedir]=/tests
    [distri]=arch
    [version]=202609
    [flavor]=medium
    [QEMUCPUS]=8
    [QEMURAM]=4096
    [HDDSIZEGB]=20
    [BOOTFROM]=d
    [PASSWORD]=correct-horse-battery-staple
)
VARS[iso]="/media/$E2E_ISO_NAME"
if [ "$KVM" -eq 1 ]; then
    # Container runs as root, so /dev/kvm access does not depend on host groups.
    DOCKER_ARGS=(--device /dev/kvm)
else
    DOCKER_ARGS=()
    VARS[qemu_no_kvm]=1
fi
if [ "$MODE" = smoke ]; then
    VARS[E2E_SMOKE]=1
fi
VARS[E2E_PROFILE]=$PROFILE
for kv in "${PASSTHROUGH[@]}"; do VARS[${kv%%=*}]=${kv#*=}; done

ISO_ARGS=()
for k in "${!VARS[@]}"; do ISO_ARGS+=("$k=${VARS[$k]}"); done

set +e
docker run --rm -w /tests --network host "${DOCKER_ARGS[@]}" \
    -v "$REPO_ROOT/casedir:/tests" \
    -v "$E2E_MEDIA_DIR:/media:ro" \
    registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
    --exit-status-from-test-results \
    "${ISO_ARGS[@]}"
rc=$?
set -e

# The container runs as root; give artifacts back to the invoking user.
# -n: never hang waiting for a password. If this fails, say so loudly —
# root-owned leftovers will break the NEXT run's cleanup.
if ! sudo -n chown -R "${USER}:$(id -gn)" casedir 2>/dev/null; then
    echo "WARNING: could not chown casedir artifacts (no passwordless sudo?);" >&2
    echo "         run 'sudo chown -R $(id -u):\$(id -g) casedir' before the next run" >&2
fi
exit "$rc"
