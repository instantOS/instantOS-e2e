> **Post-split note (2026-09-20):** this log was written while the suite
> lived in `instantCLI/e2e/`. Paths below have been mechanically updated
> to the new layout; `e2e.md`/`e2e/` in older text refers to the same
> files now under `docs/FINDINGS.md` and `casedir/`.

# e2e testing of `ins arch` with os-autoinst — research notes

Goal: evaluate [os-autoinst](https://github.com/os-autoinst/os-autoinst) (the
test engine behind openQA) for automated end-to-end tests of `ins arch` —
boot an Arch ISO in QEMU, run the installer, verify the installed system
boots and works.

**Verdict: yes, it works, and it already paid for itself.** The suite in
`e2e/` boots the Arch ISO, injects the `ins` binary from the host, runs the
non-interactive installer, cleanly reboots from disk and verifies the
installed system — and along the way it caught two real bugs (one fixed as
`ins arch exec --trust-config`, one defensive check for empty `grub.cfg`).
**A full pipeline run (10 runs of iteration) completed green end to end:
boot 203 s + install 1507 s + verify 453 s ≈ 36 min under TCG (no KVM on
this machine); with KVM it should drop to a few minutes.**

Final run (2026-09-20, `run.sh`):

| module      | result | runtime |
|-------------|--------|---------|
| boot        | ok     | 203 s   |
| install     | ok     | 1507 s  |
| verify      | ok     | 453 s   |

All needle matches at similarity 1.00 (bootloader, archiso prompt,
installed login, root prompt); all 14 post-install asserts green.

---

## Environment

- QEMU 8.2.2 (Ubuntu 24.04), 32 CPUs, 62 GB RAM, **no /dev/kvm** → all VMs run
  under TCG (software emulation). MTTCG multi-core vCPUs (8) make a full
  install ~25 min; boot to live shell ~90 s.
- Docker available (rootful, local) — used for the official isotovideo
  container.
- Network: GitHub, registry.opensuse.org, most Arch mirrors reachable;
  `geo.mirror.archlinux.org` does *not* resolve here. ISO came from
  `mirror.osbeck.com` (archlinux-x86_64.iso, ~1.6 GB, `ARCH_202609`).

## How os-autoinst works (short version)

- `isotovideo` is the standalone runner; openQA is *not* required.
- A **test distribution** (casedir) = `main.pm` + `tests/*.pm` (Perl,
  `testapi` functions) + `needles/` (PNG + JSON rectangles for screen
  matching) + optionally `scenario-definitions.yaml`.
- Backend drives QEMU; inputs via VNC (keyboard/mouse) and virtio consoles;
  screenshots matched with OpenCV needles.
- Important vars: `ISO`, `CASEDIR`, `BACKEND=qemu`, `QEMUCPUS`, `QEMURAM`,
  `HDDSIZEGB`, `BOOTFROM=c|d`, `qemu_no_kvm=1`, `NICTYPE=user` (default;
  slirp NAT, guest→host = 10.0.2.2), `VIRTIO_CONSOLE` (on by default; FIFO
  pipes to a virtio-console device), `PASSWORD` (for `type_password`).
- `--exit-status-from-test-results` → non-zero exit on test failure (CI).

## Setup that works here

```sh
./run.sh          # everything below, reproducibly
```

which is:

```sh
docker run --rm -w /tests --network host \
  -v "$PWD/e2e:/tests" -v "$HOME/e2e-media:/media:ro" \
  registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
  --exit-status-from-test-results qemu_no_kvm=1 casedir=/tests \
  iso=/media/archlinux-x86_64.iso distri=arch version=202609 flavor=medium \
  QEMUCPUS=8 QEMURAM=4096 HDDSIZEGB=20 BOOTFROM=d PASSWORD=...
```

- `-w /tests` matters: results land in `e2e/testresults/` (screenshots,
  per-assert serial captures, video) instead of being lost inside the
  container.
