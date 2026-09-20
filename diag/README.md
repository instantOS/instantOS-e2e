# Diagnostic harnesses

One-off harnesses used while debugging the suite. Not part of the regular
run (`run.sh` ignores this directory).

## bootcap

Boots an **already installed** disk image and screenshots the boot sequence —
used to create/refresh the `installed-*` needles without reinstalling.

```sh
# 1. copy the VM disk out of a run (raw images or converted qcow2 both work;
#    the file must be WRITABLE — a read-only bind mount makes SeaBIOS fail
#    with "could not read the boot disk")
qemu-img convert -O raw casedir/raid/hd0 /tmp/hd0.raw

# 2. boot it
docker run --rm -w /tests --network host -v "$PWD":/tests \
  registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
  --exit-status-from-test-results qemu_no_kvm=1 casedir=/tests \
  distri=arch version=202609 QEMUCPUS=8 QEMURAM=4096 BOOTFROM=c \
  HDD_1=/tests/hd0.raw PASSWORD=... > run.log 2>&1
```

## verifydisk

Same boot, but runs the full post-install verification suite instead of
capturing. Point `HDD_1` at a raw image of a completed install.

## Repairing a broken install offline

```sh
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 <disk.img>
sudo mount /dev/nbd0p2 /mnt/e2e-inspect
sudo chroot /mnt/e2e-inspect /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
sudo umount /mnt/e2e-inspect && sudo qemu-nbd --disconnect /dev/nbd0
```

Watch out: os-autoinst attaches provided `HDD_1` images as **raw** backing
files — convert qcow2 to raw first (`qemu-img convert -O raw`), or the
resulting overlay will read garbage and SeaBIOS reports "not a bootable
disk".
