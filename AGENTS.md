# AGENTS.md

Guidance for automated agents developing `instantCLI` and using or extending
this suite. Human-oriented overview: [README.md](README.md).

## What this suite is (and is not)

Full VM e2e for `ins arch`. It boots something in QEMU (os-autoinst/isotovideo
container), injects the `ins` binary **built from the instantCLI checkout at
`INSTANTCLI_DIR`** (default `../instantCLI` — your working tree as-is,
uncommitted changes included), runs the installer's non-interactive path, and
asserts the installed system works. Two starting points:

| flow | what boots | where instantOS goes | how it is verified |
|------|-----------|----------------------|--------------------|
| default (`live`) | the Arch ISO | the single blank disk | `power('reset')` boots the new install; `verify.pm` |
| `--offline` | the instantOS **offline** ISO, with no NIC at all | the single blank disk | as above, plus asserts that no `file://` pacman reference survived the install (Phase 3, `instantOS/offlineiso.md`) |
| `--host-arch` | a prepared minimal **Arch root disk** (`tools/mkhost-arch.sh`) | the **second** disk, `/dev/vdb` | the target disk is extracted and booted standalone via `diag/verifydisk` |
| `--host-ubuntu` | a prepared minimal **Ubuntu 24.04 root disk** (`tools/mkhost-ubuntu.sh`) | nothing — the installer must refuse before touching it | in-guest: the disk must still be blank, the host's apt sources untouched. **No second stage**: there is no install to boot. Red on instantCLI `dev` by design, see below |

`--offline` is the one flow that does *not* test your checkout: it runs the
`ins` shipped on the ISO (injected at build time as `/usr/local/bin/ins`) and
takes the questions file over serial instead of over HTTP, so no cargo build
and no asset server. CI's `offline-e2e` job therefore tests the *published*
ISO (SourceForge, stable `latest` path) and does not check out instantCLI at
all.

The `--host-*` flows exist because the live ISO cannot exercise the
"install from an already-running OS" path at all: the running system is a
real root filesystem there, so the disk guard, the host-side state writes and
the foreign-distro bootstrap all come into play. They install
`assets/questions-seconddisk.toml` — a minimal, unencrypted configuration —
so `run.sh` refuses `--profile` other than `minimal` on them rather than
silently ignoring it. See the non-live characterisation section in
[docs/FINDINGS.md](docs/FINDINGS.md), which also explains why `--host-ubuntu`
is expected to be red.

It tests your current checkout automatically. There is no "dev mode" switch
to flip — every `run.sh` invocation builds and tests exactly what is in
`INSTANTCLI_DIR` right now.

Use it when behavior *inside a VM* matters: partitioning, mkfs, pacstrap,
bootloader, first boot, and whether the installer stays inside the disk it was
pointed at. Pure logic (config parsing, validation, step graph) is covered
faster by `cargo test` in instantCLI — though the in-VM dry-run also exercises
those end to end.

## Commands

Prereqs: docker; an Arch ISO at `~/e2e-media/archlinux-x86_64.iso`
(downloaded once; `E2E_MEDIA_DIR` to override), instantCLI checkout as
sibling or via `INSTANTCLI_DIR`. The `--host-*` flows need no ISO, but do need
a prepared host image (`tools/mkhost-arch.sh` / `tools/mkhost-ubuntu.sh`,
written to `../e2e-work/images`). `--offline` needs an instantOS offline ISO
in `E2E_MEDIA_DIR` — either a local build or the published
`instantos-offline-latest.iso` (~4.3 GiB, which `run.sh --offline` picks up by
name; `E2E_ISO_NAME` overrides).

```sh
./run.sh --smoke      # ~4 min:  ISO boot + full in-VM dry-run, no install
./run.sh              # ~35 min TCG: install + reboot + 14 post-install asserts
./run.sh --offline    # ~40 min TCG: install with no NIC from the instantOS
                      # offline ISO, then reboot + verify; asserts no file://
                      # pacman remnant survived. Tests the shipped ins, not
                      # your checkout.
./run.sh --host-arch  # ~50 min TCG: install from a RUNNING Arch onto /dev/vdb,
                      # then boot that disk standalone and verify it
./run.sh --host-ubuntu  # same, from a RUNNING Ubuntu 24.04 (no Arch toolchain)
./run.sh --kvm        # KVM-capable host only: full run in ~4 min
./run.sh --release    # test published release via install.sh (no source build/web server)
./run.sh --help       # all options; extra isotovideo vars pass through,
                      # e.g. ./run.sh QEMUCPUS=16
```

**Smoke vs full** — pick by what you changed in instantCLI:

