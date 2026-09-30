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

Boot a medium in QEMU and test the `ins` binary built from the instantCLI
checkout at INSTANTCLI_DIR (default: ../instantCLI) — the working tree as-is,
uncommitted changes included.

Modes:
  --smoke        boot + in-VM dry-run only; ~4 min under TCG, no install
  --full         install + reboot + verification; ~35 min under TCG (default)
  --host-arch    install from an already-RUNNING Arch: boots the prepared
                 Arch host image as /dev/vda, installs instantOS onto the
                 blank second disk (/dev/vdb), then extracts that disk and
                 boots it on its own to verify it. ~50 min under TCG.
                 Needs images/arch-host.img — see tools/mkhost-arch.sh.
  --host-ubuntu  from a RUNNING Ubuntu 24.04 (the Arch toolchain is deliberately
                 absent, so this exercises the product's foreign-distro path).
                 Expects the installer to REFUSE before touching the second
                 disk; it does not have a second verification stage, and it is
                 red against instantCLI dev because `ins arch exec` has no
                 host-profile gate (only `ins arch install` does) — see
                 docs/FINDINGS.md. Needs images/ubuntu-host.img — see
                 tools/mkhost-ubuntu.sh.
  --kvm          use /dev/kvm instead of TCG (KVM-capable host; ~10x faster)
  --release      test published release via install.sh (skips cargo build & local web server)
  --offline      Phase 3 (offlineiso.md): boot the offline-injected instantOS
                 ISO with NO NIC and install fully offline from the on-ISO
                 bundle; verifies no file:// remnants on the target. Skips
                 cargo build & asset server (tests the shipped ins).
  -h, --help     show this help

Profiles (--profile NAME): which questions fixture to install with.
  minimal        default; TTY-only, no instantOS packages (fastest)
  full           instantOS packages + Plymouth + GRUB theme (theming asserts)
  encrypted      full profile + LUKS; verifies the encrypted boot chain and
                 that the Plymouth theme is embedded in the initramfs
                 (not accepted with --host-arch/--host-ubuntu, which always
                 install assets/questions-seconddisk.toml)

Any VAR=VALUE arguments are passed through to isotovideo and override the
defaults, e.g. QEMUCPUS=16, QEMURAM=8192, HDDSIZEGB=40, PASSWORD=...

Environment:
  INSTANTCLI_DIR      instantCLI checkout to build/test (default ../instantCLI)
  CARGO_TARGET_DIR    cargo target dir to build into (default
                      $INSTANTCLI_DIR/target); run.sh copies the binary from
                      here into assets/ins
  E2E_MEDIA_DIR       directory holding the ISO      (default ~/e2e-media)
  E2E_ISO_NAME        ISO file name                   (default archlinux-x86_64.iso;
                      with --offline: the newest instantos-*-offline.iso or
                      instantos-offline-latest.iso in E2E_MEDIA_DIR)
  E2E_WORK_DIR        writable scratch for the --host-* flows; the prepared
                      host images live in $E2E_WORK_DIR/images and are bind
                      mounted into the container at /e2e/images
                      (default ../e2e-work)
  E2E_IMAGE_DIR       override just the image directory (default
                      $E2E_WORK_DIR/images)

The suite needs port 8000 on the host to serve assets to the guest in dev mode;
a healthy server is reused, a conflicting one makes run.sh fail fast.
EOF
}

# --- arguments -------------------------------------------------------------
# Only per-run choices get flags; host config lives in env vars (above) and
# tuning in isotovideo VAR=VALUE passthrough.
MODE=full
KVM=0
RELEASE=0
OFFLINE=0
PROFILE=minimal
FLOW=live
PASSTHROUGH=()
while [ $# -gt 0 ]; do
    case "$1" in
    --smoke) MODE=smoke ;;
    --full) MODE=full ;;
    --kvm) KVM=1 ;;
    --release) RELEASE=1 ;;
    --offline) OFFLINE=1 ;;
    --host-arch) FLOW=host-arch ;;
    --host-ubuntu) FLOW=host-ubuntu ;;
    --profile)
        shift
        [ $# -gt 0 ] || {
            echo "run.sh: --profile needs a value (minimal|full|encrypted)" >&2
            exit 2
        }
        PROFILE=$1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --)
        shift
        PASSTHROUGH+=("$@")
        break
        ;;
    --*)
        echo "run.sh: unknown option '$1' (try --help)" >&2
        exit 2
        ;;
    *=*) PASSTHROUGH+=("$1") ;;
    *)
        echo "run.sh: unexpected argument '$1' (try --help)" >&2
        exit 2
        ;;
    esac
    shift
