#!/usr/bin/env bash
# Build a minimal, direct-kernel-bootable Ubuntu 24.04 x86_64 root disk for
# the `--host-ubuntu` flow: run.sh boots it as /dev/vda, injects `ins`, and
# tries to install instantOS onto /dev/vdb — from a *foreign* distro.
#
# Why not an ISO: same reasoning as tools/mkhost-arch.sh — the medium only has
# to produce a running Ubuntu with a real root filesystem. Built from the
# already-pulled `ubuntu:24.04` docker base image and packed with
# `mkfs.ext4 -d`: no ISO download, no loop/nbd, no cloud-init, ~1.5 GiB, and
# structurally identical to the Arch image so the two flows differ only in the
# distro under test.
#
# THIS IMAGE IS DELIBERATELY PRISTINE. The entire point of the Ubuntu flow is
# to exercise the product's own bootstrap of the Arch toolchain; baking
# `arch-install-scripts` / `pacman` / `archlinux-keyring` in would make the
# test lie about what the installer has to do. The following is what Ubuntu
# 24.04 (noble) *could* give the installer via apt, verified with
# `apt-cache policy` on this host:
#
#   arch-install-scripts:      Candidate: 28-1              (noble/universe)
#   pacman-package-manager:    Candidate: 6.0.2-6ubuntu2    (noble/universe)
#   archlinux-keyring:         Candidate: 0~20240313-1     (noble/universe)
#   btrfs-progs:               Installed: 6.6.3-1.1build2  (noble/main)
#   gdisk, ntfsprogs, util-linux:                          (noble/main)
#
# None of the Arch toolchain is installed here. The Arch image does carry the
# same prerequisites, because on Arch they are expected to be present already;
# both facts are recorded in docs/FINDINGS.md so a run is interpretable.
#
# EXACTLY WHAT IS BAKED IN:
#   base          ubuntu:24.04 (bash, coreutils, util-linux, dpkg/apt)
#   added         systemd-sysv, udev  -> /sbin/init and the getty generator
#                 linux-generic      -> the kernel
#                 initramfs-tools    -> update-initramfs (only a Recommends of
#                                            linux-image-*, so named explicitly)
#                 ca-certificates, curl, kmod, procps, iproute2,
#                 iputils-ping       -> harness essentials only
#   NOT added     no arch-install-scripts, no pacman, no archlinux-keyring,
#                 no fzf/gum/cfdisk  (see above)
#   configured    root password = $PASSWORD, hostname ins-e2e-host,
#                 machine-id, DHCP via systemd-networkd + resolved (NIC matched
#                 by driver, not name — see the 10-e2e.network below),
#                 serial getty on ttyS0 *and* hvc0, fstab with a LABEL= root
#   no bootloader installed (QEMU direct kernel boot)
#
# Output (all under $E2E_IMAGE_DIR, default ../e2e-work/images):
#   ubuntu-host.img        GPT disk, 1 ext4 partition LABEL=e2eubuntu
#   ubuntu-host/vmlinuz    (copied out of /boot, name is versioned there)
#   ubuntu-host/initrd.img
#   ubuntu-host.env        KERNEL/INITRD/APPEND/labels, sourced by run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# E2E_WORK_DIR first, then E2E_IMAGE_DIR: run.sh resolves the image directory
# from E2E_WORK_DIR, so deriving it any other way makes the builder write the
# image somewhere run.sh will not look (which is exactly what happens in CI,
# where E2E_WORK_DIR points inside the workspace).
E2E_WORK_DIR="${E2E_WORK_DIR:-$(cd "$REPO_ROOT/.." && pwd)/e2e-work}"
E2E_IMAGE_DIR="${E2E_IMAGE_DIR:-$E2E_WORK_DIR/images}"
PASSWORD="${PASSWORD:-correct-horse-battery-staple}"

IMG_SIZE_MB=4096
PART_START_MB=1
FS_SIZE_MB=$((IMG_SIZE_MB - PART_START_MB))

STEM=ubuntu-host
LABEL=e2eubuntu
BASE_IMAGE=ubuntu:24.04

# --- what goes into the image, built inside the container -------------------
read -r -d '' ROOTFS_BUILD <<'BUILD' || true
set -eux
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

