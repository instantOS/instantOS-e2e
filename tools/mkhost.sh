#!/usr/bin/env bash
# Build a direct-kernel-bootable host disk without host mounts or loop devices.
# Each bundle contains disk.img, vmlinuz and initrd.img. See README.md.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_ROOT/tools/lib/paths.sh"
. "$REPO_ROOT/tools/lib/fixtures.sh"
case "${1:-}" in
    arch) BASE_IMAGE=archlinux:latest; FS_MB=3072 ;;
    ubuntu) BASE_IMAGE=ubuntu:24.04; FS_MB=4096 ;;
    *) echo 'Usage: tools/mkhost.sh arch|ubuntu' >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo 'Expected one distro argument' >&2; exit 2; }
DISTRO=$1
LABEL=e2e$DISTRO
HOST_PASSWORD=$(fixture_password minimal)
DEST="$E2E_IMAGE_DIR/$DISTRO-host"
exec 9>"$E2E_IMAGE_DIR/.$DISTRO-host.lock"
flock -n 9 || { echo "Another builder is writing $DEST" >&2; exit 1; }

# Build beside the destination, so publication is a rename on one filesystem.
BUILD_DIR=$(mktemp -d "$E2E_IMAGE_DIR/.$DISTRO-host.XXXXXX")
CTR="e2e-mkhost-$DISTRO-$$"
cleanup() {
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    # Restore the old bundle if publication failed or was interrupted.
    if [ -d "$BUILD_DIR/previous" ] && [ ! -e "$DEST" ]; then
        mv "$BUILD_DIR/previous" "$DEST" || {
            echo "Could not restore $DEST; previous bundle is in $BUILD_DIR/previous" >&2
            return
        }
    fi
    sudo -n rm -rf -- "$BUILD_DIR" 2>/dev/null || rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$BUILD_DIR/rootfs" "$BUILD_DIR/bundle"

echo "Building $DISTRO host from $BASE_IMAGE" >&2
docker create --name "$CTR" \
    -v "$REPO_ROOT/tools/host:/recipe:ro" \
    -e E2E_HOST_PASSWORD="$HOST_PASSWORD" \
    -e E2E_HOST_LABEL="$LABEL" \
    "$BASE_IMAGE" bash "/recipe/$DISTRO.sh" >/dev/null
docker start -a "$CTR" >&2
# docker start reports the client status; inspect the recipe's actual exit code.
[ "$(docker inspect -f '{{.State.ExitCode}}' "$CTR")" -eq 0 ] || {
    echo "Rootfs recipe failed in $BASE_IMAGE" >&2; exit 1;
}
docker export "$CTR" | sudo -n tar -x -C "$BUILD_DIR/rootfs"
sudo -n cp "$BUILD_DIR/rootfs/e2econfig/"* "$BUILD_DIR/rootfs/etc/"
sudo -n ln -sf /run/systemd/resolve/stub-resolv.conf "$BUILD_DIR/rootfs/etc/resolv.conf"
sudo -n cp "$BUILD_DIR/rootfs/e2eboot/"* "$BUILD_DIR/bundle/"
# Keep only /boot in the rootfs; the external kernel copies belong to the bundle.
sudo -n rm -rf "$BUILD_DIR/rootfs/e2eboot" "$BUILD_DIR/rootfs/e2econfig"

# Whole-MiB filesystem, 1 MiB alignment at the front, 1 MiB for backup GPT.
PARTIMG="$BUILD_DIR/partition.img"
DISK="$BUILD_DIR/bundle/disk.img"
truncate -s "${FS_MB}M" "$PARTIMG"
sudo -n mkfs.ext4 -q -F -b 4096 -L "$LABEL" -m 0 \
    -E lazy_itable_init=1,lazy_journal_init=1 -d "$BUILD_DIR/rootfs" "$PARTIMG"
# Check the filesystem by exit status, rather than grepping one error phrase.
sudo -n e2fsck -fn "$PARTIMG"
truncate -s "$((FS_MB + 2))M" "$DISK"
printf 'label: gpt\nstart=2048, size=%d, type=linux\n' "$((FS_MB * 2048))" |
    sfdisk --no-reread --no-tell-kernel "$DISK" >/dev/null
# Read back the actual geometry before copying the filesystem.
sfdisk --json "$DISK" | python3 -c '
import json, sys
pt = json.load(sys.stdin)["partitiontable"]
p = pt["partitions"][0]
assert p["start"] * pt["sectorsize"] == 1048576
assert p["size"] * pt["sectorsize"] == int(sys.argv[1]) * 1048576
' "$FS_MB"
dd if="$PARTIMG" of="$DISK" bs=1M seek=1 conv=notrunc status=none
sudo -n chown -R "$(id -u):$(id -g)" "$BUILD_DIR/bundle"
chmod 0644 "$BUILD_DIR/bundle/"*
# Keep a previously working bundle until every build and filesystem check passes.
if [ -e "$DEST" ]; then mv "$DEST" "$BUILD_DIR/previous"; fi
mv "$BUILD_DIR/bundle" "$DEST"
echo "Wrote $DEST/{disk.img,vmlinuz,initrd.img}" >&2