done

case "$PROFILE" in
minimal | full | encrypted) ;;
*)
    echo "run.sh: unknown profile '$PROFILE' (minimal|full|encrypted)" >&2
    exit 2
    ;;
esac

# The non-live flows deliberately do not combine with the ISO-based ones: they
# boot a disk image directly, so --release/--offline (which change what `ins`
# is and where the questions come from) do not apply.
if [ "$FLOW" != live ] && { [ "$RELEASE" -eq 1 ] || [ "$OFFLINE" -eq 1 ]; }; then
    echo "run.sh: --host-arch/--host-ubuntu cannot be combined with --release/--offline" >&2
    exit 2
fi
# The non-live flows always install assets/questions-seconddisk.toml, which is
# a minimal, unencrypted configuration: that is the point of the flow (prove
# the running-OS path works), not an oversight. Accepting --profile here would
# mean the flag is silently ignored, and the second stage's verification does
# not run the profile-specific checks, so `--host-arch --profile encrypted`
# would "pass" while testing an unencrypted minimal install. Refuse instead.
if [ "$FLOW" != live ] && [ "$PROFILE" != minimal ]; then
    echo "run.sh: --host-arch/--host-ubuntu only support --profile minimal" >&2
    echo "       (they install assets/questions-seconddisk.toml, which is minimal)" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"
if [ "$OFFLINE" -eq 1 ]; then
    # Default to the local offline build output; E2E_ISO_NAME may name any
    # offline artifact (e.g. a downloaded release).
    E2E_MEDIA_DIR="${E2E_MEDIA_DIR:-$(cd "$REPO_ROOT/.." && pwd)/instantOS/iso/build/iso}"
    if [ -z "${E2E_ISO_NAME:-}" ]; then
        # `ls` on a glob with no match fails, and under `set -e -o pipefail`
        # that would abort the whole script before the friendly message below
        # could print. Swallow the status explicitly. Both names are looked
        # for: a local build output (instantos-<version>-offline.iso) and the
        # published artifact, whose name is stable and replaced in place
        # (instantOS/iso/publish-sourceforge.py).
        E2E_ISO_NAME="$(ls -1t "$E2E_MEDIA_DIR"/instantos-*-offline.iso \
            "$E2E_MEDIA_DIR"/instantos-offline-latest.iso 2>/dev/null |
            head -n 1 | xargs -r -n 1 basename)" || true
        if [ -z "$E2E_ISO_NAME" ]; then
            echo "run.sh: no instantOS offline ISO in $E2E_MEDIA_DIR" >&2
            echo "       build one first: (cd ../instantOS && just build-iso-offline-docker)" >&2
            echo "       or put the published one there (~4.3 GiB, stable path):" >&2
            echo "       https://sourceforge.net/projects/instantos/files/offline/latest/instantos-offline-latest.iso/download" >&2
            exit 1
        fi
    fi
else
    E2E_MEDIA_DIR="${E2E_MEDIA_DIR:-$HOME/e2e-media}"
    E2E_ISO_NAME="${E2E_ISO_NAME:-archlinux-x86_64.iso}"
fi
# The ISO is fetched separately in CI and named through E2E_ISO_NAME, so a
# failed or mistyped download has to fail here rather than minutes later as an
# unexplained QEMU boot timeout.
if [ ! -f "$E2E_MEDIA_DIR/$E2E_ISO_NAME" ]; then
    echo "run.sh: ISO not found: $E2E_MEDIA_DIR/$E2E_ISO_NAME" >&2
    echo "       (E2E_MEDIA_DIR=$E2E_MEDIA_DIR E2E_ISO_NAME=$E2E_ISO_NAME)" >&2
    exit 1
fi
INSTANTCLI_DIR="${INSTANTCLI_DIR:-$(cd "$REPO_ROOT/.." && pwd)/instantCLI}"

