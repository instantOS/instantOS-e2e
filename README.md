# instantOS-e2e

VM end-to-end tests for `ins arch`, using os-autoinst in the official
isotovideo container. Tests build the current instantCLI working tree,
including uncommitted changes. The offline flow tests the installer shipped
on the ISO instead.

| Flow | Starting system | Contract |
| --- | --- | --- |
| `live` (default) | Arch ISO | Install onto `/dev/vda`, reboot and verify |
| `offline` | instantOS offline ISO, no NIC | Install from the bundle, reboot, verify and reject surviving `file://` pacman references |
| `host-arch` | Running Arch on `/dev/vda` | Install onto `/dev/vdb`, preserve the host, boot the target standalone and verify |
| `host-ubuntu` | Running Ubuntu on `/dev/vda` | Refuse before writing `/dev/vdb`, preserve the host; no target boot |

The Ubuntu refusal contract is currently red on instantCLI `dev`: its
host-profile gate exists in `ins arch install`, while this suite drives
`ins arch exec`. CI tolerates only the documented partition-before-refusal failure, using completed
VM results and preservation evidence. Other failures remain fatal. Keep its
assertions intact; [FINDINGS](docs/FINDINGS.md#non-live-install-characterisation)
records the product baseline and the latest Arch chroot-guard failure.

## Run locally

Requirements: Docker, Bash 4.3+, Python 3.11+, `flock`, and an instantCLI checkout
(default `../instantCLI`). Disk conversion also needs `qemu-img`. Host image
building needs `sfdisk`, `mkfs.ext4`, `e2fsck`, and passwordless sudo for exporting
root-owned files. KVM is used automatically when `/dev/kvm` is usable. Otherwise the runners
use TCG; `--tcg` forces emulation and `--kvm` requires acceleration.

Put the Arch ISO at `~/e2e-media/archlinux-x86_64.iso`. Put a published offline
ISO at `~/e2e-media/instantos-offline-latest.iso`, or select a local build
explicitly with `E2E_MEDIA_DIR` and `E2E_ISO_NAME`.

```sh
./run.sh --smoke                         # boot + full in-VM dry-run (~4 min TCG)
./run.sh                                 # install + reboot + verify (~35 min TCG)
./run.sh --profile full                  # instantOS packages and boot themes
./run.sh --profile encrypted             # full profile with LUKS
./run.sh --release                       # published installer via install.sh
./run.sh --flow offline                  # shipped installer, no NIC (~40 min TCG)

# Select a local offline build; no automatic filename guessing.
E2E_MEDIA_DIR=../instantOS/iso/build/iso \
E2E_ISO_NAME=instantos-YYYY.MM.DD-offline.iso ./run.sh --flow offline

# Running-OS flows require no ISO.
./tools/mkhost.sh arch
./run.sh --flow host-arch --smoke         # dry-run only (~8 min TCG)
./run.sh --flow host-arch                 # install + standalone verify (~50 min TCG)
./tools/mkhost.sh ubuntu
./run.sh --flow host-ubuntu               # require safe refusal

./run.sh --kvm QEMUCPUS=4 QEMURAM=4096
./run.sh --help
```

`minimal` is TTY-only, ext4, no encryption. `full` adds instantOS packages,
Plymouth and GRUB themes. `encrypted` adds LUKS with `/boot` inside the
container and verifies both GRUB and initramfs unlocking. Theme assertions
inspect the initramfs using `lsinitcpio`. Host flows require `minimal`; the
runner derives their configuration from that fixture with `Disk = "/dev/vdb"`.

| Environment | Default | Purpose |
| --- | --- | --- |
| `INSTANTCLI_DIR` | `../instantCLI` | Product checkout |
| `CARGO_TARGET_DIR` | `$INSTANTCLI_DIR/target` | Incremental build output |
| `E2E_MEDIA_DIR` | `~/e2e-media` | ISO directory for both ISO flows |
| `E2E_ISO_NAME` | `archlinux-x86_64.iso` / `instantos-offline-latest.iso` | Exact filename |
| `E2E_WORK_DIR` | `../e2e-work` | Host bundles and converted target disks |
| `E2E_IMAGE_DIR` | `$E2E_WORK_DIR/images` | Optional bundle-directory override |

Cargo compiler temporary files use `$E2E_WORK_DIR/tmp` unless `TMPDIR` is set,
so builds do not rely on free space in `/tmp`.

Login credentials are read from the selected questions fixture. Host bundles
use the minimal fixture credential; rebuild them after changing that fixture.
Supported `VAR=VALUE` overrides are `QEMUCPUS`, `QEMURAM`, `HDDSIZEGB`, and
`STORAGE_KEEP_FREE_GB` (names are case insensitive). Other variables are rejected;
scenario, boot-device, networking and credentials are selected by the runner.

## Harness design

The runner holds a checkout lock for the entire run. Each stage clears its
runtime state, launches the same container and returns artifact ownership,
including on test failure. The harness container digest is pinned in
`tools/lib/isotovideo.sh`; update it together with a validated backend change.
A full host-Arch run always converts and verifies
the target; conversion or verification failure makes the run fail.

Checkout flows build `ins` once and serve it from this checkout on an available
port. The server belongs to that run and stops on exit. Questions files go
in over serial in every flow, including offline and release. No persistent
asset server or fixed host port is required.

Host bundles contain `disk.img`, `vmlinuz`, and `initrd.img` under
`images/arch-host/` or `images/ubuntu-host/`. `tools/mkhost.sh` builds rootfs
recipes inside Docker, exports them and assembles a GPT/ext4 disk using
`mkfs.ext4 -d`; it creates no host mounts or loop devices. It checks the
filesystem and partition geometry before replacing a previous bundle.

Distro recipes live in `tools/host/`. Arch includes the installation toolchain
(`arch-install-scripts`, fzf, gum, filesystem tools). Ubuntu includes only
host/harness essentials and the installer’s SQLite runtime, with no pacman
or Arch installation toolchain. Both
configure DHCP via systemd-networkd, resolved, and gettys on `hvc0` and `ttyS0`.
The kernel command line is a single `root=LABEL=...` token because os-autoinst
mishandles whitespace in `APPEND`. NIC matching uses `Type=ether`.

Guest helpers in `installer_base.pm` share config injection, dry-run/install
execution, log uploads, offline preconditions and host snapshots. Host snapshots
are collected before assertions, and both dry-run and real installation must
preserve protected host configuration. Installed-system checks, including
profile-specific checks, are shared with the diagnostic disk harness.

## Results and iteration

Run long tests detached and poll their logs:

```sh
./run.sh --flow host-arch > /tmp/e2e.log 2>&1 &
tail -f /tmp/e2e.log
```

Exit 0 means every required stage passed. Start failure diagnosis with
`casedir/virtio_console.log`, which includes the failing command and its output.
Screenshots and per-module results live in `casedir/testresults/`; uploaded
installer logs and host snapshots live in `casedir/ulogs/`. Offline logs are
collected over serial with a SHA-256 check; online logs use the backend upload
API. Attachments use their source basenames (`dryrun.log`, `install.log`) and
`executor-install.log`. The standalone
verification stage writes equivalent artifacts under `diag/verifydisk/`.
Never pipe a running Docker client through `head`: SIGPIPE can orphan the VM.

Use smoke tests for configuration/CLI/dry-run changes. Use a full run for
installation, reboot, or verification changes. Pure product logic belongs in
instantCLI's faster `cargo test` suite.

[Diagnostic commands](diag/README.md) can boot an existing installed disk
without reinstalling, capture boot screens, or inspect an instantOS live ISO.
[AGENTS.md](AGENTS.md) records agent-specific rules; [FINDINGS](docs/FINDINGS.md)
and [isotests.md](isotests.md) preserve research history. Read
[warning.md](warning.md) before developing root scripts that mount host paths.

## Checks and CI

```sh
./tests/run.sh
```

This checks Bash/Perl syntax, runner orchestration with simulated external
commands, and guest-helper contracts with a fake VM API. Perl runs in the same
pinned harness container as the VM tests.

CI runs online and published-offline installs nightly; manual dispatch selects
one flow. `product_ref` applies to checkout flows only. ISO caches use published
checksums; host-bundle caches use hashes of the builder and recipes. CI delegates
build, asset serving and VM lifecycle to `run.sh`.

The runner now uses `--flow NAME` in place of `--offline` / `--host-arch` /
`--host-ubuntu`. Rebuild old host images with `tools/mkhost.sh`; standalone
`.img` and generated `.env` files are no longer inputs. Diagnostic commands now
use `tools/run-diagnostic.sh`. The external scratch-prototype guard test was
removed because its implementation is outside this repository.
