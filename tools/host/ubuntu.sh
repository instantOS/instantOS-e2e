#!/usr/bin/env bash
set -euxo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

apt-get update
# systemd-sysv gives /sbin/init + the getty generator, udev gives /dev, and
# linux-image-virtual provides the VM kernel without headers or hardware firmware.
# Everything else is a harness/runtime essential, including the databases used
# to validate the questions fixture. Nothing Arch-related, on purpose.
# initramfs-tools is explicit: on noble it is only a Recommends of
# linux-image-*, so --no-install-recommends leaves the guest with a kernel and
# no initrd (and the postinst silently produces no /boot/initrd.img-*).
apt-get install -y --no-install-recommends \
    systemd-sysv systemd-resolved udev linux-image-virtual initramfs-tools \
    ca-certificates curl kmod procps iproute2 iputils-ping fdisk libsqlite3-0 \
    tzdata locales

. /recipe/common.sh

# Stage the kernel pair somewhere with stable, non-versioned names. QEMU reads
# these files from the HOST side, so they must not depend on the exported tree
# at all (and /boot/vmlinuz is a symlink on noble). The virtio + ext4 modules
# are named explicitly because MODULES=most would profile this container, not
# the guest.
mkdir -p /etc/initramfs-tools/conf.d
# /etc/initramfs-tools/modules is a FILE listing modules to bundle (the
# directory is modules.d) — do not mkdir it.
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
KERNEL_PATH=$(printf '%s\n' /boot/vmlinuz-* | sort -V | tail -n 1)
test -f "$KERNEL_PATH"
KVER=${KERNEL_PATH#/boot/vmlinuz-}
rm -f "/boot/initrd.img-$KVER"
update-initramfs -c -k "$KVER"
test -s "/boot/initrd.img-$KVER" || {
    echo "update-initramfs produced no /boot/initrd.img-$KVER" >&2
    ls -la /boot >&2
    exit 1
}
mkdir -p /e2eboot
cp "/boot/vmlinuz-$KVER" /e2eboot/vmlinuz
cp "/boot/initrd.img-$KVER" /e2eboot/initrd.img
chmod 0644 /e2eboot/vmlinuz /e2eboot/initrd.img
ls -la /e2eboot

# Trim: the image is copied, not an apt cache.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
