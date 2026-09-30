# AGENTS.md

Agent guidance for instantOS-e2e. [README.md](README.md) is the current source
for commands, prerequisites, environment variables, flow contracts and artifacts.
[docs/FINDINGS.md](docs/FINDINGS.md) and [isotests.md](isotests.md) are research
history; older command examples there may describe earlier harness layouts.

## Scope and authorization

- Never commit or push suite or instantCLI changes. Leave working trees for
  the user, unless they explicitly instruct otherwise.
- The suite builds the working instantCLI checkout at `INSTANTCLI_DIR`,
  including uncommitted changes. `--release` tests the published installer;
  `--flow offline` tests the installer shipped on the selected offline ISO.
- Use the suite for VM behavior: partitioning, filesystems, pacstrap, chroot,
  bootloaders, initramfs, first boot, disk guards and host preservation.
  Pure config/validation/step-graph logic is faster to test with `cargo test`
  in instantCLI.
- Use smoke runs for non-destructive behavior. Full runs are required for
  installation-path work (`src/arch/execution/*`, initramfs/kernel handling)
  before declaring it done. Suite lifecycle, reboot and verification changes
  also need the relevant full flow.

## Running and debugging

- Only one VM run per checkout. Both main and diagnostic entry points enforce
  this with `flock`; do not bypass the lock or run raw Docker VM commands while
  a suite run is active.
- Long runs should be detached and logged; poll the log and guest artifacts.
  Never pipe run.sh/Docker output through `head`, which can orphan the VM.
- Start debugging failed script assertions in `virtio_console.log`. Preserve
  uploaded logs and screenshots before rerunning; each stage clears its
  previous results, uploads, disks and vars.json.
- The container writes root-owned files. The launcher restores ownership with
  non-interactive sudo; if that fails, use sudo to read or repair ownership.
- Keep disk images and Cargo targets off `/tmp` on small-tmpfs hosts.
  `E2E_WORK_DIR` defaults to `../e2e-work`; `CARGO_TARGET_DIR` is honored.
- Checkout runs own their asset server on an available port. Do not start a
  separate server or reuse another checkout's binary.
- The offline flow has no guest NIC (`OFFLINE_SUT=1`). Network access inside
  that flow is a test/product bug, not a flake. Questions are injected over
  serial, the installer comes from the ISO, and gateway ping is skipped.
- Host flows direct-boot a prepared root disk. There is no ISO or CD to eject.
  The target is `/dev/vdb` during installation, then `/dev/vda` when extracted
  and booted standalone. Do not reboot the source host to verify the target.
- Host bundles must be writable by QEMU: os-autoinst opens backing files
  `O_RDWR` even when overlays absorb writes. Use the writable `/e2e` mount.
- `APPEND` is one whitespace-free `root=LABEL=...` token. Host recipes enable
  their serial gettys and match the NIC by `Type=ether`; do not add
  multiple kernel arguments without fixing the os-autoinst quoting behavior.
- Iterating on installed-system verification: copy/convert the last target
  disk outside a harness's `raid/`, then use `tools/run-diagnostic.sh verifydisk`.
  Main and diagnostics run the same complete verification assertions.
- Keep needle crops tight to stable text; avoid kernel versions/timestamps.
  Use `tools/make_needle.py` to create needle pairs. Host installation stages
  need no needles; standalone target verification reuses installed needles.
- `tools/analyze_install_log.py` consumes uploaded installer/executor logs
  to explain step and command timing.

## Preserve the contracts

Never weaken coverage to make a run green. Fix the product or a demonstrated
incorrect test assumption, and identify which changed in the final report.
Read [docs/FINDINGS.md](docs/FINDINGS.md#non-live-install-characterisation)
before changing host assertions:

- Host preservation checks encode correct behavior. Arch installs must leave
  the host's package configuration and installer state untouched. These checks
  are green on instantCLI dev and red on the older `49ff5bb9`; a regression
  must not be "fixed" by restoring the destructive behavior.
- Ubuntu refusal checks encode the requirement to reject a foreign source host
  before disk writes. Older instantCLI refs gate `ins arch install` only;
  current `ins arch exec` enforces the gate too. CI tolerates only the documented
  older-ref failure, never infrastructure or host-preservation failures. Keep
  the refusal assertions intact.
- Full host-Arch runs must boot and verify the extracted target. There is no
  verification-skip option. Ubuntu has no second stage because nothing should
  have been installed.
- Full/encrypted profiles verify the whole theming chain, including the
  Plymouth theme inside the initramfs (`lsinitcpio`), not merely on root.
  Encrypted runs also verify GRUB cryptodisk, sd-encrypt, and root-from-mapper.