# The non-live flows need a *writable* place for the prepared host images and
# for the converted target disk. /media is mounted read-only, and os-autoinst
# opens an HDD_N backing file read-write (the qcow2 overlay in casedir/raid
# absorbs the writes, but QEMU still needs the mode bits), so the images get
# their own bind mount under /e2e. Keep this off /tmp: a rootfs is >1 GiB and
# /tmp is a small tmpfs on the reference host.
E2E_WORK_DIR="${E2E_WORK_DIR:-$(cd "$REPO_ROOT/.." && pwd)/e2e-work}"
E2E_IMAGE_DIR="${E2E_IMAGE_DIR:-$E2E_WORK_DIR/images}"
mkdir -p "$E2E_IMAGE_DIR"

# Honour a shared target dir so repeated runs (and the baseline worktree
# comparison) do not each pay for a full release build of the product.
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$INSTANTCLI_DIR/target}"
export CARGO_TARGET_DIR

HOST_ENV=""
if [ "$FLOW" != live ]; then
    case "$FLOW" in
    host-arch)
        HOST_STEM=arch-host
        HOST_BUILDER=tools/mkhost-arch.sh
        ;;
    host-ubuntu)
        HOST_STEM=ubuntu-host
        HOST_BUILDER=tools/mkhost-ubuntu.sh
        ;;
    esac
    HOST_ENV="$E2E_IMAGE_DIR/$HOST_STEM.env"
    if [ ! -f "$HOST_ENV" ]; then
        echo "run.sh: missing $HOST_ENV" >&2
        echo "       build the host image first: ./$HOST_BUILDER" >&2
        echo "       (E2E_IMAGE_DIR overrides the image directory, default ../e2e-work/images)" >&2
        exit 1
    fi
    # Container-side paths: $E2E_IMAGE_DIR is bind mounted at /e2e/images.
    # shellcheck disable=SC1090
    . "$HOST_ENV"
    for f in "$E2E_IMAGE_DIR/$HOST_STEM.img" \
        "$E2E_IMAGE_DIR/$HOST_STEM/vmlinuz" \
        "$E2E_IMAGE_DIR/$HOST_STEM/initrd.img"; do
        if [ ! -f "$f" ]; then
            echo "run.sh: $HOST_ENV references $f but it does not exist" >&2
            exit 1
        fi
    done
    echo "non-live flow '$FLOW': host image $E2E_IMAGE_DIR/$HOST_STEM.img, target disk /dev/vdb" >&2
fi

if [ "$RELEASE" -eq 0 ] && [ "$OFFLINE" -eq 0 ]; then
    if [ ! -f "$INSTANTCLI_DIR/Cargo.toml" ]; then
        echo "instantCLI checkout not found at $INSTANTCLI_DIR" >&2
        echo "set INSTANTCLI_DIR to a checkout of instantOS/instantCLI" >&2
        exit 1
    fi
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

if [ "$RELEASE" -eq 0 ] && [ "$OFFLINE" -eq 0 ]; then
    # Build the binary injected into the guest from the paired instantCLI checkout.
    # Always run: cargo is incremental, so an unchanged checkout is a no-op — and
    # this prevents silently testing a stale assets/ins after source changes.
    echo "building ins from $INSTANTCLI_DIR (incremental, target=$CARGO_TARGET_DIR)" >&2
    (cd "$INSTANTCLI_DIR" && cargo build --release --bin ins)
    cp "$CARGO_TARGET_DIR/release/ins" assets/ins

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
else
    if [ "$OFFLINE" -eq 1 ]; then
        echo "offline mode: testing the shipped ins on $E2E_ISO_NAME with no NIC (skipping local build & asset server)" >&2
    else
        echo "running in release mode: testing published release via install.sh (skipping local build & asset server)" >&2
    fi
fi

