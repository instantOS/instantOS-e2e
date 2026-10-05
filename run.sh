#!/usr/bin/env bash
# Build/test the working instantCLI checkout, or the installer on an offline ISO.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_ROOT"
usage() {
    cat <<'HELP'
Usage: ./run.sh [--flow live|offline|host-arch|host-ubuntu] [OPTIONS] [VAR=VALUE ...]

  --flow NAME      live (default): Arch ISO, one blank disk
                   offline: instantOS offline ISO, no NIC, shipped installer
                   host-arch: running Arch, install onto a second disk and boot it
                   host-ubuntu: running Ubuntu, require refusal before disk writes
  --smoke          boot and dry-run only
  --full           install and verify (default)
  --profile NAME   minimal (default), full, encrypted; host flows require minimal
  --release        published installer via install.sh (live flow only)
  --kvm            hardware acceleration (default: TCG)
  -h, --help       show help

Environment:
  INSTANTCLI_DIR    checkout to build (default ../instantCLI)
  CARGO_TARGET_DIR  build output (default $INSTANTCLI_DIR/target)
  E2E_MEDIA_DIR    ISO directory (default ~/e2e-media)
  E2E_ISO_NAME     live: archlinux-x86_64.iso; offline: instantos-offline-latest.iso
                   Set explicitly for a locally built offline ISO.
  E2E_WORK_DIR     scratch directory (default ../e2e-work)
  E2E_IMAGE_DIR    host bundles (default $E2E_WORK_DIR/images)

Build host bundles with tools/mkhost.sh arch|ubuntu. Extra VAR=VALUE arguments
set QEMU tuning variables, e.g. QEMUCPUS=4. Scenario and credential variables
are owned by the suite. See README.md for requirements and diagnostic commands.
HELP
}
FLOW=live MODE=full PROFILE=minimal RELEASE=0 KVM=0
PASSTHROUGH=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --flow|--profile)
            option=$1; shift
            [ "$#" -gt 0 ] || { echo "$option needs a value" >&2; exit 2; }
            if [ "$option" = --flow ]; then FLOW=$1; else PROFILE=$1; fi ;;
        --smoke) MODE=smoke ;;
        --full) MODE=full ;;
        --release) RELEASE=1 ;;
        --kvm) KVM=1 ;;
        -h|--help) usage; exit 0 ;;
        *=*) PASSTHROUGH+=("$1") ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
case "$FLOW" in live|offline|host-arch|host-ubuntu) ;; *) echo "Unknown flow: $FLOW" >&2; exit 2 ;; esac
case "$PROFILE" in minimal|full|encrypted) ;; *) echo "Unknown profile: $PROFILE" >&2; exit 2 ;; esac
if [[ $FLOW == host-* && $PROFILE != minimal ]]; then
    echo 'Host flows require --profile minimal' >&2; exit 2
fi
if [ "$RELEASE" -eq 1 ] && [ "$FLOW" != live ]; then
    echo '--release requires --flow live' >&2; exit 2
fi
# Reject overrides that would contradict the flow selected on the host.
for kv in "${PASSTHROUGH[@]}"; do
    key=${kv%%=*}
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Invalid variable: $key" >&2; exit 2; }
    case "${key^^}" in
        E2E_*|PASSWORD|CASEDIR|NEEDLES_DIR|ISO|HDD_*|NUMDISKS|KERNEL|INITRD|APPEND|BOOTFROM|OFFLINE_SUT|NICTYPE|NIC*|QEMU_NO_KVM)
            echo "$key is controlled by the suite; use flags instead" >&2; exit 2 ;;
    esac
done
. "$REPO_ROOT/tools/lib/paths.sh"
. "$REPO_ROOT/tools/lib/fixtures.sh"
. "$REPO_ROOT/tools/lib/isotovideo.sh"
lock_suite

INSTANTCLI_DIR=${INSTANTCLI_DIR:-$(dirname "$REPO_ROOT")/instantCLI}
INSTALLER=checkout
if [ "$FLOW" = offline ]; then INSTALLER=shipped; fi
if [ "$RELEASE" -eq 1 ]; then INSTALLER=release; fi