apt-get update
# systemd-sysv gives /sbin/init + the getty generator, udev gives /dev, and
# linux-generic brings a kernel with an update-initramfs initramfs. Everything
# else is a harness essential. Nothing Arch-related, on purpose.
# initramfs-tools is explicit: on noble it is only a Recommends of
# linux-image-*, so --no-install-recommends leaves the guest with a kernel and
# no initrd (and the postinst silently produces no /boot/initrd.img-*).
apt-get install -y --no-install-recommends \
    systemd-sysv systemd-resolved udev linux-generic initramfs-tools \
    ca-certificates curl kmod procps iproute2 iputils-ping

# machine-id first: the initramfs' init and any systemd unit that resolves the
# host expect it to exist.
systemd-machine-id-setup
test -s /etc/machine-id

# Identity. ins-e2e-host matches the Arch host image on purpose: the two flows
# must differ only in the distro under test.
echo ins-e2e-host > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tins-e2e-host\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts

# Throwaway root credential, same value the questions fixtures use.
echo "root:${E2E_HOST_PASSWORD}" | chpasswd

# Serial console on BOTH the UART and the virtio console: the harness drives
# hvc0, ttyS0 is the independent debugging view (casedir/serial0).
systemctl --root=/ enable serial-getty@ttyS0.service serial-getty@hvc0.service

# DHCP + DNS without netplan/NetworkManager. Match the NIC by driver, not by
# name: os-autoinst single-quotes an -append value that contains whitespace and
# the kernel then parses the whole cmdline as one argument, so net.ifnames=0
# is not available and the NIC comes up as a predictable-but-not-guaranteed
# name. /etc/resolv.conf is a docker bind mount in here and must be replaced by
# the resolved stub.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-e2e.network <<'NET'
[Match]
Driver=virtio_net

[Network]
DHCP=yes
NET
systemctl --root=/ enable systemd-networkd.service systemd-resolved.service
# /etc/resolv.conf is a docker bind mount inside the container, so it
# cannot be replaced by a symlink (EBUSY) -- write the stub address
# instead; on the guest systemd-resolved is listening on it.
rm -f /etc/resolv.conf 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || \
    printf 'nameserver 127.0.0.53\noptions edns0\n' > /etc/resolv.conf

# Single-partition root; QEMU passes root=LABEL=, so the label is the contract.
printf 'LABEL=e2eubuntu / ext4 defaults 0 1\n' > /etc/fstab
: > /etc/mtab

# Stage the kernel pair somewhere with stable, non-versioned names. QEMU reads
# these files from the HOST side, so they must not depend on the exported tree
# at all (and /boot/vmlinuz is a symlink on noble). The virtio + ext4 modules
# are named explicitly because MODULES=most would profile this container, not
# the guest.
mkdir -p /etc/initramfs-tools/conf.d
# /etc/initramfs-tools/modules is a FILE listing modules to bundle (the
# directory is modules.d) — do not mkdir it.
rm -rf /etc/initramfs-tools/modules
cat > /etc/initramfs-tools/modules <<'MOD'
virtio_pci
virtio_blk
virtio_net
virtio_console
ext4
MOD
# Take the kernel version from /boot/vmlinuz-*: linux-image's postinst does not
# generate an initrd in a build container (no /etc/modules, no running udev),
# so there is nothing under /boot/initrd.img-* to read it from.
KVER="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
test -n "$KVER"
rm -f "/boot/initrd.img-$KVER"
update-initramfs -c -k "$KVER"
test -s "/boot/initrd.img-$KVER" || {
    echo "update-initramfs produced no /boot/initrd.img-$KVER" >&2
    ls -la /boot >&2
    exit 1
}
mkdir -p /e2eboot
cp -L /boot/vmlinuz /e2eboot/vmlinuz
cp "/boot/initrd.img-$KVER" /e2eboot/initrd.img
chmod 0644 /e2eboot/vmlinuz /e2eboot/initrd.img
ls -la /e2eboot

# Trim: the image is copied, not an apt cache.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
BUILD

echo "building ${STEM}.img from ${BASE_IMAGE} (container + mkfs.ext4 -d)" >&2