# --- isotovideo invocation -------------------------------------------------
# Explicitly deduped/overridden in bash — passthrough always wins over the
# defaults below, regardless of how isotovideo treats duplicate keys.
declare -A VARS=(
    [distri]=arch
    [version]=202609
    [flavor]=medium
    [QEMUCPUS]=8
    [QEMURAM]=4096
    [HDDSIZEGB]=20
    [BOOTFROM]=d
    [PASSWORD]=correct-horse-battery-staple
    # casedir/main.pm dispatches the entire module list on this. It has to be
    # a default here, not something the host branch adds: without it every
    # flow takes the `live` branch and waits for an ISO that is not attached.
    [E2E_FLOW]=$FLOW
)
if [ "$FLOW" = live ]; then
    VARS[iso]="/media/$E2E_ISO_NAME"
else
    # Two disks: disk 1 is the prepared running host OS (raw backing file, its
    # qcow2 overlay lands in casedir/raid/hd0-overlay0 and is thrown away every
    # run), disk 2 is a blank 20 GiB qcow2 created by os-autoinst. Both are
    # virtio-blk, so the host OS is /dev/vda and the install target /dev/vdb.
    VARS[NUMDISKS]=2
    VARS[HDD_1]=$E2E_HOST_IMAGE
    # Direct kernel boot: no bootloader lives in the host images (see
    # tools/mkhost-*.sh), so hand QEMU the kernel, the initramfs and a cmdline
    # that mounts the root by LABEL. os-autoinst passes KERNEL/INITRD/APPEND
    # straight through to qemu (backend/qemu.pm).
    VARS[KERNEL]=$E2E_HOST_KERNEL
    VARS[INITRD]=$E2E_HOST_INITRD
    VARS[APPEND]=$E2E_HOST_APPEND
    # BOOTFROM is irrelevant with -kernel, and there is no ISO: QEMU boots the
    # kernel directly. BOOTFROM=disk is the honest value rather than leaving
    # the ISO-era default behind.
    VARS[BOOTFROM]=c
    # os-autoinst's storage preflight sums HDDSIZEGB*NUMDISKS (40 GiB) and
    # compares against a ratio of total space; relax the absolute floor so the
    # preflight measures what it says it measures.
    VARS[STORAGE_KEEP_FREE_GB]=10
fi

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
if [ "$RELEASE" -eq 1 ]; then
    VARS[E2E_RELEASE]=1
fi
VARS[E2E_PROFILE]=$PROFILE
if [ "$OFFLINE" -eq 1 ]; then
    # Phase 3 switches: instantOS live ISO under test, no NIC at all, and
    # the modules branch on E2E_OFFLINE (boot into the shipped installer,
    # install from the on-ISO bundle, assert no file:// remnants).
    # OFFLINE_SUT is os-autoinst's supported networkless switch (QEMU
    # -net none); NICTYPE=none is not a valid value.
    VARS[E2E_OFFLINE]=1
    VARS[OFFLINE_SUT]=1
