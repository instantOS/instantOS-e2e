#!/usr/bin/env bash
# Build a minimal, direct-kernel-bootable Arch x86_64 root disk for the
# `--host-arch` flow: run.sh boots it as /dev/vda, injects `ins`, and installs
# instantOS onto /dev/vdb.
#
# Why not an ISO: the flow under test is "install from an already-running OS",
# so the medium only needs to produce a *running Arch with a real root
# filesystem*. Building the rootfs from the already-pulled `archlinux:latest`
# docker base image and packing it with `mkfs.ext4 -d` is reproducible, needs no
# ISO download, no loop/nbd device and no cloud-init, and produces a ~1 GiB
# image instead of a 1.5 GiB ISO.
#
# EXACTLY WHAT IS BAKED IN (the test's value depends on knowing the starting
# state — see docs/FINDINGS.md "non-live install characterisation"):
#   base          archlinux:latest (pacman 7.x, systemd 261, glibc, bash,
#                 e2fsprogs, util-linux, iproute2, iputils, procps-ng, curl,
#                 ca-certificates, kmod)
#   added         linux (kernel + mkinitcpio initramfs)
#                 arch-install-scripts  -> pacstrap, arch-chroot, genfstab
#                 fzf, gum              -> the dialog helpers the installer
#                                            shells out to (off-ISO the code
#                                            assumes they are present)
#                 gdisk                -> provides cfdisk, the interactive
partitioner fallback
#                 btrfs-progs, ntfsprogs-> FS helpers the installer probes for
#   NOT added     no bootloader at all (QEMU direct kernel boot)
#                 no bootloader-related host packages, nothing instantOS
#   configured    root password = $PASSWORD, hostname ins-e2e-host,
#                 machine-id (generated, needed by the initramfs build),
#                 DHCP via systemd-networkd + systemd-resolved (NIC matched by
#                 driver, not name — see the 10-e2e.network below),
#                 serial getty on ttyS0 *and* hvc0,
#                 fstab with a single LABEL= root entry
#
# Output (all under $E2E_IMAGE_DIR, default ../e2e-work/images):
#   arch-host.img        GPT disk, 1 ext4 partition LABEL=e2earch
#   arch-host/vmlinuz    copied out of /boot (QEMU reads it host-side)
#   arch-host/initrd.img
#   arch-host.env        KERNEL/INITRD/APPEND/labels, sourced by run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# E2E_WORK_DIR first, then E2E_IMAGE_DIR: run.sh resolves the image directory
# from E2E_WORK_DIR, so deriving it any other way makes the builder write the
# image somewhere run.sh will not look (which is exactly what happens in CI,
# where E2E_WORK_DIR points inside the workspace).
E2E_WORK_DIR="${E2E_WORK_DIR:-$(cd "$REPO_ROOT/.." && pwd)/e2e-work}"
E2E_IMAGE_DIR="${E2E_IMAGE_DIR:-$E2E_WORK_DIR/images}"
PASSWORD="${PASSWORD:-correct-horse-battery-staple}"

# Disk geometry. Sized well above the ~1.2 GiB installed tree so a pacstrap
# onto the *other* disk and a few writes have room without the image growing.
IMG_SIZE_MB=3072
PART_START_MB=1
FS_SIZE_MB=$((IMG_SIZE_MB - PART_START_MB))

STEM=arch-host
LABEL=e2earch
BASE_IMAGE=archlinux:latest

# --- what goes into the image, built inside the container -------------------
# Kept in a variable (not a heredoc file) so the whole rootfs recipe is visible
# in one place; $PASSWORD is expanded inside the container from the env.
read -r -d '' ROOTFS_BUILD <<'BUILD' || true
set -eux
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

# Refresh the db, then the harness prerequisites listed in the header.
pacman -Syy --noconfirm --needed
pacman -S --noconfirm --needed --overwrite '*' \
    linux arch-install-scripts fzf gum gdisk btrfs-progs ntfsprogs

# machine-id must exist before mkinitcpio: the hook scripts parse
# /etc/machine-id and fail without it.
systemd-machine-id-setup
test -s /etc/machine-id

# Identity. ins-e2e-host is deliberately NOT ins-e2e-vm: the installed-login
# needle bakes in the installed system's hostname, and conflating the two
# would make a mistake (logging into the host instead of the target) invisible.
echo ins-e2e-host > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tins-e2e-host\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts

# Throwaway root credential, same value the questions fixtures use.
echo "root:${E2E_HOST_PASSWORD}" | chpasswd

# Serial console on BOTH the UART and the virtio console. The harness drives
# everything over hvc0 (text matching, no needles); ttyS0 is a second,
# independent view that lands in casedir/serial0 for debugging.
systemctl --root=/ enable serial-getty@ttyS0.service serial-getty@hvc0.service

# Networking: systemd-networkd + resolved is the smallest thing that gives us
# DHCP and DNS without pulling NetworkManager.
# Match the driver, not the interface name. os-autoinst single-quotes an
# -append value that contains whitespace and the kernel then parses the whole
# cmdline as one argument, so net.ifnames=0 is not available and the NIC comes
# up with a predictable-but-not-guaranteed name (enp0s2 &c.).
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