CTR="e2e-mkhost-ubuntu-$$"
STAGE_PARENT="${E2E_STAGE_DIR:-$(dirname "$E2E_IMAGE_DIR")}"
mkdir -p "$STAGE_PARENT"
ROOTFS="$(mktemp -d "$STAGE_PARENT/mkhost-ubuntu.XXXXXX")"
PARTIMG="$ROOTFS.part.img"
STAGE="$ROOTFS.stage"
cleanup() {
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    # The staged rootfs is full of root-owned files, so this needs sudo; fall
    # back to a plain rm so a host without passwordless sudo still works.
    sudo -n rm -rf "$ROOTFS" "$PARTIMG" "$STAGE" 2>/dev/null || rm -rf "$ROOTFS" "$PARTIMG" "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE"

docker create --name "$CTR" -e E2E_HOST_PASSWORD="$PASSWORD" "$BASE_IMAGE" \
    bash -c "$ROOTFS_BUILD" >/dev/null
# `docker start -a` returns the container's exit status, and `set -e` would
# abort the build without saying which step failed: check it and name it.
if ! docker start -a "$CTR" >&2; then
    echo "ERROR: the rootfs build step failed inside $BASE_IMAGE (see above)" >&2
    exit 1
fi
docker export "$CTR" | sudo tar -x -C "$STAGE"

# Lift the staged kernel pair out. KVER is only used for the log line.
KVER="$(basename "$(readlink -f "$STAGE/boot/vmlinuz" 2>/dev/null || echo unknown)" |
    sed 's/^vmlinuz-//')"
mkdir -p "$E2E_IMAGE_DIR/$STEM"
sudo cp "$STAGE/e2eboot/vmlinuz" "$E2E_IMAGE_DIR/$STEM/vmlinuz"
sudo cp "$STAGE/e2eboot/initrd.img" "$E2E_IMAGE_DIR/$STEM/initrd.img"
sudo chown -R "$(id -u):$(id -g)" "$E2E_IMAGE_DIR/$STEM"
sudo chmod 0644 "$E2E_IMAGE_DIR/$STEM/vmlinuz" "$E2E_IMAGE_DIR/$STEM/initrd.img"

# --- image assembly ---------------------------------------------------------
# Getting these two sizes to agree is the whole difficulty, and getting it
# wrong is invisible until the guest refuses to boot:
#   e2earch: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY
#   ERROR: Bailing out. Run 'fsck LABEL=%LABEL%' manually
#
#   * mke2fs rounds the block count UP to a whole flex_bg group (128 MiB at a
#     4 KiB block size), so a filesystem built in a file of N bytes can claim
#     more than N. Size the filesystem to a 128 MiB multiple and the partition
#     to the same value, and the rounding is a no-op.
#   * sfdisk sizes a `,,L` partition by alignment, which lands *below* the
#     arithmetic result. Give it the start and size explicitly instead.
#   * GPT keeps the last 33 sectors of the disk for its backup header and
#     partition array, so a partition that ends on the very last sector has
#     nowhere to put them and sfdisk refuses outright:
#       The last usable GPT sector is 8390622, but 8390655 is requested.
#       Failed to add #1 partition: Invalid argument
#     That is silent-ish: `truncate` has already sized the file, so the run
#     dies here with an image that has no partition table at all. Reserve a
#     whole MiB at the tail for the backup GPT.
FLEX_MB=128
GPT_RESERVE_MB=1
FS_MB=$((((FS_SIZE_MB * 1048576 + FLEX_MB * 1048576 - 1) / (FLEX_MB * 1048576)) * FLEX_MB))
IMG_SIZE_MB=$((PART_START_MB + FS_MB + GPT_RESERVE_MB))
PART_SECTORS=$((FS_MB * 2048)) # MiB -> 512-byte sectors
PART_START_SECTOR=$((PART_START_MB * 2048))

truncate -s "${IMG_SIZE_MB}M" "$E2E_IMAGE_DIR/$STEM.img"
printf 'label: gpt\nstart=%d, size=%d, type=linux\n' \
    "$PART_START_SECTOR" "$PART_SECTORS" |
    sudo sfdisk --no-reread --no-tell-kernel "$E2E_IMAGE_DIR/$STEM.img" >/dev/null
read -r GOT_START GOT_BYTES <<<"$(sudo sfdisk --json "$E2E_IMAGE_DIR/$STEM.img" |
    python3 -c 'import json,sys
d = json.load(sys.stdin)["partitiontable"]
p = d["partitions"][0]
print(p["start"] * d["sectorsize"], p["size"] * d["sectorsize"])')"
echo "filesystem $FS_MB MiB; partition 1 starts at byte $GOT_START, is $GOT_BYTES bytes" >&2
[ "$GOT_START" = "$((PART_START_MB * 1048576))" ] ||
    {
        echo "ERROR: partition does not start where PART_START_MB=$PART_START_MB says" >&2
        exit 1
    }
