#!/usr/bin/env bash
set -euxo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Refresh the db, then the harness prerequisites listed in the header.
pacman -Syu --noconfirm --needed --overwrite '*' \
    linux arch-install-scripts fzf gum gdisk btrfs-progs ntfsprogs

. /recipe/common.sh

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
COMPRESSION=zstd
CONF
mkinitcpio -P linux
# Prove the image has an init before it can silently reach the guest: an
# initramfs built with HOOKS="" is just a bag of modules and boots to nothing,
# which cost one debugging round. List to a file first (a `| grep -q` pipeline
# makes grep exit early, the writer take SIGPIPE, and `pipefail` kill the
# build) and turn a miss into a message instead of a silent non-zero exit.
lsinitcpio /boot/initramfs-linux.img > /tmp/ird.list
grep -qx init /tmp/ird.list || { echo 'FATAL: no /init in the generated initramfs' >&2; exit 1; }
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