# Single-partition root; QEMU passes root=LABEL= so this is what the guest
# mounts. No bootloader entries: the harness never boots this disk via BIOS.
printf 'LABEL=e2earch / ext4 defaults 0 1\n' > /etc/fstab
: > /etc/mtab

# The initramfs is what QEMU loads as INITRD; generate it last so it contains
# the final /etc/machine-id.
#
# archlinux:latest ships NO /etc/mkinitcpio.conf, so the linux package hook
# happily builds an image with HOOKS="" - an initramfs with kernel modules and
# no init at all, which boots to nothing. Write the config explicitly. No
# `autodetect` hook either: it profiles the *build* machine (a docker
# container), not the guest, so the guest's virtio drivers have to be named.
cat > /etc/mkinitcpio.conf <<'CONF'
MODULES=(virtio_pci virtio_blk virtio_net virtio_console ext4)
BINARIES=()
FILES=()
HOOKS=(base udev modconf kms block filesystems fsck)
COMPRESS=zstd
CONF
mkinitcpio -P linux
# Prove the image has an init before it can silently reach the guest: an
# initramfs built with HOOKS="" is just a bag of modules and boots to nothing,
# which cost one debugging round. List to a file first (a `| grep -q` pipeline
# makes grep exit early, the writer take SIGPIPE, and `pipefail` kill the
# build) and turn a miss into a message instead of a silent non-zero exit.
lsinitcpio /boot/initramfs-linux.img > /tmp/ird.list
wc -l /tmp/ird.list
head -n 8 /tmp/ird.list
grep -qx init /tmp/ird.list || { echo 'FATAL: no /init in the generated initramfs' >&2; exit 1; }
lsinitcpio /boot/initramfs-linux.img | grep initcpio | head -n 5 || true
ls -la /boot/initramfs-linux.img

# Stage the kernel pair under stable, non-versioned names: QEMU reads these
# from the HOST side, so they must not depend on the exported tree surviving
# intact.
mkdir -p /e2eboot
cp -L /boot/vmlinuz-linux /e2eboot/vmlinuz
cp -L /boot/initramfs-linux.img /e2eboot/initrd.img
chmod 0644 /e2eboot/vmlinuz /e2eboot/initrd.img

# Trim: the image is copied, not pacman-cached.
rm -rf /var/cache/pacman/pkg/*
BUILD

echo "building ${STEM}.img from ${BASE_IMAGE} (container + mkfs.ext4 -d)" >&2

CTR="e2e-mkhost-arch-$$"
# Staging lives next to the images (NOT /tmp: a rootfs is >1 GiB and this host's
# /tmp is a 16 GiB tmpfs with ~3 GiB free).
STAGE_PARENT="${E2E_STAGE_DIR:-$(dirname "$E2E_IMAGE_DIR")}"
mkdir -p "$STAGE_PARENT"
ROOTFS="$(mktemp -d "$STAGE_PARENT/mkhost-arch.XXXXXX")"
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

# 1. Rootfs: install + configure inside the container, then export the result.
#    `docker export` walks the merged container filesystem but leaves the
#    tmpfs mount points (/proc /sys /dev /run) as empty directories, which is
#    exactly what we want in a disk image.
docker create --name "$CTR" -e E2E_HOST_PASSWORD="$PASSWORD" "$BASE_IMAGE" \
    bash -c "$ROOTFS_BUILD" >/dev/null
# `docker start -a` returns the container's exit status, and `set -e` would
# abort the build without saying which step failed: check it and name it.
if ! docker start -a "$CTR" >&2; then
    echo "ERROR: the rootfs build step failed inside $BASE_IMAGE (see above)" >&2
    exit 1
fi
docker export "$CTR" | sudo tar -x -C "$STAGE"

# The kernel + initramfs must be readable by QEMU on the HOST side, so copy
# them out next to the image rather than relying on a mount of the image.
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
#       The last usable GPT sector is 6293470, but 6293503 is requested.
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
# generated by tools/mkhost-arch.sh — sourced by run.sh for --host-arch
E2E_HOST_IMAGE=/e2e/images/$STEM.img
E2E_HOST_KERNEL=/e2e/images/$STEM/vmlinuz
E2E_HOST_INITRD=/e2e/images/$STEM/initrd.img
# Quoted: run.sh sources this file and the cmdline has spaces in it.
# ONE token on purpose: os-autoinst's gen_params single-quotes an -append
# value that contains whitespace, and the kernel then parses the whole cmdline
# as a single argument (root= is not recognised, no console is set up). So the
# kernel cmdline carries only the root device; console= and net.ifnames come
# from the image instead (getty on hvc0 is enabled explicitly below, and
# systemd-networkd matches the NIC by driver).
E2E_HOST_APPEND="root=LABEL=$LABEL"
EOF

echo "wrote $E2E_IMAGE_DIR/$STEM.img ($(du -h "$E2E_IMAGE_DIR/$STEM.img" | cut -f1))" >&2
echo "wrote $E2E_IMAGE_DIR/$STEM.env" >&2
