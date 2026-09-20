# instantOS-e2e

End-to-end VM tests for the instantOS installer (`ins arch`) and, later, the
instantOS ISO. Built on [os-autoinst](https://github.com/os-autoinst/os-autoinst)
(the engine behind openQA), executed standalone via the official
`isotovideo` container — no openQA server, no KVM required.

The suite boots the Arch ISO in QEMU, injects the `ins` binary built from an
instantCLI checkout over the network, runs the installer's non-interactive
path, cleanly reboots from disk and verifies the installed system (systemd
state, filesystem layout, bootloader, packages, network). See
[`docs/FINDINGS.md`](docs/FINDINGS.md) for the full research log, gotchas and
design notes.

## Quickstart (local)

Requirements: docker, qemu-capable host (TCG works; KVM makes it ~10x
faster), an Arch ISO, and an instantCLI checkout.

```sh
# layout assumed by default (override with env vars, see run.sh):
#   ../instantCLI                        product checkout
#   ~/e2e-media/archlinux-x86_64.iso     install medium

./run.sh                 # full pipeline: install + reboot + verify (~35 min TCG)
./run.sh --smoke         # boot ISO + in-VM dry-run only (~4 min)
```

CI runs the same thing — see `.github/workflows/e2e.yml` (nightly +
manual dispatch; `product_ref` input selects the instantCLI ref under test).

## How it works

- `casedir/` is an os-autoinst **test distribution**: Perl test modules
  (`tests/`), image fixtures (`needles/`), and the questions fixture
  (`assets/` in the repo root, served to the guest over HTTP).
- Strategy: needles only for boot menus and login prompts; everything else
  is text matching on a virtio serial console (`assert_script_run`),
  which is robust against font/rendering drift.
- The installer copies its own binary into the target system, so a single
  self-contained `ins` binary plus a questions file is all the VM needs.
- `diag/` contains one-off harnesses used while debugging (boot a bare disk
  image, capture boot frames); they are not part of the regular suite.

## Repo layout

```
run.sh                  entry point (wraps isotovideo in the official container)
casedir/                os-autoinst test distribution
  tests/                boot / install / verify modules
  needles/              PNG + JSON image fixtures
assets/                 served to the guest (ins binary, questions file)
diag/                   diagnostic harnesses
tools/                  needle creation helper
docs/FINDINGS.md        research log: findings, bugs caught, gotchas
```

## Notes

- The CI job caches the Arch ISO keyed by its published sha256
  (`actions/cache`): one download per ISO release instead of per run, and a
  checksum check on every cache miss.
- The `ins` binary under `assets/` is generated; never commit it.
- Needle PNGs *are* committed — they are the test fixtures. Keep crops
  tight to stable text (avoid kernel versions/timestamps) so they survive
  ISO updates; `tools/make_needle.py <frame.png> <tag> x y w h` creates them.
- `PASSWORD` in `run.sh` is a throwaway VM credential defined by the
  questions fixture; nothing here is secret.