[ "$GOT_BYTES" = "$((FS_MB * 1048576))" ] ||
    {
        echo "ERROR: partition is $GOT_BYTES bytes, expected $((FS_MB * 1048576))" >&2
        exit 1
    }
# Belt and braces on the backup-GPT reserve above: if someone retunes
# GPT_RESERVE_MB to 0 this fails here with an explanation instead of leaving an
# sfdisk "Invalid argument" three steps up.
LAST_USABLE_SECTOR=$((IMG_SIZE_MB * 2048 - 34)) # 33 backup-GPT sectors + 1
[ $((PART_START_SECTOR + PART_SECTORS - 1)) -le "$LAST_USABLE_SECTOR" ] ||
    {
        echo "ERROR: partition ends at sector $((PART_START_SECTOR + PART_SECTORS - 1)) but the" >&2
        echo "       last usable GPT sector is $LAST_USABLE_SECTOR — raise GPT_RESERVE_MB" >&2
        exit 1
    }

truncate -s "$GOT_BYTES" "$PARTIMG"
sudo mkfs.ext4 -q -F -L "$LABEL" -m 0 -E lazy_itable_init=1,lazy_journal_init=1 \
    -d "$STAGE" "$PARTIMG"

# Verify the geometry instead of trusting it: compare what the superblock
# claims against the device it will live on, then let e2fsck have a look.
read -r FS_BLOCKS FS_BLOCKSIZE <<<"$(sudo dumpe2fs -h "$PARTIMG" 2>/dev/null | awk '
    /^Block count:/ { bc = $3 }
    /^Block size:/  { bs = $3 }
    END { print bc, bs }')"
DEV_BLOCKS=$((GOT_BYTES / FS_BLOCKSIZE))
if [ "$FS_BLOCKS" -gt "$DEV_BLOCKS" ]; then
    echo "ERROR: the filesystem claims $FS_BLOCKS x ${FS_BLOCKSIZE}B blocks but the" >&2
    echo "       partition only holds $DEV_BLOCKS — the guest would refuse to mount it" >&2
    exit 1
fi
sudo e2fsck -fn "$PARTIMG" >/tmp/e2e-mkhost-e2fsck.log 2>&1 || true
if grep -q 'likely to be corrupt' /tmp/e2e-mkhost-e2fsck.log; then
    echo "ERROR: the generated ext4 is inconsistent with its size" >&2
    cat /tmp/e2e-mkhost-e2fsck.log >&2
    exit 1
fi
tail -n 1 /tmp/e2e-mkhost-e2fsck.log >&2

sudo dd if="$PARTIMG" of="$E2E_IMAGE_DIR/$STEM.img" bs=1M \
    seek="$PART_START_MB" conv=notrunc status=none
sudo chown "$(id -u):$(id -g)" "$E2E_IMAGE_DIR/$STEM.img"
sudo fdisk -l "$E2E_IMAGE_DIR/$STEM.img" >&2

cat >"$E2E_IMAGE_DIR/$STEM.env" <<EOF
# generated by tools/mkhost-ubuntu.sh — sourced by run.sh for --host-ubuntu
E2E_HOST_IMAGE=/e2e/images/$STEM.img
E2E_HOST_KERNEL=/e2e/images/$STEM/vmlinuz
E2E_HOST_INITRD=/e2e/images/$STEM/initrd.img
# ONE whitespace-free token on purpose — identical to the arch builder, and for
# the same reason. os-autoinst's gen_params single-quotes an -append value that
# contains whitespace, the kernel then receives the quotes as part of the first
# argument, and `root=` is not recognised: the guest drops to an initramfs
# shell with no console. So the cmdline carries the root device only; console=
# and the NIC name come from the image (serial-getty@hvc0 is enabled above and
# systemd-networkd matches on Driver=virtio_net). A previous revision of this
# file emitted "root=... rw console=hvc0 console=ttyS0 net.ifnames=0
# biosdevname=0" here, which contradicts the comment in ROOTFS_BUILD above and
# cannot boot.
E2E_HOST_APPEND="root=LABEL=$LABEL"
EOF

echo "wrote $E2E_IMAGE_DIR/$STEM.img ($(du -h "$E2E_IMAGE_DIR/$STEM.img" | cut -f1))" >&2
echo "wrote $E2E_IMAGE_DIR/$STEM.env (kernel $KVER)" >&2
