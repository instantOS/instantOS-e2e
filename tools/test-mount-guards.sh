#!/bin/bash
# Regression test for the mount guards in the bootstrap prototype script.
#
# On 2026-09-26 `bootstrap-proto.sh` wiped the host's /dev and /run: it
# `mount --rbind`ed them into a scratch dir, leaked those mounts when it died
# partway, and then a later run's `rm -rf "$SCRATCH"` descended through them
# and deleted every device node on the machine. See ../warning.md.
#
# This test exercises the guards themselves, not a copy of them: the guard
# block is extracted from the script by marker and sourced.
#
#   ./tools/test-mount-guards.sh [path/to/bootstrap-proto.sh]
#
# Note what that means in practice: the script under test is the bootstrap
# prototype, which lives OUTSIDE this repository (it is a scratch tool, not
# part of the e2e suite). With no path given the script looks in
# $E2E_BOOTSTRAP_PROTO or $HOME/stuff/e2e-work/bootstrap-proto.sh, and SKIPs
# when it is not there — so in CI, and on any checkout without the scratch
# tree, this reports SKIP rather than passing. The mount hazard itself is
# documented in ../warning.md; this is a regression test for one host's
# prototype, not a suite invariant.
#
# Tier 1 runs anywhere: pure-logic checks against a synthetic mount table.
# Tier 2 needs root (it creates a real bind mount to prove the delete refuses
# to follow it) and is skipped otherwise.
set -uo pipefail

SCRIPT=${1:-${E2E_BOOTSTRAP_PROTO:-$HOME/stuff/e2e-work/bootstrap-proto.sh}}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "  PASS  $1"; }
bad() {
    echo "  FAIL  $1"
    fails=$((fails + 1))
}
skip() { echo "  SKIP  $1"; }

if [ ! -r "$SCRIPT" ]; then
    echo "SKIP: no bootstrap script at '$SCRIPT'."
    echo "      This prototype lives outside the repo; pass its path as \$1."
    exit 0
fi

# Extract the real guard block: from the "guard 2" banner to just before the
# first call into it. Markers, not line numbers, so editing the script's
# comments cannot silently shift the slice.
sed -n '/^# --- guard 2: /,/^safe_rm_rf "\$B"/p' "$SCRIPT" |
    sed '$d' >"$WORK/guards.sh"

if ! grep -q '^safe_rm_rf()' "$WORK/guards.sh"; then
    echo "FAIL: could not extract the guard block from '$SCRIPT'."
    echo "      Expected to find safe_rm_rf() between the guard 2 banner and"
    echo "      the first 'safe_rm_rf \"\$B\"' call. Did the script change shape?"
    exit 1
fi

die() {
    echo "bootstrap-proto: $*" >&2
    exit 1
}
# shellcheck source=/dev/null
. "$WORK/guards.sh"

W="$WORK/tree"
mkdir -p "$W"

# A synthetic /proc/self/mounts: "device mountpoint fstype opts dump pass",
# so field 2 is the mount point. Models the real incident -- $W/boot/{dev,run}
# are live aliases of host directories, with a nested mount under run.
cat >"$WORK/table" <<EOF
sysfs /sys sysfs rw 0 0
tmpfs /run tmpfs rw 0 0
proc /proc proc rw 0 0
udev /dev devtmpfs rw 0 0
devpts /dev/pts devpts rw 0 0
canary $W/boot/dev none rw 0 0
canary $W/boot/run none rw 0 0
tmpfs $W/boot/run/qemu tmpfs rw 0 0
EOF

echo "== tier 1: guard logic (no privileges needed) =="

echo "-- mounts_under matches only strict descendants"
got=$(mounts_under "$W/boot" "$WORK/table" | tr '\n' ' ')
want="$W/boot/dev $W/boot/run $W/boot/run/qemu "
[ "$got" = "$want" ] && ok "found exactly the descendants" || bad "got '$got' want '$want'"

got=$(mounts_under "$W/canary" "$WORK/table")
[ -z "$got" ] && ok "sibling with no mounts reports none" || bad "sibling matched: $got"