- `--smoke` suffices for: CLI, wizard/validation, step graph, config
  import/`--trust-config`, dry-run behavior — anything that does not modify
  the target system. `--host-arch --smoke` is the cheap way to test the
  non-live plumbing: it boots the host image, logs in over serial, injects
  `ins`, and runs the dry-run against `/dev/vdb`. `--offline --smoke` is the
  equivalent for the offline ISO: it checks the Phase 0 preconditions (bundle
  mounted at `/run/archiso/bootmnt/offline-repo`, dotfiles snapshot present,
  mirrorlist `file://`-first) and the in-VM dry-run, without installing.
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
- The non-live equivalent: `./run.sh --host-arch --smoke` (~8 min TCG) boots
  the host image, logs in over `hvc0` and dry-runs against `/dev/vdb`. It does
  no install, so it is the cheap loop for the running-OS path.
- Iterating on `verify.pm` only: after any full run, `casedir/raid/hd0` is a
  working installed system. Copy it somewhere safe and boot it with the
  `diag/verifydisk` harness (see `diag/README.md`) — minutes, no reinstall.
  Same for a second-disk install: `casedir/raid/hd1` is the target, and
  `run.sh` already boots it for you in the second stage.
- Needle (image fixture) changes: no rebuild needed; rerun the affected
  module. Keep needle crops tight to stable text, never kernel
  versions/timestamps (they change with every ISO). The `--host-*` flows
  need **no** needles at all (the host images give the harness a getty on
  `hvc0`).
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
  `curl: (22)` failure minutes into the run. `--release` and `--offline` skip
  the server entirely (the questions file goes in over serial as a base64
  heredoc), so port 8000 is only the online dev flows' problem.
- The offline ISO is ~4.3 GiB and boots with **no NIC** (`OFFLINE_SUT` →
  QEMU `-net none`). Anything that reaches for the network in that run is a
  bug in the test, not a flake: the questions file is typed in, the installer
  comes off the ISO, and `verify.pm` skips the gateway ping.
- All VM runs here are TCG (software emulation) — ~10x slower than KVM. On a
  KVM-capable host, remove `qemu_no_kvm=1` from `run.sh` (and expect ~4 min
  full runs).
- Container output files are root-owned; `run.sh` chowns them back
  non-interactively. If chown was skipped (no passwordless sudo), read files
  with sudo.
- If a run fails bizarrely and early, verify the ISO exists and is intact;
  `run.sh` deletes `casedir/vars.json` and `casedir/raid/` itself, so stale
  state is not the usual suspect.
- Never put disk images or a cargo target dir in `/tmp` on small-tmpfs hosts.
  `run.sh` uses `E2E_WORK_DIR` (default `../e2e-work`) for host images and
  converted disks, and honours `CARGO_TARGET_DIR` for the `ins` build.
- The `--host-*` flows boot with `-kernel`, so there is **no CD** and no
  `iso=` var. After `power('reset')` the machine comes back up in the *host*
  OS on `/dev/vda`, which is why verification happens in the second stage
  (`run.sh`: `qemu-img convert` `casedir/raid/hd1` → `diag/verifydisk`).
  Debug a target that will not boot by extracting it and booting it directly,
  not by adding a reboot to the first stage.
- `KERNEL`/`INITRD`/`APPEND` go straight to QEMU via os-autoinst
  (`backend/qemu.pm`), but `APPEND` must be a **single whitespace-free token**:
  `gen_params` single-quotes an `-append` value containing whitespace and the
  kernel then reads the quotes as part of the first argument, so `root=` is not
  recognised and there is no console. That is why the generated `APPEND` is
  only `root=LABEL=…`, the host images enable `serial-getty@hvc0` themselves,
  and the NIC is matched by `Driver=virtio_net` in `10-e2e.network` — not by
  the name `eth0`, and not via `net.ifnames=0`, which cannot be passed at all.
- os-autoinst opens `HDD_N` backing files **O_RDWR** (the qcow2 overlay in
  `casedir/raid` absorbs the writes, but a read-only bind mount makes SeaBIOS
  report "could not read the boot disk"). That is why host images are mounted
  at `/e2e` read-write, not at the read-only `/media`.
- Do not weaken coverage to make a test pass (e.g. deleting verify asserts);
  fix the product or the test's assumption, and say which in your summary.
- One deliberate exception exists, and it is worth stating precisely because
  the easy reading of it is backwards. `tests/host_install.pm` has two kinds
  of assert:
  - The **host-must-survive** asserts (`diff -q` on the host's pacman files,
    `! test -e /etc/instant/…`) encode the *correct* behaviour, so they are
    green on instantCLI `dev` and red on a product that reconfigures the host.
    They were written *after* the non-live install work fixed that, and they
    fail against the older `49ff5bb9`. If one goes red, the product
    regressed — do not restore the old behaviour to make it pass.
  - The **`--host-ubuntu` refusal** asserts encode a property the product does
    not implement on the `ins arch exec` path (the host-profile gate is in
    `ins arch install` only), so that flow is red on `dev` by design and CI
    runs it with `continue-on-error`. Do not invert those asserts to match
    today's behaviour.
  `docs/FINDINGS.md` §"Non-live install characterisation" is the baseline for
  both; read it before changing either.
- Suite-side changes (Perl, needles, run.sh) follow the same rule as
  instantCLI: never commit or push; leave the working tree for the user.
