#!/usr/bin/env bash
# Run diagnostic modules with the same container lifecycle as the installer.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_ROOT/tools/lib/isotovideo.sh"
. "$REPO_ROOT/tools/lib/fixtures.sh"
case "${1:-}" in
    bootcap|verifydisk|liveiso) HARNESS=$1; shift ;;
    *) echo 'Usage: tools/run-diagnostic.sh bootcap|verifydisk DISK.raw [OPTIONS] [VAR=VALUE ...]' >&2
       echo '       tools/run-diagnostic.sh liveiso [--offline] [--kvm] [VAR=VALUE ...]' >&2; exit 2 ;;
esac
MOUNTS=() DOCKER_ARGS=()
declare -A VARS=(
    [distri]=arch [version]=202609 [QEMUCPUS]=8 [QEMURAM]=4096
    [HDDSIZEGB]=20 [qemu_no_kvm]=1
    [NEEDLES_DIR]=/casedir/needles [E2E_PROFILE]=minimal [E2E_FLOW]=live
    [E2E_TARGET_DISK]=/dev/vda
)
if [ "$HARNESS" = liveiso ]; then
    VARS[PASSWORD]=instantos
    VARS[BOOTFROM]=d
else
    [ "$#" -gt 0 ] || { echo 'A raw installed disk is required' >&2; exit 2; }
    DISK=$(realpath "$1"); shift
    [ -s "$DISK" ] || { echo "No disk at $DISK" >&2; exit 1; }
    qemu-img info --output=json "$DISK" | python3 -c '
import json, sys
if json.load(sys.stdin)["format"] != "raw":
    sys.exit("Convert the disk with qemu-img convert -O raw first")
'
    VARS[HDD_1]="/input/$(basename "$DISK")"
    VARS[BOOTFROM]=c
    MOUNTS+=(-v "$(dirname "$DISK"):/input")
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --kvm) DOCKER_ARGS+=(--device /dev/kvm); unset 'VARS[qemu_no_kvm]' ;;
        --offline) VARS[E2E_FLOW]=offline; VARS[OFFLINE_SUT]=1 ;;
        --profile)
            shift; [ "$#" -gt 0 ] || { echo '--profile needs a value' >&2; exit 2; }
            case "$1" in minimal|full|encrypted) VARS[E2E_PROFILE]=$1 ;; *) echo "Invalid profile: $1" >&2; exit 2 ;; esac ;;
        *=*)
            key=${1%%=*}
            [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Invalid variable: $key" >&2; exit 2; }
            case "${key^^}" in
                CASEDIR|NEEDLES_DIR|ISO|HDD_*|BOOTFROM|E2E_*|OFFLINE_SUT|QEMU_NO_KVM)
                    echo "$key is controlled by the diagnostic runner" >&2; exit 2 ;;
            esac
            VARS[${key^^}]=${1#*=} ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
VARS[PASSWORD]=${VARS[PASSWORD]:-$(fixture_password "${VARS[E2E_PROFILE]}")}
if [ "$HARNESS" = liveiso ]; then
    E2E_MEDIA_DIR=${E2E_MEDIA_DIR:-$HOME/e2e-media}
    E2E_ISO_NAME=${E2E_ISO_NAME:?Set E2E_ISO_NAME to the instantOS ISO to boot}
    [ -f "$E2E_MEDIA_DIR/$E2E_ISO_NAME" ] || { echo 'ISO not found' >&2; exit 1; }
    E2E_MEDIA_DIR=$(cd "$E2E_MEDIA_DIR" && pwd)
    # run_isotovideo reads VARS by nameref.
    # shellcheck disable=SC2034
    VARS[iso]="/media/$E2E_ISO_NAME"
    MOUNTS+=(-v "$E2E_MEDIA_DIR:/media:ro")
fi
lock_suite
run_isotovideo "$REPO_ROOT/diag/$HARNESS" VARS MOUNTS
