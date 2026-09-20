# Diagnostic harnesses

One-off harnesses used while debugging the suite. Not part of the regular
run (`run.sh` ignores this directory).

Both harnesses share the login/assert code (`casedir/tests/installed_base.pm`)
and the needles with the main suite: the docker commands below mount
`casedir/` read-only at `/casedir` and point `NEEDLES_DIR` at its needles.
Run them from the harness directory (`diag/bootcap` / `diag/verifydisk`) —
isotovideo writes its run state into the casedir it is given.

## bootcap

Boots an **already installed** disk image and screenshots the boot sequence —
used to create/refresh the `installed-*` needles without reinstalling.

```sh
# 1. copy the VM disk out of a run (raw images or converted qcow2 both work;
#    the file must be WRITABLE — a read-only bind mount makes SeaBIOS fail
#    with "could not read the boot disk"). From the repo root:
qemu-img convert -O raw casedir/raid/hd0 diag/bootcap/raid/hd0

# 2. boot it (from diag/bootcap)
docker run --rm -w /tests --network host \
  -v "$PWD":/tests -v "$PWD/../../casedir":/casedir:ro \
  registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
  --exit-status-from-test-results qemu_no_kvm=1 casedir=/tests \
  NEEDLES_DIR=/casedir/needles \
  distri=arch version=202609 QEMUCPUS=8 QEMURAM=4096 BOOTFROM=c \
  HDD_1=/tests/raid/hd0 PASSWORD=... > run.log 2>&1
```

## verifydisk

Same boot, but runs the full post-install verification suite instead of
capturing — the fastest way to iterate on the verification asserts without
reinstalling (minutes, not ~35 min).

```sh
# From the repo root: copy out the disk of the last full run (writable!)
qemu-img convert -O raw casedir/raid/hd0 diag/verifydisk/raid/hd0

# Then boot it (from diag/verifydisk)
docker run --rm -w /tests --network host \
  -v "$PWD":/tests -v "$PWD/../../casedir":/casedir:ro \
  registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
  --exit-status-from-test-results qemu_no_kvm=1 casedir=/tests \
  NEEDLES_DIR=/casedir/needles \
  distri=arch version=202609 QEMUCPUS=8 QEMURAM=4096 BOOTFROM=c \
  HDD_1=/tests/raid/hd0 PASSWORD=... > run.log 2>&1
```

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
