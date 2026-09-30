# instantOS-e2e

End-to-end VM tests for the instantOS installer (`ins arch`) and, later, the
instantOS ISO. Built on [os-autoinst](https://github.com/os-autoinst/os-autoinst)
(the engine behind openQA), executed standalone via the official
`isotovideo` container — no openQA server, no KVM required.

The suite can start from two places:

- **the live ISO** (default): boots the Arch ISO in QEMU, injects the `ins`
  binary built from an instantCLI checkout over the network, runs the
  installer's non-interactive path, cleanly reboots from disk and verifies the
  installed system (systemd state, filesystem layout, bootloader, packages,
  network);
- **an already-running operating system** (`--host-arch` / `--host-ubuntu`):
  boots a prepared minimal Arch or Ubuntu root **disk** (not an ISO), injects
  the same `ins`, and installs instantOS onto a **second disk** while the host
  OS keeps running. This is the "non-live install" path — the case the live
  ISO cannot exercise at all. Afterwards the target disk is extracted and
  booted on its own to verify it.

See [`docs/FINDINGS.md`](docs/FINDINGS.md) for the full research log, gotchas,
design notes and the non-live characterisation results.

> **⚠️ [`warning.md`](warning.md) — read before running any root + mount
> script.** On 2026-09-26 a prototype in the scratch area wiped this host's
> `/dev` and `/run` by `mount --rbind`-ing them into a scratch directory and
> later `rm -rf`-ing that directory; `rm -rf` descends through mount points.
> The machine needed a reboot. The script is now hardened and covered by
> `tools/test-mount-guards.sh`, but the pattern is worth understanding before
> you write another one.

## Quickstart (local)

Requirements: docker, qemu-capable host (TCG works; KVM makes it ~10x
faster), an Arch ISO, and an instantCLI checkout.

```sh
# layout assumed by default (override with env vars, see run.sh):
#   ../instantCLI                        product checkout
#   ~/e2e-media/archlinux-x86_64.iso     install medium
#   ../e2e-work/images/                  prepared host images (host flows)

./run.sh                 # full pipeline: install + reboot + verify (~35 min TCG)
./run.sh --smoke         # boot ISO + in-VM dry-run only (~4 min)
./run.sh --release       # test published release via install.sh (no source build, no web server)
./run.sh --offline       # Phase 3: no-NIC install from the offline ISO's bundle
                         # (boots instantos-*-offline.iso, ships no questions over
                         # the network, asserts no file:// pacman remnants survive;
                         # ~40 min TCG). Looks in E2E_MEDIA_DIR for either a local
                         # build or a copy of the published ISO
                         # (instantos-offline-latest.iso, ~4.3 GiB, stable path:
                         # https://sourceforge.net/projects/instantos/files/offline/latest/instantos-offline-latest.iso/download).
                         # For checkout-fresh installer code, rebuild the ISO
                         # locally with LOCAL_INS_BIN=... (instantOS/iso/build.sh)
                         # — the published one always carries the released `ins`.
```

## Install from a running OS (second disk)

```sh
./tools/mkhost-arch.sh       # once: build images/arch-host.img   (~6 min)
./run.sh --host-arch         # install from a running Arch onto /dev/vdb (~50 min TCG)

./tools/mkhost-ubuntu.sh     # once: build images/ubuntu-host.img (~8 min)
./run.sh --host-ubuntu       # from a running Ubuntu; expects a refusal, not an install
```

> **`--host-ubuntu` is expected to fail** against instantCLI `dev`. It asserts
> that `ins` refuses a foreign distro *before* repartitioning the disk it was
> pointed at; the host-profile gate exists in `ins arch install` but not in the
> `ins arch exec` this flow drives, so the disk does get partitioned and the
> run only fails afterwards. Those asserts are the regression test for that
> gap — see [docs/FINDINGS.md](docs/FINDINGS.md) §"Non-live install
> characterisation". CI runs this flow with `continue-on-error`.

These flows install `assets/questions-seconddisk.toml` (minimal, unencrypted),
so `run.sh` rejects `--profile` other than `minimal` on them rather than
silently ignoring the flag.

The host images are minimal x86_64 root **disks** built from docker base
images (`archlinux:latest`, `ubuntu:24.04`) with `mkfs.ext4 -d` — no ISO
download, no loop/nbd device, no cloud-init, ~1–3 GiB each. `run.sh`
direct-boots them (`KERNEL=`/`INITRD=`/`APPEND=`, root by `LABEL=`), so there
is no bootloader in them at all. Each image is a GPT disk with a single ext4
partition, DHCP on the slirp NIC, and getty **serial consoles on both `ttyS0`
and the virtio console `hvc0`** — the harness drives the whole flow over
`hvc0` with text matching, so the install stage needs no new needles (the
second stage reuses the `installed-*` ones it shares with the main suite).

The kernel cmdline `APPEND` is deliberately a single whitespace-free token
(`root=LABEL=…`): os-autoinst single-quotes an `-append` value containing
whitespace and the kernel then reads the quotes as part of its first argument,
so `root=` would not be recognised. Hence no `console=` and no `net.ifnames=0`
— the images set up `serial-getty@hvc0` themselves and match the NIC by
`Driver=virtio_net`.

Both builders record exactly what they bake into the header of the script;
that list is part of the test's meaning (the Ubuntu image is deliberately
*pristine*: no `arch-install-scripts`, no `pacman`, no `archlinux-keyring`, so
the product's own bootstrap of the Arch toolchain is what is under test).

CI runs the same thing — see `.github/workflows/e2e.yml`. Every nightly runs two
jobs in parallel on separate runners: `install-e2e` (the online install, from the
Arch ISO) and `offline-e2e` (a networkless install from the **published**
instantOS offline ISO, downloaded from its stable SourceForge path and cached by
sha256). `workflow_dispatch` runs a single flow instead: `product_ref` selects
the instantCLI ref under test, `flow` selects `live` / `offline` / `host-arch` /
`host-ubuntu`, `smoke` cuts the run down to boot + in-VM dry-run. The offline
job deliberately does not check out instantCLI — it tests the shipped artifact
(installer included), so `product_ref` does not apply to it. `host-ubuntu` runs
with `continue-on-error`, because of the known product gap above.

## How it works

- `casedir/` is an os-autoinst **test distribution**: Perl test modules
  (`tests/`), image fixtures (`needles/`), and the questions fixture
  (`assets/` in the repo root, served to the guest over HTTP).
- Strategy: needles only for boot menus and login prompts; everything else
  is text matching on a virtio serial console (`assert_script_run`),
  which is robust against font/rendering drift.
- The installer copies its own binary into the target system, so a single
  self-contained `ins` binary plus a questions file is all the VM needs.
- The two flows use different questions fixtures: `assets/questions-minimal.toml`
  (`Disk = "/dev/vda"`) for the live ISO, `assets/questions-seconddisk.toml`
  (`Disk = "/dev/vdb"`) for the running-OS flows.
- A second-disk install cannot be verified by rebooting (the machine comes
  back up in the host OS on `/dev/vda`), so `run.sh` flattens
  `casedir/raid/hd1` and boots it standalone through the `diag/verifydisk`
  harness, which runs exactly the same `login_installed_system()` +
  `assert_core_suite()` as the main suite. There the target is `/dev/vda`,
  hence `E2E_TARGET_DISK=/dev/vda` for that stage. `--host-ubuntu` skips the
  stage: nothing is supposed to have been installed.
- `diag/` contains one-off harnesses used while debugging (boot a bare disk
  image, capture boot frames); they are not part of the regular suite.

## Repo layout

```
run.sh                  entry point (wraps isotovideo in the official container)
casedir/                os-autoinst test distribution
  tests/                boot / install / verify / host_boot / host_install modules
  needles/              PNG + JSON image fixtures
assets/                 served to the guest (ins binary, questions files)
diag/                   diagnostic harnesses
tools/                  helper scripts (needle creation, install-log
                        timing analysis, host image builders,
                        mount-guard regression test)
docs/FINDINGS.md        research log: findings, bugs caught, gotchas
warning.md              mount/rm -rf hazard: what broke, and the safe pattern
```

## Notes

- Both CI jobs cache their ISO keyed by its published sha256
  (`actions/cache`): one download per release instead of per run, and a
  checksum check on every cache miss. The `--host-*` flows need no ISO at all;
  their host image is built in the job and cached the same way.
- The offline ISO is ~4.3 GiB, so its cache entry is worth more than it costs —
  the SourceForge download is the slowest step of that job — but it does take
  most of the repository's 10 GiB cache budget. A new published build evicts the
  previous entry. If the download ever gets fast enough to make the cache
  pointless, the step to delete is `Cache instantOS offline ISO`.
- The `ins` binary under `assets/` is generated; never commit it. The host
  disk images are large generated binaries too — never commit them; the
  `tools/mkhost-*.sh` builders are the source of truth.
- Needle PNGs *are* committed — they are the test fixtures. Keep crops
  tight to stable text (avoid kernel versions/timestamps) so they survive
  ISO updates; `tools/make_needle.py <frame.png> <tag> x y w h` creates them.
- `PASSWORD` in `run.sh` is a throwaway VM credential defined by the
  questions fixture; nothing here is secret.