VM_PASSWORD=$(fixture_password "$PROFILE")
declare -A VARS=(
    [distri]=arch [version]=202609 [flavor]=medium
    [QEMUCPUS]=8 [QEMURAM]=4096 [HDDSIZEGB]=20
    [PASSWORD]=$VM_PASSWORD
    [E2E_FLOW]=$FLOW [E2E_PROFILE]=$PROFILE [E2E_INSTALLER]=$INSTALLER
)
MOUNTS=(-v "$REPO_ROOT/assets:/tests/assets:ro")
if [[ $FLOW == host-* ]]; then
    DISTRO=${FLOW#host-}
    BUNDLE="$E2E_IMAGE_DIR/$DISTRO-host"
    # Prevent replacing a backing disk while this run uses it.
    exec 9>"$E2E_IMAGE_DIR/.$DISTRO-host.lock"
    flock -sn 9 || { echo "Host bundle is being rebuilt: $BUNDLE" >&2; exit 1; }
    for file in disk.img vmlinuz initrd.img; do
        [ -s "$BUNDLE/$file" ] || {
            echo "Missing $BUNDLE/$file; run tools/mkhost.sh $DISTRO" >&2; exit 1;
        }
    done
    VARS[NUMDISKS]=2
    VARS[HDD_1]="/e2e/images/$DISTRO-host/disk.img"
    VARS[KERNEL]="/e2e/images/$DISTRO-host/vmlinuz"
    VARS[INITRD]="/e2e/images/$DISTRO-host/initrd.img"
    # os-autoinst cannot pass a whitespace-containing APPEND correctly.
    VARS[APPEND]="root=LABEL=e2e$DISTRO"
    # Direct kernel boot needs no firmware disk boot index. QEMU assigns index
    # zero to the kernel loader; BOOTFROM=c would assign zero to disk 1 too.
    VARS[E2E_TARGET_DISK]=/dev/vdb
    VARS[STORAGE_KEEP_FREE_GB]=10
    MOUNTS+=(-v "$E2E_WORK_DIR:/e2e" -v "$E2E_IMAGE_DIR:/e2e/images")
else
    E2E_MEDIA_DIR=${E2E_MEDIA_DIR:-$HOME/e2e-media}
    if [ "$FLOW" = offline ]; then
        E2E_ISO_NAME=${E2E_ISO_NAME:-instantos-offline-latest.iso}
        VARS[OFFLINE_SUT]=1
    else
        E2E_ISO_NAME=${E2E_ISO_NAME:-archlinux-x86_64.iso}
    fi
    [ -f "$E2E_MEDIA_DIR/$E2E_ISO_NAME" ] || {
        echo "ISO not found: $E2E_MEDIA_DIR/$E2E_ISO_NAME" >&2; exit 1;
    }
    E2E_MEDIA_DIR=$(cd "$E2E_MEDIA_DIR" && pwd)
    VARS[iso]="/media/$E2E_ISO_NAME"
    VARS[BOOTFROM]=d
    VARS[E2E_TARGET_DISK]=/dev/vda
    MOUNTS+=(-v "$E2E_MEDIA_DIR:/media:ro")
fi
DOCKER_ARGS=()
if [ "$KVM" -eq 1 ]; then DOCKER_ARGS+=(--device /dev/kvm); else VARS[qemu_no_kvm]=1; fi
if [ "$MODE" = smoke ]; then VARS[E2E_SMOKE]=1; fi
for kv in "${PASSTHROUGH[@]}"; do
    key=${kv%%=*}
    VARS[${key^^}]=${kv#*=}
done

ASSET_PID='' ASSET_PORT_FILE=''
# Called by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
    if [ -n "$ASSET_PID" ]; then kill "$ASSET_PID" 2>/dev/null || true; wait "$ASSET_PID" 2>/dev/null || true; fi
    if [ -n "$ASSET_PORT_FILE" ]; then rm -f "$ASSET_PORT_FILE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$INSTALLER" = checkout ]; then
    [ -f "$INSTANTCLI_DIR/Cargo.toml" ] || { echo "No instantCLI checkout at $INSTANTCLI_DIR" >&2; exit 1; }
    INSTANTCLI_DIR=$(cd "$INSTANTCLI_DIR" && pwd)
    CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$INSTANTCLI_DIR/target}
    # Resolve even a dangling checkout cache symlink before creating its target.
    CARGO_TARGET_DIR=$(realpath -m "$CARGO_TARGET_DIR")
    mkdir -p "$CARGO_TARGET_DIR"
    export CARGO_TARGET_DIR
    BUILD_TMPDIR=${TMPDIR:-$E2E_WORK_DIR/tmp}
    mkdir -p "$BUILD_TMPDIR"
    echo "Building ins from $INSTANTCLI_DIR" >&2
    (cd "$INSTANTCLI_DIR" && TMPDIR="$BUILD_TMPDIR" cargo build --release --bin ins)
    # Record what produced the binary under test. A failure that depends on the
    # toolchain or on the build host (an instruction the guest CPU lacks, a
    # library the medium dropped) is otherwise impossible to attribute: the run
    # log names neither the product commit nor the compiler that built it.
    # A tool that is not installed is reported as such rather than putting a
    # shell error in the middle of the block.
    tool_version() {
        if command -v "$1" >/dev/null 2>&1; then
            "$1" --version 2>&1 | head -1
        else
            echo 'unavailable'
        fi
    }
    {
        echo "instantCLI $(git -C "$INSTANTCLI_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "build host $(uname -srm)"
        echo "rustc $(tool_version rustc)"
        echo "cc $(tool_version "${CC:-cc}")"
        echo "cmake $(tool_version cmake)"
        echo "libc $(tool_version ldd)"
    } >&2
    cp "$CARGO_TARGET_DIR/release/ins" assets/ins
    ASSET_PORT_FILE=$(mktemp)
    python3 "$REPO_ROOT/tools/serve-assets.py" "$REPO_ROOT/assets" >"$ASSET_PORT_FILE" 2>/dev/null &
    ASSET_PID=$!
    for ((attempt=0; attempt<50; attempt++)); do
        [ ! -s "$ASSET_PORT_FILE" ] || break
        kill -0 "$ASSET_PID" 2>/dev/null || { echo 'Asset server failed to start' >&2; exit 1; }
        sleep 0.1
    done
    read -r port <"$ASSET_PORT_FILE" || { echo 'Asset server startup timed out' >&2; exit 1; }
    VARS[E2E_ASSET_URL]="http://10.0.2.2:$port"
