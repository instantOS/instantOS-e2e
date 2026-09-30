# Diagnostic harnesses

Run diagnostics from the repository root with the shared launcher. It locks
the checkout, clears the selected harness's runtime state, launches isotovideo,
and restores artifact ownership, just like `run.sh`.

```sh
# Preserve the last target outside raid/: each launch deletes its own raid/.
mkdir -p ../e2e-work/work
qemu-img convert -O raw casedir/raid/hd0 ../e2e-work/work/installed.raw
# A running-Arch install's target is casedir/raid/hd1 instead.

./tools/run-diagnostic.sh verifydisk ../e2e-work/work/installed.raw
./tools/run-diagnostic.sh verifydisk ../e2e-work/work/installed.raw --profile full
./tools/run-diagnostic.sh verifydisk ../e2e-work/work/installed.raw --profile encrypted
./tools/run-diagnostic.sh bootcap ../e2e-work/work/installed.raw

E2E_MEDIA_DIR=../instantOS/iso/build/iso \
E2E_ISO_NAME=instantos-YYYY.MM.DD-x86_64.iso ./tools/run-diagnostic.sh liveiso
# Offline ISO: also check the bundle, snapshot and file://-first mirrorlist.
E2E_ISO_NAME=instantos-offline-latest.iso ./tools/run-diagnostic.sh liveiso --offline
# UEFI live-session spike (visual assertions only):
E2E_ISO_NAME=instantos-YYYY.MM.DD-x86_64.iso ./tools/run-diagnostic.sh liveiso UEFI=1
```

`verifydisk` runs the complete shared post-install verification suite, including
profile-specific checks. `bootcap` captures the boot/login sequence for needle
maintenance. Both require a writable raw disk; convert qcow2 first because
os-autoinst treats `HDD_1` as raw backing storage.

`liveiso` checks the instantOS live session: boot menu, pre-Welcome desktop bar,
Welcome window, greetd, Wayland socket, absence of Xorg, swaybg wallpaper, and
live-setup completion. It includes forensic dumps used by [isotests.md](../isotests.md).
UEFI runs boot the default entry and check the desktop visually; serial checks
need a systemd-boot menu needle and editor flow before they can run on UEFI.

All diagnostics accept `--kvm` and hardware variables such as `QEMUCPUS=4`.
Disk diagnostics can use `PASSWORD=...` for a preserved disk with a different
credential. `--offline` also disables the NIC; use it for verifying a target
installed offline. Artifacts land under `diag/<harness>/`, including screenshots,
module results, serial logs and uploaded guest logs.