fi
for kv in "${PASSTHROUGH[@]}"; do VARS[${kv%%=*}]=${kv#*=}; done

# --- isotovideo invocation -------------------------------------------------
# run_isotovideo <casedir-container-path> <host-casedir-dir> [VAR=VALUE ...]
# The host casedir dir is mounted read-write at /tests (isotovideo writes its
# run state into it); assets and the shared needle/module library are mounted
# read-only, and the non-live flows additionally get /e2e (writable work dir +
# the prepared host images).
run_isotovideo() {
    local casedir_path="$1" host_casedir="$2"
    shift 2
    local -a mounts=(-v "$host_casedir:$casedir_path")
    if [ "$FLOW" != live ]; then
        # /e2e must be writable: the HDD_1 backing file and the converted
        # target disk are opened O_RDWR by QEMU, and a read-only bind mount
        # makes SeaBIOS report "could not read the boot disk".
        mounts+=(-v "$E2E_WORK_DIR:/e2e")
        # Nested mount for the (overridable) image directory; harmless when it
        # already lives under E2E_WORK_DIR, and required when it does not.
        mounts+=(-v "$E2E_IMAGE_DIR:/e2e/images")
    else
        mounts+=(-v "$E2E_MEDIA_DIR:/media:ro")
    fi
    mounts+=(-v "$REPO_ROOT/assets:/tests/assets:ro")

    # casedir is passed per invocation rather than from VARS: the second stage
    # boots a different harness directory (diag/verifydisk).
    local -a args=("casedir=$casedir_path")
    for k in "${!VARS[@]}"; do args+=("$k=${VARS[$k]}"); done
    args+=("$@")

    docker run --rm -w /tests --network host "${DOCKER_ARGS[@]}" \
        "${mounts[@]}" \
        registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
        --exit-status-from-test-results \
        "${args[@]}"
}

set +e
run_isotovideo /tests "$REPO_ROOT/casedir"
rc=$?
set -e

# --- second stage: boot and verify the second-disk install -----------------
# After `power('reset')` the VM comes back up in the *host* OS on vda — the new
# install is on a disk the firmware is not told about (the host image has no
# bootloader at all). So prove the install separately: flatten the target disk
# and boot it as the only disk through the existing diag/verifydisk harness,
# which runs exactly login_installed_system() + assert_core_suite(). Minutes,
# and it is the only honest way to assert "the target boots".
#
# host-ubuntu is excluded: its contract is that the installer refuses and the
# second disk is never written, so there is no install to boot. Booting the
# untouched disk would fail the login and report a broken install that never
# happened.
if [ "$FLOW" = host-arch ] && [ "$MODE" != smoke ] && [ "$rc" -eq 0 ]; then
    mkdir -p "$E2E_WORK_DIR/work"
    TARGET_RAW="$E2E_WORK_DIR/work/$HOST_STEM-target.raw"
    if [ ! -f casedir/raid/hd1 ]; then
        echo "ERROR: casedir/raid/hd1 missing — the install stage did not produce a second disk" >&2
        rc=1
    else
        echo "converting casedir/raid/hd1 -> $TARGET_RAW and booting it standalone" >&2
        rm -f "$TARGET_RAW"
        qemu-img convert -O raw casedir/raid/hd1 "$TARGET_RAW"
        if [ -n "${E2E_SKIP_VERIFY_STAGE:-}" ]; then
            echo "E2E_SKIP_VERIFY_STAGE set: not booting $TARGET_RAW" >&2
        else
            set +e
            # NEEDLES_DIR + /casedir mirror the documented diag/verifydisk
            # invocation; the target disk arrives via the /e2e work dir.
            # QEMUCPUS/QEMURAM/PASSWORD come from the *first* stage's resolved
            # values, not the shell environment: they are isotovideo vars, so a
            # `./run.sh QEMUCPUS=4 PASSWORD=…` passthrough would otherwise be
            # dropped here and the login would use the wrong password.
            docker run --rm -w /tests --network host "${DOCKER_ARGS[@]}" \
                -v "$REPO_ROOT/diag/verifydisk:/tests" \
                -v "$REPO_ROOT/casedir:/casedir:ro" \
                -v "$E2E_WORK_DIR:/e2e" \
                -v "$E2E_IMAGE_DIR:/e2e/images" \
                registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
                --exit-status-from-test-results \
                casedir=/tests NEEDLES_DIR=/casedir/needles \
                distri=arch version=202609 \
                QEMUCPUS="${VARS[QEMUCPUS]}" QEMURAM="${VARS[QEMURAM]}" \
                BOOTFROM=c \
                HDD_1="/e2e/work/$HOST_STEM-target.raw" \
                PASSWORD="${VARS[PASSWORD]}" \
                $([ "$KVM" -eq 1 ] || echo qemu_no_kvm=1) \
                E2E_TARGET_DISK=/dev/vda
            vrc=$?
            set -e
            sudo -n chown -R "${USER}:$(id -gn)" "$REPO_ROOT/diag/verifydisk" 2>/dev/null || true
            if [ "$vrc" -ne 0 ]; then
                echo "ERROR: second-disk install failed verification (see diag/verifydisk/testresults)" >&2
                rc=$vrc
            fi
        fi
    fi
fi

# The container runs as root; give artifacts back to the invoking user.
# -n: never hang waiting for a password. If this fails, say so loudly —
# root-owned leftovers will break the NEXT run's cleanup.
if ! sudo -n chown -R "${USER}:$(id -gn)" casedir 2>/dev/null; then
    echo "WARNING: could not chown casedir artifacts (no passwordless sudo?);" >&2
    echo "         run 'sudo chown -R $(id -u):\$(id -g) casedir' before the next run" >&2
fi
exit "$rc"