fi

# Clear the planned second stage even if the installation stage fails.
if [ "$FLOW" = host-arch ] && [ "$MODE" = full ]; then
    reset_harness "$REPO_ROOT/diag/verifydisk"
fi
rc=0
run_isotovideo "$REPO_ROOT/casedir" VARS MOUNTS || rc=$?
if [ "$FLOW" = host-arch ] && [ "$MODE" = full ] && [ "$rc" -eq 0 ]; then
    mkdir -p "$E2E_WORK_DIR/work"
    TARGET_RAW="$E2E_WORK_DIR/work/arch-host-target.raw"
    echo "Booting the installed second disk standalone" >&2
    # Propagate conversion failures and always verify a full install.
    qemu-img convert -O raw casedir/raid/hd1 "$TARGET_RAW"
    declare -A VERIFY_VARS=(
        [distri]=arch [version]=202609 [BOOTFROM]=c [NUMDISKS]=1
        [HDD_1]=/e2e/work/arch-host-target.raw
        [NEEDLES_DIR]=/casedir/needles [E2E_TARGET_DISK]=/dev/vda
        [E2E_PROFILE]=$PROFILE [E2E_FLOW]=host-arch
    )
    # Carry hardware tuning into the fresh stage, excluding boot/install state.
    for key in "${!VARS[@]}"; do
        # run_isotovideo reads these arrays by nameref.
        # shellcheck disable=SC2034
        case "$key" in QEMU*|qemu_no_kvm|PASSWORD|HDDSIZEGB|STORAGE_*) VERIFY_VARS[$key]=${VARS[$key]} ;; esac
    done
    # shellcheck disable=SC2034
    VERIFY_MOUNTS=(-v "$E2E_WORK_DIR:/e2e")
    run_isotovideo "$REPO_ROOT/diag/verifydisk" VERIFY_VARS VERIFY_MOUNTS || rc=$?
fi
exit "$rc"