got=$(mounts_under "$W" "$WORK/table" | tr '\n' ' ')
want="$W/boot/dev $W/boot/run $W/boot/run/qemu "
[ "$got" = "$want" ] && ok "does not match the prefix dir itself" || bad "got '$got' want '$want'"

got=$(mounts_under "$W/nonexistent" "$WORK/table")
[ -z "$got" ] && ok "absent dir reports no mounts" || bad "got '$got'"

echo "-- assert_in_work_dir scopes the delete"
# NB: capture rather than pipe. Under `set -o pipefail` a pipeline inherits the
# subshell's expected exit 1 and would report failure on a correct refusal.
out=$( (assert_in_work_dir /etc) 2>&1)
grep -q "not inside the work dir" <<<"$out" && ok "rejects /etc" || bad "did not reject /etc: $out"
out=$( (assert_in_work_dir /) 2>&1)
grep -q "not inside" <<<"$out" && ok "rejects /" || bad "did not reject /: $out"
[ -z "$( (assert_in_work_dir "$W/boot") 2>&1)" ] &&
    ok "accepts a path under \$W" || bad "rejected a legitimate path under \$W"

echo "-- release_mounts unwinds in reverse creation order"
calls=()
umount_quietly() { calls+=("$1"); }
# shellcheck disable=SC2034  # read by track()/release_mounts in the sourced block
MOUNTS=()
track /a
track /b
track /c
release_mounts
[ "${calls[*]}" = "/c /b /a" ] && ok "reverse order: ${calls[*]}" || bad "got '${calls[*]}'"
calls=()
release_mounts
[ "${#calls[@]}" -eq 0 ] && ok "empty MOUNTS is a safe no-op" || bad "unexpected: ${calls[*]}"

echo "-- safe_rm_rf refuses paths outside the work dir"
mkdir -p "$W/keep"
touch "$W/keep/canary"
out=$( (
    # shellcheck disable=SC2034  # read by release_stale_mounts in the sourced block
    E2E_BOOTSTRAP_MNTNS=
    safe_rm_rf /etc
) 2>&1)
grep -q "not inside" <<<"$out" && ok "refused /etc" || bad "did not refuse /etc: $out"

echo "== tier 2: refuses to delete through a real mount (needs root) =="

# A real bind mount, with a canary on the far side. If the delete followed the
# mount, the canary would be destroyed -- which is the whole bug.
mkdir -p "$W/real/victim/mnt" "$W/real/canary"
echo precious >"$W/real/canary/canary.txt"

if ! mount --bind "$W/real/canary" "$W/real/victim/mnt" 2>&1; then
    skip "cannot bind mount as uid $(id -u); re-run with sudo for full coverage"
else
    W="$W/real"
    mountpoint -q "$W/victim/mnt" && ok "fixture: live bind mount in place" || bad "fixture missing"

    # The real table must be what stops us, so no override here.
    out=$( (safe_rm_rf "$W/victim") 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] && ok "safe_rm_rf refused (rc=$rc)" || bad "safe_rm_rf did NOT refuse"
    [ -f "$W/canary/canary.txt" ] && ok "canary on the far side survived" ||
        bad "canary destroyed -- the delete followed the mount"
    [ -d "$W/victim" ] && ok "scratch dir not deleted" || bad "scratch dir was deleted"

    # Even claiming to be in a namespace, when the detach cannot actually
    # happen, the post-detach re-check must still stop the delete. This is the
    # backstop that holds if the namespace guard is ever removed.
    out=$( (
        # shellcheck disable=SC2034  # read by release_stale_mounts in the sourced block
        E2E_BOOTSTRAP_MNTNS=1
        safe_rm_rf "$W/victim"
    ) 2>&1)
    grep -q "a mount is still live underneath it" <<<"$out" &&
        ok "refused by the post-detach re-check too" || bad "re-check did not fire: $out"
    [ -f "$W/canary/canary.txt" ] && ok "canary still survived" || bad "canary destroyed"

    umount -R "$W/victim/mnt"
    mountpoint -q "$W/victim/mnt" && bad "fixture mount left behind" || ok "fixture released"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "PASS: all mount-guard tests passed"
else
    echo "FAIL: $fails mount-guard test(s) failed"
    exit 1
fi
