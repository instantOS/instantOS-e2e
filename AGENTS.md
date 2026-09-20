# AGENTS.md

Guidance for automated agents developing `instantCLI` and using or extending
this suite. Human-oriented overview: [README.md](README.md).

## What this suite is (and is not)

Full VM e2e for `ins arch`: boots the Arch ISO in QEMU (os-autoinst/isotovideo
container), injects the `ins` binary **built from the instantCLI checkout at
`INSTANTCLI_DIR`** (default `../instantCLI` — your working tree as-is,
uncommitted changes included), installs to a blank disk, reboots from it, and
asserts the installed system works.

It tests your current checkout automatically. There is no "dev mode" switch
to flip — every `run.sh` invocation builds and tests exactly what is in
`INSTANTCLI_DIR` right now.

Use it when behavior *inside a VM* matters: partitioning, mkfs, pacstrap,
bootloader, first boot. Pure logic (config parsing, validation, step graph)
is covered faster by `cargo test` in instantCLI — though the in-VM dry-run
also exercises those end to end.

## Commands

Prereqs: docker; an Arch ISO at `~/e2e-media/archlinux-x86_64.iso`
(downloaded once; `E2E_MEDIA_DIR` to override), instantCLI checkout as
sibling or via `INSTANTCLI_DIR`.

```sh
./run.sh --smoke      # ~4 min:  ISO boot + full in-VM dry-run, no install
./run.sh              # ~35 min TCG: install + reboot + 14 post-install asserts
./run.sh --kvm        # KVM-capable host only: full run in ~4 min
./run.sh --release    # test published release via install.sh (no source build/web server)
./run.sh --help       # all options; extra isotovideo vars pass through,
                      # e.g. ./run.sh QEMUCPUS=16
```

**Smoke vs full** — pick by what you changed in instantCLI:

- `--smoke` suffices for: CLI, wizard/validation, step graph, config
  import/`--trust-config`, dry-run behavior — anything that does not modify
  the target system.
- Full run required for: `src/arch/execution/*` (partitioning, filesystems,
  packages, bootloader, chroot steps), initramfs/kernel handling — and always
  before declaring install-path work done.

**Profiles** — which installed configuration gets verified:

- `--profile minimal` (default): TTY-only, fast; core install machinery.
- `--profile full`: instantOS packages + Plymouth + GRUB theme. verify.pm
  asserts the whole theming chain — packages present, `Theme=instantos`
  configured, `plymouth` in HOOKS, and critically that the theme is embedded
  **inside the initramfs image** (`bsdtar -tf`), which is what makes the
  passphrase prompt themed at all.
- `--profile encrypted`: full + LUKS (`/boot` inside the container). Adds
  cryptodisk/sd-encrypt asserts, root-from-mapper check, and blind-typing of
  the passphrase through the double prompt (GRUB + initramfs) at boot.
  **Known product caveats under test**: the code comments in
  `config.rs::configure_plymouth` and `bootloader.rs::configure_grub_theme`
  claim both themes are not visible when encryption is on — these runs are
  how that gets settled empirically.

## Running it as an agent

A full run far exceeds typical command timeouts. Run it detached and poll:

```sh
./run.sh --smoke > /tmp/e2e.log 2>&1 &
tail -f /tmp/e2e.log          # modules print progress as they run
```

Never pipe run.sh/docker output through `head` — SIGPIPE kills the docker
client mid-run and the VM keeps running orphaned.

**One run at a time per checkout** (casedir state, port 8000 and the disk
images are shared).

## Interpreting results

- **Exit code 0** = every module passed. Nonzero = at least one failed.
- Artifacts (all under `casedir/`):
  - `testresults/*.png` — screenshots in execution order; the last ones show
    the failure state. Needle failures render the screenshot with matched
    regions outlined.
  - `testresults/result-*.json` — per-module results with failure details.
  - `virtio_console.log`, `virtio_console_user.log` — full text of the
    installer/target consoles. **A failed `assert_script_run` shows the exact
    command and its output here — start debugging here.**
  - `video.ogv`, `serial0` — screen recording, raw serial log.
  - `ulogs/` — logs the guest uploaded (`journalctl` etc.).
- The docker output also streams everything; the log file is enough.

## Fast iteration recipes

- Boot/dry-run failure loop: edit instantCLI → rerun `./run.sh --smoke`
  (the rebuild of `ins` is automatic and incremental — no stale-binary risk).
- Iterating on `verify.pm` only: after any full run, `casedir/raid/hd0` is a
  working installed system. Copy it somewhere safe and boot it with the
  `diag/verifydisk` harness (see `diag/README.md`) — minutes, no reinstall.
- Needle (image fixture) changes: no rebuild needed; rerun the affected
  module. Keep needle crops tight to stable text, never kernel
  versions/timestamps (they change with every ISO).
- To create a needle: `tools/make_needle.py <screenshot.png> <tag> x y w h`.
- To see where an install spent its time:
  `tools/analyze_install_log.py casedir/ulogs/install-install.log
  [casedir/ulogs/install-executor.log ...]` — parses the step/slow-command
  lines the installer prints and, when given the executor log, the full
  per-command timeline.

## Gotchas

- `run.sh` needs port 8000 to serve the guest its `ins` binary; it reuses a
  healthy server, and fails fast with instructions if the port is taken by
  something else (e.g. a stale server from another checkout). Don't ignore
  that error — the VM-side symptom of a bad asset server is a misleading
  `curl: (22)` failure minutes into the run.
- All VM runs here are TCG (software emulation) — ~10x slower than KVM. On a
  KVM-capable host, remove `qemu_no_kvm=1` from `run.sh` (and expect ~4 min
  full runs).
- Container output files are root-owned; `run.sh` chowns them back
  non-interactively. If chown was skipped (no passwordless sudo), read files
  with sudo.
- If a run fails bizarrely and early, verify the ISO exists and is intact;
  `run.sh` deletes `casedir/vars.json` and `casedir/raid/` itself, so stale
  state is not the usual suspect.
- Do not weaken coverage to make a test pass (e.g. deleting verify asserts);
  fix the product or the test's assumption, and say which in your summary.
- Suite-side changes (Perl, needles, run.sh) follow the same rule as
  instantCLI: never commit or push; leave the working tree for the user.