- `--network host` matters: the guest's slirp gateway 10.0.2.2 reaches the
  **host** directly → a plain `python3 -m http.server` on the host serves the
  `ins` binary + questions file into the VM (`curl 10.0.2.2:8000/...`).
- UEFI is available in the same container (OVMF firmware shipped) — a
  BIOS + UEFI matrix needs only `UEFI=1` vars.

## Test architecture

`casedir/main.pm` declares two consoles and loads three modules:

- `tests/boot.pm` — `assert_screen 'bootloader'` (syslinux menu needle),
  Tab-edit the kernel cmdline to add `console=hvc0`, `assert_screen
  'archiso-prompt'` (tty1 autologin needle), then
  `select_console 'root-console'` → all further interaction is **text over
  the virtio console** (`wait_serial`/`script_run`/`assert_script_run`): log
  in as root, `stty cols 400`, curl `ins` (39 MB release binary) +
  questions file from the host, smoke `ins arch list`, then
  `ins arch exec --dry-run --trust-config` in the live ISO.
- `tests/install.pm` — the real `ins arch exec --trust-config -f
  questions.toml` (3 h timeout), asserts `INSTALL_RC=0` and key log lines,
  uploads the install log as artifact, dumps its tail to serial for
  debugging, then `swapoff` + `umount -R /mnt` + `sync`, `eject_cd`, clean
  ACPI shutdown (`power('acpi')` + `check_shutdown`), `power('reset')`
  (QEMU runs with `-no-shutdown` → reset reboots the powered-off VM; SeaBIOS
  falls through to the hard disk), `select_console 'user-console'`.
- `tests/verify.pm` — `assert_screen 'installed-login'` on VGA
  (`ins-e2e-vm login:` needle; also proves the configured hostname), blind
  login as root, start `serial-getty@hvc0` from inside, then the whole
  verification suite over serial: hostname, user, systemd healthy
  (`--failed` empty, NetworkManager/sshd active), ext4 root + fstab sanity,
  active swap, GRUB stage1 magic in the MBR, non-empty grub.cfg with menu
  entries, expected packages, slirp connectivity.

Needles are only used for the two boot menus + login prompt; everything
else is text matching on the virtio console.

## How `ins arch` is structured (test-relevant)

- `ins arch install` = wizard → saves answers to `/etc/instant/questions.toml`
  → `ins arch exec` → finished menu. Requires a TTY (relaunches itself in a
  terminal otherwise), root, internet, Arch distro.
- `ins arch exec -f questions.toml [--dry-run] [--trust-config]` runs the
  full install from a config file (steps: Disk → Base → Fstab → Config →
  Bootloader → Post). Copies its own binary into the target as
  `/usr/bin/ins-install` and re-invokes itself inside the chroot for
  Config/Bootloader/Post → a single self-contained binary + config file is
  all the VM needs.
- The chroot steps clean up after themselves: the target's
  `/usr/bin/ins-install`, `/etc/instant/install_config.toml` and state file
  are removed at the end (no password leakage on the installed system).
- Wizard "Install" flow **auto-applies unattended defaults for all optional
  questions** — `ins arch install` only *asks* ~10 required questions
  (keymap, disk, partitioning method, hostname, username, password,
  encryption yes/no, mirror region, timezone, locale, kernel) and defaults
  to the full instantOS experience (instantWM + GDM + btrfs + plymouth).
  So the wizard path e2e would test the real default user outcome, while
  the exec path tests arbitrary configurations (TTY-only minimal is fastest
  to verify). All questions are plain `fzf` dialogs (no X needed) → the
  wizard is drivable over the serial console with `type_string` +
  `wait_serial`, no needles. Note the plain Arch ISO lacks fzf →
  `pacman -Sy fzf` in the live session as part of the test.
- Config TOML = serialized `InstallContext`: `answers` (StepId → string),
  `completed_steps`, `step_dependency_fingerprints`, `system_info`.
  `answers` keys are PascalCase StepIds (`Keymap`, `DesktopEnvironment`,
  ...), values are the `answer_value` vocabulary (`automatic`, `none/tty`,
  `gdm`, `linux`, `yes`/`no`, ...).
- Questions with `should_ask == false` for the chosen config must NOT have
  stored answers, else exec rejects the config as "irrelevant" (e.g. with
  `DesktopEnvironment = "none/tty"` there must be no `DisplayManager`,
  `Autologin` or `UseXorg` answer).

## Change made to `ins arch` (sanctioned by Ben)

`ins arch exec` used to require valid `step_dependency_fingerprints` in the
config (provenance that answers were recorded against current dependency
values). That's impossible to produce by hand and made hand-written/e2e
config files second-class. Added:

- `ins arch exec --trust-config` — skips provenance *rejection*; every answer
  is still validated semantically (`validate()`) and for relevance
  (`should_ask`), then fresh fingerprints are recomputed from the imported
  answers.
- **The flag is propagated into the chroot re-invocations** (that took an
  actual failed install to discover — see below).
- Default behavior (wizard-saved configs, `ins arch install`) is unchanged
  and still rejects stale provenance; existing tests kept, new tests added
  (`trusted_import_*` in `src/arch/engine/wizard_engine/tests.rs`).

## Host-side dry-run loop (fast iteration, no VM)

```sh
./target/release/ins arch exec --dry-run --trust-config -f assets/questions-minimal.toml
```

prints the whole plan (sfdisk, mkfs, pacstrap, chroot config, grub,
services). Plan for the minimal TTY config: DOS label, swap sized to RAM
(note: **swap = full RAM size** — with 63 GB host RAM the dry-run planned a
63 G swap; on a small disk that's a real-world bug worth flagging), ext4
root, `pacstrap base linux-firmware linux intel-ucode`, in-chroot package
set incl. `grub os-prober qemu-guest-agent networkmanager openssh`,
GRUB→MBR, NetworkManager/sshd/timesyncd/qemu-guest-agent enabled.

## Bugs found by the e2e so far

### 1. Hand-written configs rejected by the chroot re-invocation (fixed)

First real-install attempt died after ~9 min — pacstrap (156 packages), the
in-chroot package set and `mkinitcpio` all succeeded, then:

```
Step Config requires chroot, setting up and entering...
Loading configuration from: /etc/instant/install_config.toml
Error: Refusing to execute an invalid configuration
    1: the stored answer for PartitioningMethod is stale: ...
```

The Config/Bootloader/Post steps re-invoke the installer *inside* the chroot
(`arch-chroot /mnt /usr/bin/ins-install arch exec config ...`). That inner
invocation re-validated the copied config **strictly** — a hand-written file
has no fingerprints, so the inner run rejected what the outer `--trust-config`
run had accepted. Wizard-saved configs never hit this (they carry valid
provenance). Fix: propagate the flag into the chroot invocation
(`src/arch/execution/mod.rs`, `execute_step`). Invisible to unit tests
because the strict/lenient decision is re-made in a separate process.

### 2. Empty `grub.cfg` could look like a successful install (hardened)

Two installs landed in the GRUB shell after `INSTALL_RC=0`. Forensics on the
captured disk (qemu-nbd + mount): valid GRUB stage1 + core.img, populated
`/boot/grub/i386-pc`, log shows grub-mkconfig finding kernels and finishing —
but the on-disk `grub.cfg` was **0 bytes, mode 0600**.

Primary trigger turned out to be the *harness*: QEMU disks are attached with
`cache.no-flush=on`, and a raw `system_reset` with `/mnt` still mounted
discards the last unflushed writes — exactly grub.cfg, written seconds
before. The e2e now releases the target filesystem and shuts the live system
down cleanly (ACPI) before resetting, like a real user's reboot.

But an installer should never *look* successful with an unbootable result,
and the empty-cfg failure itself was nondeterministic — so `configure_grub`
now bails if the generated `/boot/grub/grub.cfg` contains no `menuentry`.

Other observations from the install logs (non-fatal, already handled by ins):
`pacman -Scc` on the live ISO fails ("could not access database directory") —
best-effort; `increase_cowspace` remount fails on archiso — warning only.

## Serial-console gotchas (cost real debugging time)

- The hvc0 getty prompt is **colored**, so `root@archiso` never appears
  contiguously in the byte stream — match the plain `# ` prompt instead.
- The serial tty defaults to 80 columns; **long typed commands wrap** and
  bash's line redraws (`ESC[K`) split the echoed text, which breaks
  `script_run`'s echo confirmation ("typing command ... timed out"). Fix:
  `script_run('stty cols 400 rows 100')` right after login.
- `consoles` are **distribution-declared**: `select_console('root-console')`
  dies ("console does not exist") unless the casedir calls
  `$testapi::distri->add_console(...)` in `main.pm`. The QEMU backend wires
  up the virtio-console FIFOs itself (VIRTIO_CONSOLE=1 default); the class
  is `virtio-terminal`, and the guest needs `console=hvc0` so systemd's
  getty-generator spawns `serial-getty@hvc0`.
- **`type_password` neither reads `$PASSWORD` nor presses Enter**: in
  standalone mode `$password` is only set via `testapi::set_password(...)`
  (main.pm), and a `send_key 'ret'` is needed after typing. Missing either
  looks like "Login incorrect" or silently swallowed keystrokes.
- VGA-console login needs needles for *both* the `Password:` prompt and the
  shell prompt: `login` flushes pending tty input when the password prompt
  appears (type too early → empty password), and the prompt is colored so
  the text can't be matched (needles cropped from bootcap captures).
- After starting `serial-getty@hvc0` from the VGA session, **the serial side
  still needs a full login** (root + password) — `wait_serial '# '` cannot
  match at a `login:` prompt.
- The installed system gets `/dev/hvc0` for free: Arch's kernel has
  `CONFIG_VIRTIO_CONSOLE=y` (built in, no module needed).
- Under TCG install load, the virtual CD can throw **SQUASHFS EIO errors**
  (observed once mid-install) — treat as environment flake; a retry policy
  or IDE cd model may help if it recurs.
- `vars.json` **persists in the casedir between runs** and is rewritten by
  isotovideo — stale vars silently leak into the next run. Delete it before
  runs; pass vars via CLI.
- Docker runs as root inside the container → result files are root-owned;
  chown after runs. Don't pipe the docker run through `grep | head` —
  SIGPIPE kills the run mid-flight. Redirect to a file instead.
- A killed run leaves QEMU/ports bound on the host (`--network host`); kill
  strays before rerunning.
- `upload_logs('/tmp/install.log', failok => 1)` + dumping the log tail to
  the serial console are essential — without them a failed run takes the
  only copy of the in-guest log down with the container.

## Forensics tooling that worked

```sh
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 casedir/raid/hd0   # attach the VM's disk
sudo mount /dev/nbd0p2 /mnt/e2e-inspect          # inspect the installed root
sudo qemu-nbd --disconnect /dev/nbd0             # detach (after umount)
```

- Repairing a broken install offline: chroot into the mounted root and
  re-run `grub-mkconfig` (or ins' own `arch exec bootloader` with a
  fabricated `/etc/instant/install_state.toml`).
- Booting a bare qcow2 without the installer: copy it (QEMU needs the file
  writable; a read-only bind mount fails with "could not read the boot
  disk") and run isotovideo with `HDD_1=<path> BOOTFROM=c`, no ISO.
- Locating text rows in screenshots for needle areas: PIL brightness scan
  instead of eyeballing crops.

## CI integration (implemented: `.github/workflows/e2e-nightly.yml`)

Nightly schedule + manual dispatch. Two modes via the `E2E_SMOKE` var
(`main.pm` skips install/verify when set):

- **Smoke** (~5–8 min): ISO boot, needles, serial console, `ins` injection,
  in-VM dry-run. Cheap enough to run per-PR if wanted.
- **Full** (~1 h on 4-vCPU hosted runners, TCG): adds the real install,
  clean reboot and the post-reboot verification suite.

```yaml
- run: |
    docker run --rm -v .:/tests \
      registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86 \
      --exit-status-from-test-results qemu_no_kvm=1 casedir=/tests ...
```

`--exit-status-from-test-results` → non-zero exit on any failed module; test
results (screenshots, serial captures, install log) are uploaded as an
artifact on every run. Hosted runners expose no `/dev/kvm` — a KVM-capable
self-hosted runner plus the `qemu-kvm` container variant and `--device
/dev/kvm` drops the full run to a few minutes. The ISO is downloaded fresh
each run (~1.6 GB); add `actions/cache` keyed on the ISO date if that ever
matters. This repo's CI already builds in an Arch container, so an
Arch-native os-autoinst install (no pacman package; AUR only) is *not* the
easy path — the container is.

## Separate repo?

Not recommended right now. The suite is tightly coupled to product internals
on purpose: the questions fixture encodes the `StepId`/`answer_value`
vocabulary and the relevance rules, needles bake in installer-rendered
text/hostname, and the pipeline builds `ins` from the same checkout. Keeping
it in-repo means a schema or wording PR updates fixture and needles in the
same commit (the `--trust-config` chroot fix + its e2e assertions are the
proof case), and it matches the existing pattern (`tests/*.sh` live in-tree
too). Also covered above: `release-plz` paths-ignore now skips `e2e/**` so
test churn doesn't trigger release runs.

Revisit a split when one of these becomes true:

- the suite starts testing **multiple repos/products** (instantOS ISO,
  instantMENU) — openQA's own convention is one test-distri repo per target,
  versioned independently;
- the matrix grows enough to need its own **runner fleet / secrets /
  flake-quarantine policy** (KVM machine, UEFI, btrfs, full instantOS
  desktop...);
- **needle re-capture churn** starts polluting main-repo history.

If/when moving: take `e2e/` + the nightly workflow, pin the product ref the
suite tests (checkout of instantCLI at a tag inside the job), and trigger
full runs via `repository_dispatch` from instantCLI releases — the casedir
itself is already location-independent (`casedir=/tests`), so the move is
cheap precisely because the in-repo layout kept it self-contained.

## Native (non-container) build status

Not attempted; the container is the documented standalone/CI mechanism.
Native needs cmake + OpenCV dev + ~40 Perl modules (most exist as Ubuntu
packages, a few via cpan). Left as future work.

## Current status / next steps

- [x] Milestone 1: boot ISO, needles, serial console, inject `ins`, in-VM
      dry-run (202 s)
- [x] Milestone 2: real install under TCG (~20 min) with log capture
- [x] Milestone 3: clean shutdown → reboot from disk → post-reboot
      verification suite (`installed-login` needle + serial asserts)
- [x] Milestone 4: verification suite fully green against the installed
      system (boot from disk → VGA login via needles → serial handoff →
      14/14 asserts). Gotchas that cost time: `type_password` needs
      `set_password` + explicit Enter; login/password/shell-prompt all need
      needles (tty input flush + colored prompt); fstab columns for awk are
      `<fs> <dir> <type> <options>`; os-autoinst overlays a provided
      `HDD_1` image assuming **raw** backing format (`-F raw`) — convert
      qcow2 to raw first; unclean QEMU termination (SIGTERM at container
      teardown) discards unflushed guest writes (same no-flush caveat as
      the reset).
- [x] Single-run green pipeline (see verdict at top).
- [ ] Stabilize: the dry-run "flake" was diagnosed and fixed — my own
      menuentry check read the not-yet-existing grub.cfg in dry-run mode
      (skip in dry-run). SQUASHFS EIO burst during install (TCG + virtual
      CD) remains an environment-level risk to watch.
- [ ] Wire the suite into CI (nightly workflow, needs an ISO artifact —
      download in the job or cached)
- [ ] Wizard path: `ins arch install` driven over the serial console with
      fzf keystrokes; defaults yield instantWM+GDM+btrfs — verify a full
      instantOS desktop boot (slow under TCG; needs KVM runner to be nice)
- [ ] UEFI variant (`UEFI=1` + OVMF is in the container) — installer has a
      separate ESP/GRUB path worth covering
- [ ] btrfs variant of the questions file (subvolume checks in verify)
- [ ] Full instantOS (MinimalMode=no) exec path

## Unrelated pre-existing test failures noted

`cargo test` on a clean tree fails two tests (verified via stash):
`settings::users::ssh_keys::tests::foreign_store_targets_the_users_home` and
`video::render::ffmpeg::compiler::tests::rendered_repeated_cuts_...` — not
related to the e2e work, flagging for completeness.

---

## Where the installer's time goes (profiling, 2026-09-20)

The installer now reports its own timing: every spawned command gets a
`DONE (Xs): <cmd>` line in `/var/log/instantos/install.log` (uploaded as
`ulogs/executor-install.log`), slow commands (>=10s) and per-step totals are
printed to stdout (captured in `ulogs/install-install.log`). Summarize with
`tools/analyze_install_log.py`.

Full profile, TCG, 8 vCPU, before the size/duration optimizations (commit
87bd002c's baseline, `run.sh --profile full`):

| Step      | Duration | Dominated by                                   |
|-----------|---------:|------------------------------------------------|
| Disk      |      4s  | sfdisk + mkfs                                  |
| Base      |  9m56s   | pacstrap 683 MiB download (firmware meta!)     |
| Fstab     |      1s  | genfstab                                       |
| Config    |  8m11s   | standard packages 410 MiB / 158 pkgs           |
| Bootloader|      6s  | grub-install + grub-mkconfig                   |
| Post      | 10m00s   | instant packages 480 MiB / 461 pkgs + theme -R |

~91% of install time is package download+extract; ~1.57 GiB downloaded,
~4.7 GiB installed, 775 packages across three transactions.

After the optimizations (same profile): install 28m23s -> 22m07s:

- firmware vendor splits selected by detected GPU + NIC vendors instead of
  the `linux-firmware` meta (VM shape: pacstrap drops ~450 MiB; Base
  9m56s -> 5m57s)
- `linux-headers` only when a DKMS driver actually needs them
- `ParallelDownloads = 10` (was the uncommented default 5)
- no D-Bus stalls in the chroot (`timedatectl`/`localectl` replaced by
  direct config writes)
- Post 10m00s -> 9m35s, Config 8m11s -> 6m20s

Considered and rejected:
- merging the standard+instant package transactions saves ~1 min but
  couples the Config step to the `[instant]` repo and breaks `ins arch
  setup` reuse
- deferring the Config-step `mkinitcpio -P` to the Post step's
  `plymouth-set-default-theme -R` saves ~70s under TCG but was consciously
  dropped in 87bd002c: each step should leave a bootable, consistent
  system (encryption/btrfs hooks in the image as soon as the conf is
  written), and the Post rebuild is then a cosmetic, warn-only nicety

### The "missing Plymouth theme" that wasn't

The full/encrypted profile assert
`bsdtar -tf /boot/initramfs-linux.img | grep -q plymouth/themes/instantos`
failed on a good install. mkinitcpio images are a leading *uncompressed*
early-microcode cpio followed by the *zstd* main archive; bsdtar only reads
the first segment, so the theme (present and verified — extracted manually
and inspected) was invisible to it. The assert now uses the target's own
`lsinitcpio`, which understands the container format. Diagnostics that
helped: qemu-img-convert the casedir qcow2 disk, mount it, inspect
`/boot`, `/etc/plymouth/plymouthd.conf` and the mkinitcpio plymouth hook
(the hook embeds the theme reported by `plymouth-set-default-theme` at
build time, so the conf must be written before the rebuild — the installer
does this).
