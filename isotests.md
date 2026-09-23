# instantOS live ISO — e2e testing investigation (`isotests.md`)

Research log and recommendation for boot-testing the instantOS live ISO with
the `instantOS-e2e` suite. Produced 2026-09-21 by actually building ISOs and
booting them under os-autoinst/isotovideo.

Legend: ✅ empirical (ran here) · 📋 static analysis · ⏳ pending run

---

## 0. Verdict (TL;DR)

**Yes — extending the suite with live-ISO tests is a good idea**, and the
prototype already works:

* The repo's own `iso/README.md` anticipates it ("later, the instantOS ISO");
  `iso/verify.sh` verifies ISO *content* statically but nothing ever *boots*
  the image. Everything runtime — greetd autologin, the Wayland session race,
  Welcome autostart, wallpaper, service startup — is untested.
* A full discovery run (boot menu → wallpapered desktop → serial forensics)
  takes **~15 min on TCG**, no KVM needed; ~2 min expected with KVM.
* The mechanics port directly from the main suite: needles + `assert_screen`
  for the boot menu and Welcome window, root login over the virtio console
  for hard assertions, screenshots for the wallpaper.
* It pays for itself immediately: this investigation found and fixed a
  **build-breaking bug** (`broadcom-wl` vanished from the Arch repos),
  **confirmed a serious silent live-setup bug** (`liveautostart` never
  executes on the release ISO: no NetworkManager, cowspace stuck at 256 M —
  §3.9; proven fixed on `ins ≥ 0.14.9` by run 3b), **found the wallpaper was
  never applied on any current image** (swaybg not packaged +
  `appearance.wallpaper_path` unset — §3.14, fixed), found **instantwm
  keeping killed windows' last frames on screen** (§3.13), and documented
  several more findings (§3) — none of which any existing check would have
  caught before release day.

Prototype harness: `diag/liveiso/` (independent of the main suite, shares
`casedir/needles/`). Current state: assert-based module (v6: early
bare-desktop `live-bar` capture, no kill step), 3 needles; runs 3b and 4
**full green** — 3b on the X-less build B ISO, 4 on build C (swaybg +
wallpaper seed), which renders the default photo for the first time (§3.14).

---

## 1. What exists today 📋

| Piece | What it does | Runtime? |
|---|---|---|
| `iso/build.sh` | clones `releng/` → `build/instantlive`, copies `overlay/` + `syslinux/`, writes `/etc/instantos/version`, fetches dotfiles/instantTOOLS/liveutils, runs mkarchiso (via `just build-iso-docker`), then `verify.sh` | build only |
| `iso/verify.sh` | static verifier: unsquashfs `airootfs.sfs`, asserts setup marker `status=complete`, commit cross-checks (dotfiles/instanttools/liveutils manifest vs marker vs installed trees), greetd config contains `user = "instantos"` + `instantwm --backend drm`, dotfiles `.zshrc` hash equality, build-only pacman hook removed, optional version check | ❌ no boot |
| `.github/workflows/iso.yml` | "Build & Release ISO" — triggers **only** on push to `release` branch (+ manual dispatch) | build only |
| suite (`run.sh`, `casedir/`) | boots the **Arch** ISO, injects a freshly built `ins`, installs to disk, reboots, 14 post-install asserts | ✅ but installer path, not the live desktop |
| **nothing** | boots the instantOS live ISO into its desktop | ❌ gap |

**Gap proven by events**: `broadcom-wl` was removed from Arch's repos; the
instantOS ISO build failed with `error: target not found: broadcom-wl`; CI
would only ever notice at `release`-branch push time (see §3.1, §3.8).

---

## 2. Empirical: booting the release ISO ✅

* **ISO**: `instantos-2026.08.24-x86_64.iso` (release v2026.08.24-4,
  sha256-verified) — built after the 2026-08-14 greetd change, so it
  represents the current `iso/` design.
* **Harness**: `diag/liveiso/` — run 1 was zero-needle discovery (text waits
  on ttyS0 + screenshot every ~15 s), run 2 is the assert-based version.
* **Environment**: TCG only (no `/dev/kvm` on this host), `QEMUCPUS=8`,
  `QEMURAM=4096`, VGA 1024×768 (os-autoinst default EDID), `BOOTFROM=d`.
  Kernel cmdline gets `console=hvc0 console=ttyS0` via Tab-edit at the menu.

### Timeline (run 1, from `testresults/` mtimes + `serial0`)

| T+ | Event | Evidence |
|---|---|---|
| +0:00 | syslinux boot menu visible (mirrored to ttyS0 — `wait_serial('instantOS install medium')` works) | `liveiso-1.png` |
| +0:17 | kernel early boot (`Probing EDD…`) after cmdline edit | `liveiso-4.png` |
| ~+2:10 | serial getty banner + instantOS issue art + `instantlive login:` on ttyS0 | `serial0` |
| ~+2:22 | instantWM top bar + Welcome (kitty) window on screen — greetd won the VT race | `liveiso-13/14.png` |
| ~+5:03 | Welcome TUI fully rendered: fzf menu, title bar "Welcome to instantOS" | `liveiso-23/37.png` |
| end | root login on hvc0 (empty password works), forensics over serial | `virtio_console.log` |

Notes:

* **The Welcome window is fullscreen** — it covers the whole desktop below
  the bar from early on. Closing it does *not* reveal the desktop either:
  instantwm keeps the dead client's last frame on screen (§3.13 — run 3b:
  survivors empty, yet the post-SIGKILL frame differs from the Welcome frame
  only in the clock's bbox). The bare desktop is therefore captured
  **early**, in the gap between the bar appearing and the Welcome window
  opening (`live-bar` assert + save at the top of the module).
* The `video.ogv` recording spans the whole run in **~21 s with a non-linear
  time mapping** (screen-change driven) — extract frames with
  `ffmpeg -vf fps=1` and identify states *by content* (boot menu → boot text
  → bar + bare bg → Welcome), not by timestamp. That is how the
  bare-desktop frame (the `live-bar` source) was recovered.
* Needle validation (run 2, release ISO): `iso-bootloader` matched at
  **sim 1.00, +6 s**; `live-welcome` matched at **sim 0.98, T+5:05**
  (23:18:43 → 23:23:42) — bar-title area shifted ~3 px and still matched
  (97). Root login on hvc0 prompt followed ~15 s later (zshrc init).
* Welcome menu content is **network-dependent** ("Configure Network" appears
  only when offline) → needles anchor row 1 (`Install instantOS`) and the
  static preview pane only, never the full list.
* Plymouth printed `Terminate Plymouth Boot Screen` on ttyS0 although the
  archiso initramfs hooks contain no plymouth hook — ✅ explained by the
  run 2/4 `SECTION_plymouth` dump: plymouth runs from *rootfs systemd
  units* (`plymouth-start/quit/quit-wait/read-write.service` all
  active-exited), not from initramfs.
* Frame sizes give a poor-man's timeline: 118 KB menu → ~5.7 KB black kernel
  phase → 43 KB stable desktop.

### What empirically works

* greetd autologin `instantos` → `instantwm --backend drm` (Wayland session
  on vt=1), bar with workspaces/tray/clock.
* Welcome app via XDG autostart (`ins welcome --gui --force-live`), TUI with
  "Install instantOS" + installer preview.
* **Asserted green (run 2b/2c)**: `/opt/instantos/.setup-done` exists,
  `display-manager.service` → greetd symlink exists, `greetd` unit active,
  root login on hvc0 with empty password, both boot needles (sim 1.00 / 0.98).
* ⚠️ **`liveautostart` never runs on the release ISO** (§3.9, root cause
  settled run 2e: `ins 0.14.8` lacks the live block — introduced one release
  later in v0.14.9 — and no other Wayland-session caller exists) — NM
  inactive, cowspace left at 256 M, no end-marker. Welcome/mako/instantWM
  come up regardless, so the desktop *looks* right while the live setup
  silently does nothing — precisely the class of bug only a boot test
  catches. Fixed upstream (≥ v0.14.9); **proven by run 3b**: marker +
  NetworkManager asserts green on build B (`ins 0.14.14`).
* **Run 3b — full green on the X-less build B ISO** (EXIT=0, 45/47 details
  ok): boot-menu + Welcome needles matched,
  `! pacman -Q xorg-server` + `! pgrep -x Xorg` (only rootless Xwayland),
  Wayland socket present, marker + NetworkManager green — the complete
  "Wayland-only ISO boots to a working desktop *and* runs its live setup"
  proof.
* **Run 4 — full green on the build C ISO** (`instantos-2026.09.22`,
  EXIT=0, 48 details / 46 ok + 2 saves): the §3.14 wallpaper fix proven
  end to end — `pgrep -u instantos -x swaybg` rc=0, `SECTION_session_procs`
  shows `swaybg -i /usr/share/instantwallpaper/defaultphoto.png -m fill`
  running, and `run4-wallpaper-frame.png` (video extract) shows the photo
  edge-to-edge below the bar; the run-3b set re-proves green with the
  now-unconditional X-less asserts.
* Root-over-hvc0 forensics pattern works (empty root password on the live
  image).

---

## 3. Bugs and findings (ordered by severity)

### 3.1 🔴 `broadcom-wl` breaks the ISO build — **fixed**
`error: target not found: broadcom-wl` at pacstrap. Package left the Arch
repos (modern replacement: `broadcom-wl-dkms`; upstream archiso releng dropped
the line entirely). Fix applied: deleted the line from
`iso/releng/packages.x86_64` (matches releng). Build A proved the fix end to
end (full build + `verify.sh` pass); Build B (with the Xorg omission on top)
stayed green as well.

### 3.2 🔴 Xorg shipped on a Wayland-only distro — **removed (uncommitted)**
See §4 for the full inventory and rationale. Summary: the session path is
greetd → `instantwm --backend drm`; no package depends on `xorg-server`; X
*clients* from `instantdepend` only need XWayland.

### 3.3 🟡 The boot menu is branded **Arch Linux**
`iso/syslinux/splash.png` is byte-identical to releng's
(`md5 914969f793db805b330d0e9ab3f63c00`, 640×480 Arch logo): the instantOS
"install medium" menu renders over the Arch logo, letterboxed with gray
borders at 1024×768 (frame `liveiso-1.png`). `build.sh` copies
`iso/syslinux/*` over releng's, but the splash was never replaced.
*Fix left to the maintainer* (branding/art decision — drop in instantOS art,
ideally 1024×768). **If the splash changes, recapture the `iso-bootloader`
needle** — its match areas sit on splash background pixels.

### 3.4 🟡 Stock **Arch motd** on the live root console
`/etc/motd` is the unmodified Arch text ("To install Arch Linux follow the
installation guide …") printed under the instantOS issue art at root login
(`serial0`, run 2 `SECTION_motd`). The overlay never replaces `/etc/motd`.

### 3.5 🟡 `iso/README.md` says **GDM**, code says **greetd**
`iso/README.md:24`: "The live user is configured for GDM autologin …" —
`instantos-setup` writes `/etc/greetd/config.toml` and links
`display-manager.service → greetd.service` (since 2026-08-14). Doc drift;
nobody has re-read the README since the switch.

### 3.6 🟡 `getty@tty1` autologin-root drop-in still ships next to greetd — **settled (run 2c)**
The releng `getty@tty1` autologin (root, vt=1) drop-in is still present in
the image (`/etc/systemd/system/getty@tty1.service.d/autologin.conf`), but the
unit is **`inactive (dead)`** — empirically it never runs: greetd wins the VT
completely. `fuser /dev/tty1` at T+10 min: `systemd-logind`, `greetd`,
`instantwm`, `Xwayland`, `i3status-rs`, `kitty`×3 (welcome) — no getty, no
root shell on the desktop VT. Recommendation: remove the drop-in from the
instantOS image (dead code with a live footgun if greetd ever fails to
start), or assert its absence in `verify.sh` like the build-only pacman hook.

### 3.7 🟡 `startx` fallback becomes dead once Xorg is removed
`rootinstall.sh:51-53` writes `/etc/X11/Xwrapper.config`
("enabling startx"). With no `xorg-server`, `startx` cannot work — **product
decision needed**: drop the Xwrapper write + any startx docs, or keep the
file (harmless) for a future Xorg install. Not removed in this change to keep
the package-list edit minimal.

### 3.8 🟡 CI blind spot: `iso.yml` only runs on the `release` branch
Package-rot like `broadcom-wl` surfaces exactly when you can least afford it.
Cheap mitigations: also trigger on `iso/**` paths, or a scheduled build.

### 3.9 🔴 **CONFIRMED BUG: `liveautostart` never runs on the release live image (runs 2c–2e; root cause settled 2e)**

`/run/instantos-liveautostart.done` never appears — and it isn't slow: after
a deliberate 6-minute wait loop the marker was still missing, no
`liveautostart`/`pacman` process existed at any sampled point, and every
observable side effect of the script is absent:

| expected effect | observed (run 2c) |
|---|---|
| marker touched at end of script | **absent** after 6+ min |
| `systemctl enable --now NetworkManager` | **NetworkManager `inactive`** |
| cowspace re mount to half of RAM (2 G on this 4 G VM) | still archiso default **`size=262144k`** |
| `pacman -Sy --needed ins` refresh | never ran (no pacman process) |
| user journal traces (autostart/sudo) | none |

Wiring traced statically:

* `instantwm` (Rust compositor, strings) starts
  `instantwm-session.target` + portals and runs **`ins autostart`**
  (`instantwm: failed to run ins autostart:` / `'ins' command not found…`
  error strings).
* instantCLI's **current** `src/autostart.rs::run()` (≥ v0.14.9; the
  release ISO's `ins 0.14.8` has **no live block at all** — see ROOT CAUSE
  below) does, in order: flock guard →
  `is_live_iso()` (checks `/run/archiso/cowspace` — true here) →
  **`Command::new("liveautostart").status()`** (PATH lookup — the script
  itself then re-execs `sudo`, which is fine: image sudoers has
  `%wheel NOPASSWD: ALL` and `instantos` is in `wheel`, `secure_path`
  includes `/usr/local/bin`) → `installapplet` → notifications (mako —
  **running** ✓) → settings → wallpaper → compositor setup (sway/i3/niri —
  all skipped: compositor is instantwm) → dot update → polkit →
  **welcome (last step — running** ✓).
* Observed: mako + welcome alive, everything between them absent; the
  `.desktop` route is ruled out anyway (no `instantos-*` user units ever
  load, and none of the ~10 stock `/etc/xdg/autostart` entries such as
  `nm-applet`, `picom`, `blueman` run either — the generator's target is
  never started). Resolution below.
* A legacy parallel chain exists in `autostart.sh` (= image
  `/usr/bin/instantautostart`, byte-identical) whose live branch does
  `sudo systemctl start NetworkManager` / `sudo liveautostart` /
  `installapplet` / `ins welcome --gui --force-live` — NM inactive and
  conky/installapplet/instantwallpaper all absent prove **that branch did
  not run** either.

**Run 2d results — hypotheses narrowed (release ISO):**

* ❌→✅ **PATH hypothesis refuted (2d)**: `SECTION_instantwm_env` shows
  instantwm's own `PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:…` and
  `is_live_iso()` = `/run/archiso/cowspace` exists (mount confirmed) — any
  spawn would have found `/usr/local/bin`; run 2e's child-env snapshots
  confirmed the same for the spawned tree (see ROOT CAUSE: the ENOENT
  theory died with the discovery that 0.14.8 has no such spawn at all).
* ✅ **`ins autostart` ran**: `SECTION_autostart_lock` —
  `/run/user/1000/instant_autostart.lock` **absent**, but
  **`/tmp/instant_autostart.lock` exists** (mtime = session start) — first
  attributed to a missing `XDG_RUNTIME_DIR`; the real reason is version
  drift (0.14.8's PID-file check always writes to `temp_dir()` — see ROOT
  CAUSE). The
  lock holds a **3-byte PID** (100–999 = instantwm's child range; root's
  hvc0 login shells are 13xx+ → 4 bytes) → the writer was instantwm's
  `ins autostart`, not a root-shell re-run.
* ✅ **The script never ran as root**: it has **no `set -e`** and every step
  after the done-check is guarded (`checkinternet` in an `if`, pacman behind
  `||`), so the only way to reach the observed state is to have never
  executed `systemctl enable --now NetworkManager` (line 28) — NM `inactive`
  and cowspace still `size=262144k` prove lines 28/47 were never reached,
  and the end-marker (line 50) is absent. The script *cannot* die silently
  mid-way — it was simply never executed (see ROOT CAUSE).
* ✅ **Steps *after* the would-be live block ran**: `hyprpolkitagent`
  (polkit) and welcome (the last step) are running — with `installapplet`
  absent too, consistent with 0.14.8 having no live block whatsoever.
* ✅ **The `.desktop` route is dead in this session**: no `instantos-*`
  user units loaded (`SECTION_user_units`), so welcome came from
  `ins autostart`'s own welcome step (consistent: its args are
  `force_live=false`, whereas the `.desktop` would pass `--force-live`).
* **Network before NM**: releng enables `systemd-networkd` + `resolved` +
  `iwd` — that's how welcome had internet with NetworkManager off; it does
  *not* exonerate the script (NM/cowspace/marker are script-side effects).
* **Version drift matters** — which code actually ran is decisive; see the
  version table in ROOT CAUSE (release ISO = `ins 0.14.8` /
  `instantwm 0.1.20`, one release short of the fix).

**ROOT CAUSE SETTLED (run 2e + git archaeology):**

* ❌ **Env-stripping refuted**: `SECTION_child_env` — kitty (a direct child of
  `ins autostart`) carries the full instantwm PATH *including*
  `/usr/local/bin`, `XDG_RUNTIME_DIR=/run/user/1000`, the session bus and
  `WAYLAND_DISPLAY` — the spawn env was healthy. (mako/hyprpolkitagent show a
  constructed `PATH=/usr/local/bin:/usr/bin` — also `/usr/local/bin`-bearing;
  they explain nothing.)
* ✅ **The `/tmp` lock is old code, not env drift**: `ins 0.14.8`'s
  `is_already_running()` is the *pre-flock* PID-file design writing
  unconditionally to `std::env::temp_dir()` → `/tmp` (lock pid 995 =
  instantwm's child range ✓). The XDG-preferred flock in today's
  `src/autostart.rs` is newer code.
* 🔴 **`ins 0.14.8`'s `autostart::run()` contains no live block at all** —
  no `liveautostart`, no `installapplet`; it goes guard → nvidia → settings →
  compositor setup → dot update → wallpaper → polkit → welcome. The live
  block was added in commit `268855d9` *"auto launch live iso autostart if
  necessary"*, first released in **`v0.14.9`** — the release ISO ships
  `ins 0.14.8-1`, **one release short**.
* 🔴 **No other caller exists on the live Wayland session**: the legacy
  `autostart.sh` path (its line 198 `sudo liveautostart` / line 200 welcome)
  is only wired through the **i3/X11** config (`dex --autostart`,
  `bash ~/.instantautostart`); instantwm runs only `ins autostart`. Its own
  side effects (NM start, conky, installapplet, wallpaper set) are absent,
  confirming it never ran. → **On the release ISO nothing ever invokes
  `/usr/local/bin/liveautostart`** — an orphaned script. All observed
  symptoms follow (NM inactive, cowspace 256 M, no marker, no installapplet)
  while settings/polkit/welcome (the rest of `run()`) complete normally.
* **Fix status**: the live block exists in every instantCLI ≥ v0.14.9;
  build B carries `ins 0.14.14` — **run 3b booted the build B ISO with
  marker + NetworkManager asserts green**, the regression test that pins
  this.
* Versions in play: release ISO `ins 0.14.8` / `instantwm 0.1.20`;
  build B `ins 0.14.14` / `instantwm 0.1.24`; local checkouts
  `ins 0.14.20` / `instantwm 0.3.1`.
* Also explained by version drift:0.14.8 has no
  `ensure_notification_daemon` (mako starts later, from settings apply —
  hence mako pid > kitty pid), and its step order differs from local source.

**Secondary finding (runs 2e + 3b) → §3.13**: the wallpaper step's `pkill`
reported success but the captured frame still showed the Welcome TUI. Run 3b
upgraded the test to SIGKILL + wait-until-vanished + survivor dump —
survivors **empty**, yet the frame still differs from the Welcome frame only
in the clock's bbox (99.92 % identical). That *settled* it as an instantwm
bug rather than a harness issue: the kill step was removed from the module
and the bare desktop is captured early instead (§3.13, §5).

**User-visible impact if unfixed**: no NetworkManager on the live desktop
(no nm-applet either), cowspace stuck at 256 M (writes to `/` hit ENOSPC
sooner), installer never refreshed from the repo. The suite keeps these as
**strict asserts** (moved to the end of the module so a failure still
leaves probes + wallpaper frame captured — order changed, coverage not
weakened).

### 3.10 🟡 Plymouth runs at boot with no plymouth initramfs hook — **settled (run 2c)**
`plymouth-start/quit/quit-wait/read-write.service` all `loaded active
exited` at runtime, while `HOOKS=(base systemd autodetect microcode modconf
kms keyboard sd-vconsole block filesystems fsck)` contains **no plymouth
hook** — so the live boot gets the plymouth *userspace* units (source of the
`Terminate Plymouth Boot Screen` serial noise) without an initramfs splash.
Installed-system theming (`--profile full`) is a different path and stays
covered by verify.pm. Consider excluding plymouth autostart from the live
image.

### 3.11 🟡 The greetd session registers with logind as `Type=tty`, not `wayland` — **settled (run 2d/2e)**
instantwm's own environ has `XDG_SESSION_TYPE=tty`, and the logind assert
`loginctl show-session … -p Type | grep -q wayland` **failed** (rc 1);
run 2e raw dump: `Type=tty`, `Class=greeter`, `Active=yes` — greetd opens
the PAM session on a VT and nobody upgrades the type, so the desktop session
is advertised to logind as *tty*. Portals/tooling that key off
`XDG_SESSION_TYPE`/logind `Type` see a text session while a Wayland
compositor (plus rootless Xwayland) actually runs. The suite's wayland
assertion was therefore a **wrong test assumption**, fixed as: assert the
compositor's socket exists in the runtime dir (`ls /run/user/1000/wayland-*`),
with raw `Type`/`Class` still dumped for the record. Optionally, the product
could set `XDG_SESSION_TYPE=wayland` before greetd opens the session —
worth an upstream discussion, not asserted either way.

### 3.12 ℹ️ Journal scan (run 2c) — no serious first-boot errors
`journalctl -p err -b`: `virt/tdx: TDX not supported by the host platform`
(host note), `I/O error, dev fd0` (QEMU floppy probe — harmless noise),
`dbus-broker: Ignoring duplicate name 'org.freedesktop.Notifications' in
/usr/share/dbus-1/services/org.knopwob.dunst.service` (instantOS ships a
second dunst D-Bus service file next to the package's — packaging smell,
harmless). No failed systemd units of consequence.

### 3.13 🔴 instantwm keeps a killed window's last frame on screen (runs 2e + 3b, both versions)

Evidence chain:
* Run 2e (release, instantwm 0.1.20): plain-TERM kill "succeeded", yet the
  captured frame and a death frame 50 s later are **byte-identical md5** of
  the Welcome TUI.
* Run 3b (build B, instantwm 0.1.24): SIGKILL welcome+kitty+fzf, wait loop
  until `pgrep` reports no survivors (dump: empty, rc=1) — the screenshot
  taken afterwards still shows the full Welcome TUI: vs the pre-kill Welcome
  frame the **only** differing bbox is `(731,0,904,18)` — the live status-bar
  clock — 99.92 % pixels identical, row/preview/title bright-pixel counts
  equal.
* The compositor itself is alive and rendering (the bar's clock keeps
  ticking *over* the stale frame).

So a destroyed client's last committed surface is never dropped — the dead
window stays composited (0.1.20 and 0.1.24; local checkout 0.3.1 not
tested). User impact: killing a fullscreen app — or it crashing — leaves a
frozen ghost on screen until something else forces a full repaint.

Test-side consequence: "kill Welcome → screenshot the wallpaper" can never
work; the module captures the **pre-Welcome** desktop instead (`live-bar`,
§5/§7). Product-side: needs an instantwm fix (drop surfaces on client
disconnect) — not done here (instantWM repo, and the renderer path deserves
its own change + regression test).

### 3.14 🔴 The wallpaper is never applied on current images — **fixed (uncommitted)**

Symptom: every bare-desktop frame shows instantwm's plain background — no
wallpaper art ever appears on live (release **and** build B), and `swaybg`
never runs (`SECTION_session_procs` has no swaybg on either ISO). Two
independent causes:

1. **`swaybg` is not packaged** — `iso/releng/packages.x86_64` never shipped
   it, the build airootfs has no `/usr/bin/swaybg`, while instantwm's
   Wayland `set_wallpaper()` *spawns `swaybg -i <path> -m fill`* (X11 uses
   feh). Any `ins wallpaper set` on the live image fails at spawn
   (`instantWM/src/backend/mod.rs:289`).
2. **No wallpaper is configured** — `apply_configured_wallpaper()`
   (`instantCLI/src/wallpaper/commands.rs:103`) bails with "No wallpaper
   configured" when `appearance.wallpaper_path` is unset, *before* compositor
   dispatch. The live user is created with `useradd -m -k <empty skel>` (no
   settings file), dotfiles ship no `settings.toml`, and `liveautostart`
   does nothing wallpaper-related — so `ins autostart`'s wallpaper step
   (which runs first, before anything that can block on the network) fails
   into a discarded stdout/stderr and continues.

**Fixes applied (uncommitted, instantOS repo)**:
* `iso/releng/packages.x86_64`: **+ `swaybg`** (with comment).
* `iso/overlay/usr/local/bin/instantos-setup`: seed
  `/home/instantos/.config/instant/settings.toml` with
  `[appearance] wallpaper_path = "/usr/share/instantwallpaper/defaultphoto.png"`
  (create-if-absent; dotfiles don't ship that file today).
* `iso/overlay/etc/skel/.config/instant/settings.toml`: same seed for
  installed systems (`ins arch` creates users with plain `useradd -m` →
  default skel).

**Validated by build C + run 4 — green (EXIT=0, 48 details)**:
* package level: `swaybg-1.2.2-1` in the image's 932-package list, with
  `/usr/bin/swaybg` present in airootfs;
* process level: strict assert `pgrep -u instantos -x swaybg` rc=0, and
  `SECTION_session_procs` shows `instant+ … swaybg -i
  /usr/share/instantwallpaper/defaultphoto.png -m fill` running (158 s at
  dump time);
* pixel level: `diag/liveiso/run4-wallpaper-frame.png` (run 4 `video.ogv`,
  fps=1 extract) — the default photo rendered edge-to-edge below the bar
  in the gap before the Welcome window opens.

Timing nuance: the module's early `live-bar` save fires at the bar's
*first paint*, which can precede swaybg's first frame — the saved frame
(`liveiso-2.png`) still shows the pre-wallpaper background. That is
expected; wallpaper pixels are evidenced by the process assert + video,
not by the saved screenshot.

---

## 4. Xorg removal — inventory, change, numbers

### Inventory (3 sources of X on the ISO) 📋✅

1. **`iso/releng/packages.x86_64` groups**: `xorg`, `xorg-drivers`,
   `xorg-xinit`, plus explicit `xf86-input-evdev`, `xf86-input-synaptics`
   (~59 pkgs total incl. `xorg-server`, xf86 drivers, x11 utils, Xephyr/Xvfb).
2. **`instantdepend` X clients**: `feh`, `rofi`, `xdotool`, `xclip`,
   `xdragon` (+ `xorg-xinput`, `xorg-xsetroot` pulled by dotfiles tooling) —
   these need **XWayland**, not Xorg.
3. **`rootinstall.sh`**: `Xwrapper.config` + "enabling startx" (§3.7).

Not a source: greetd already launches `instantwm --backend drm`
(`instantos-setup` writes the greetd config; `verify.sh` asserts it). No
package in the list has a hard dependency on `xorg-server` (checked against
current core/extra/multilib/instant DBs ✅).

### The change (applied, uncommitted — `git diff iso/releng/packages.x86_64`)

```diff
-broadcom-wl
-xf86-input-evdev
-xf86-input-synaptics
-xorg
-xorg-drivers
-xorg-xinit
+# X clients from instantdepend (feh/rofi/xdotool/xclip) run in the Wayland
+# session through XWayland; the Xorg server itself is not shipped — greetd
+# autologins straight into instantwm --backend drm and no package depends on
+# xorg-server.
+xorg-xwayland
```

### Numbers ✅ (build A vs build B, both green + `verify.sh` pass)
* Build A (broadcom fix only): **1441.13 MiB download / 4442.08 MiB
  installed**; ISO ≈ 1.9 G; squashfs 1604402.57 K comp / 4591178.92 K raw.
* Build B (Xorg-less): **1409.29 MiB download / 4379.58 MiB installed**,
  931 packages; ISO **1.80 GiB**; squashfs 1572134.34 K comp / 4525585.59 K
  raw.
* **Delta: −31.84 MiB download, −62.50 MiB installed, −~60 packages,
  −~64 MiB raw rootfs, −~31 MiB compressed squashfs, −~100 MB ISO.**
* Build B log confirms the intent: no `installing xorg-server…` line (only
  `xorg-server-common`, the xwayland dependency), no `broadcom-wl`
  (`linux-firmware-broadcom`/`b43-fwcutter` are unrelated firmware and stay).
* Transitive note ✅: `xorg-xwayland` depends on `xorg-server-common` (Arch DB
  check), so common (XKB/protocol data) legitimately remains — runtime asserts
  target `xorg-server` specifically, **not** the `xorg-*` namespace.

### Runtime assertions (unconditional in the module)
```perl
assert_script_run('! pacman -Q xorg-server', timeout => 60);
assert_script_run('! pgrep -x Xorg',          timeout => 60);
```
(An `E2E_ISO_XORG` toggle existed while the module still had to boot both
the archived X-ful images and the new X-less builds; with the removal in
§4 there is no Xorg-containing ISO to support, so the flag was dropped and
the X-less expectation is unconditional — the assert *is* the pin on the
decision.)
plus the always-on ones: Wayland compositor socket in `/run/user/1000`
(logind `Type` is `tty`, §3.11), greetd active, instantwm + Welcome
processes, `swaybg` running (wallpaper, §3.14), live-setup marker +
NetworkManager.

**All green on run 3b** (build B, EXIT=0): `xorg-server`/`xorg-xinit`/
`xf86-input-evdev`/`xf86-input-synaptics` not found, no `Xorg` process,
`Xwayland :0 -rootless` running, socket present — the X-less default is
proven at runtime.

**Runtime X evidence from the release ISO (run 2c `SECTION_xstack`)** — the
X-ful image still never uses Xorg: `xorg-server 21.1.24-1`,
`xorg-xinit`, `xf86-input-evdev`, `xf86-input-synaptics` all *installed*,
`pgrep -ax Xorg` **empty**, only `Xwayland :0 -rootless -wm 26` running
(wm-owned rootless mode — exactly the supported Wayland path),
`/tmp/.X11-unix/X0` owned by instantos, `Xwrapper.config` =
`allowed_users=anybody` present (the startx fallback, §3.7). Removing the
Xorg group changes nothing at runtime.

---

## 5. Proposed suite integration (design)

### Entry point
Add a `--iso` / live mode to `run.sh`:
* `E2E_ISO_NAME` / `E2E_MEDIA_DIR` env already supported by the prototype's
  `diag/liveiso/run.sh`; port the same into the main `run.sh`.
* Skip the cargo build + asset-server entirely (the live test never injects
  `ins` — it tests the ISO as shipped). Everything else (docker, needles,
  artifacts) is identical.

### Module & flow (current `diag/liveiso/tests/liveiso.pm`, ready to move in)
1. `assert_screen('iso-bootloader', 180)` — **before** the 14 s countdown
   expires (Tab-edit must still work).
2. Tab-append `console=hvc0 console=ttyS0` → scripted root login on hvc0 +
   boot messages on ttyS0, then `exec bash --norc` (marker traps, see
   gotchas).
3. `assert_screen('live-bar', 1200)` → `save_screenshot()` — the **bare
   desktop in the pre-Welcome gap** (bar-only needle; opaque bar makes it
   wallpaper-art agnostic) — then `assert_screen('live-welcome', 1200)` for
   desktop + Welcome TUI. (No kill step: instantwm keeps dead windows'
   frames, §3.13. Run 4 note: the save lands at bar-first-paint and may
   precede swaybg's first frame — §3.14 timing nuance; wallpaper pixels
   come from the process assert + video, not this save.)
4. Switch to root-console, scripted root login, `exec bash --norc`.
5. Bounded wait for the liveautostart end-marker (up to 6 min — *then*
   assert, so slow ≠ broken).
6. Section dumps **before** strict asserts (sessions, procs, tty1 owner,
   X-stack, wallpaper, greetd cfg, plymouth, motd, journal errors, plus the
   root-cause probes: autostart lock, greetd journal, instantwm env,
   user units) — a failing assert still leaves evidence.
7. Strict asserts: setup marker, DM link, greetd active, instantwm +
   Welcome processes, cowspace, Wayland socket, Xorg absent
   (`pacman` + `pgrep`, unconditional).
8. The live-setup asserts (marker + NetworkManager) and `pgrep -x swaybg`
   (wallpaper end-to-end) run **last** — coverage identical, evidence-first
   ordering.

### Needles (`tools/make_needle.py`, all in `casedir/needles/`)
| tag | source | areas | status |
|---|---|---|---|
| `iso-bootloader` | run 1 `liveiso-1.png` | menu entries (x136 y210 410×50) + help text (x8 y405 350×36) | ✅ |
| `live-welcome` | run 3 `liveiso-9.png` (recropped) | fzf row 1 (46,136 460×33) + preview pane (520,105 470×88) + **widened** title (370,0 170×17) | ✅ |
| `live-bar` | run 3b video frame t=18 (`video.ogv`, fps=1 extract) | bar row only: ws strip (0,0 190×17) + empty title center (350,1 260×14) | ✅ |

Rules learned: never crop the countdown line, clock, or RAM/network readouts;
anchor stable text rows; remember needles match *pixels*, so a new splash art
invalidates `iso-bootloader`. **Run 3 failure = needle lesson**: the original
`live-welcome` title area (104×15 of thin *centered* text) went from sim ~1.0
on the release frame to **0.02** on build B — the centered title shifted ~2–3 px
between package sets while the left-anchored row/preview stayed 91–93 % identical,
dragging the whole needle to 0.44 (assert timeout). Fix: rebuild the needle from
the new frame and keep centered titles inside a **wide, background-heavy area**
so small position shifts stay cheap. (Also: needle JSON uses `"area"`, singular.)

**Why `live-wallpaper` became `live-bar`**: no image ever renders wallpaper
art (§3.14), so the planned below-bar crop was a plain background —
near-zero texture, fuzzy-matches black boot screens, and would break the
moment the wallpaper fix lands. The bar row is opaque (`background $base`;
sway bar colors have no alpha) → art-agnostic, and its *empty* title center
doubles as the "Welcome not open yet" signal (title text there kills the
match). Source frame recovered from `video.ogv` — states identified by
content, not timestamp (the 21 s recording maps non-linearly to ~6.5 min of
wall time). Run 4 confirmed the timing rule: the save fires at
bar-first-paint, so with the §3.14 fix the saved frame can show bar +
pre-wallpaper bg while the photo appears a moment later — verify wallpaper
via `pgrep swaybg` + a video frame, never via this save.

### CI options
1. **Release ISO download** (sha256 from the release) — cheapest runner;
   pairs naturally with `iso.yml` (suggest triggering on `iso/**` too).
2. **`just build-iso-docker` in CI** — always tests HEAD; ~15 min on a
   decent runner (this host: full build ≈ 15 min), needs privileged docker.
3. Nightly full boot test; PR CI keeps `verify.sh` only.

### Division of labor vs `verify.sh` (keep both)
| Check | `verify.sh` (static, fast) | boot suite (runtime, ~10 min TCG) |
|---|---|---|
| setup marker, commit/hash cross-checks, greetd cfg content, hook removed | ✅ | redundant |
| greetd *actually active*, session Type, getty/greetd race | ❌ | ✅ |
| Welcome autostart + TUI renders | ❌ | ✅ needle |
| wallpaper/desktop renders, bar | ❌ | ✅ needle |
| services (NetworkManager, timesyncd) running | ❌ | ✅ |
| Xorg actually absent / XWayland works | package-level addable | ✅ + process-level |
| boot menu & branding | file presence at best | ✅ needle (caught Arch splash) |
| build package resolution (rot like broadcom-wl) | ❌ | via build; CI trigger fix (§3.8) |

### Gotchas for the implementer
* **Shell traps in `script_run` markers (bit us twice)**: os-autoinst's
  `hashed_string()` builds the exit marker from `md5_base64(cmd)` with
  `/` → `~` substitution — so a given command string reliably gets a marker
  that may **start with `~`** (deterministic: `stty cols 400 rows 100`
  with `timeout=>60` produced marker `~6rU_` on *both* runs — for a cursed
  command it fails every run, ~1/64 of command strings are affected).
  Root's login shell on the instantOS live ISO is **zsh**, which
  *tilde-expands* it (`zsh: no such user or named directory: 6rU_-0-`),
  the marker never prints, the command times out and the test dies. zsh
  additionally rejects words starting with `=` (equals-expansion: my own
  `echo ===x` section marker died the same way in run 1). The main suite
  never sees this because the Arch ISO root shell is **bash**, which leaves
  unmatched `~`/`=` words literal (verified: `bash -c 'echo ~6rU_-0-'` →
  prints it). Fix: after root login, `exec bash --norc` before any
  `script_run` (prompt still ends `# `). Verified live: run 2b's `~6rU_`
  marker echoed back and matched under bash.
* **Root-owned outputs**: os-autoinst writes as root; `run.sh` must
  `sudo rm -rf testresults raid` up front and chown back afterwards (fixed in
  `diag/liveiso/run.sh`; the main suite does its own chown).
* **14 s menu countdown** vs needle assert — assert first, always.
* Welcome covers the desktop — close it before any wallpaper assertion.
* One run per checkout (shared port/state) — `diag` harness is independent of
  the main suite's port 8000 but shares `casedir/needles` read-only.
* `wait_serial` during a screen console reads the **ttyS0 ringbuf** — usable
  for boot-menu sync without needles.
* TCG timings: boot-to-desktop ≈ 2.5 min, full module ≈ 10–15 min; KVM ≈ 10×
  faster (per suite README: 35 min → 4 min for the install suite).

---

## 6. Reproduce

```sh
# build an instantOS ISO from source (privileged docker, ~15 min here)
cd instantOS && just build-iso-docker          # → iso/build/iso/instantos-YYYY.MM.DD-x86_64.iso
iso/verify.sh iso/build/iso/instantos-YYYY.MM.DD-x86_64.iso   # static checks (runs automatically)

# boot it under isotovideo (TCG; ~10–15 min; needles from casedir/needles)
cd instantOS-e2e/diag/liveiso
E2E_ISO_NAME=instantos-2026.09.22-x86_64.iso ./run.sh > run.log 2>&1
# artifacts: testresults/*.png, result-*.json, virtio_console.log, serial0
# (X-less expectations are unconditional — see §4)

# release ISO for comparison
cd instantOS && just download-iso             # or curl from GitHub releases + sha256sum -c
```

---

## 7. Files changed/created (all uncommitted, left for review)

| Path | What |
|---|---|
| `instantOS/iso/releng/packages.x86_64` | −broadcom-wl; −Xorg groups/inputs; +xorg-xwayland (§4); +swaybg (§3.14) |
| `instantOS/iso/overlay/usr/local/bin/instantos-setup` | seed the live user's `appearance.wallpaper_path` (§3.14) |
| `instantOS/iso/overlay/etc/skel/.config/instant/settings.toml` | same wallpaper seed for installed systems (§3.14) |
| `instantOS-e2e/diag/liveiso/{main.pm,tests/liveiso.pm,run.sh}` | prototype live-ISO harness (assert-based after run 1→2 rework; v6 = early `live-bar` capture, no kill step, swaybg assert; sudo-clean/chown fix in `run.sh`) |
| `instantOS-e2e/casedir/needles/iso-bootloader.*` | new needle |
| `instantOS-e2e/casedir/needles/live-welcome.*` | new needle (recropped from run 3 after title-shift failure, §7) |
| `instantOS-e2e/casedir/needles/live-bar.*` | new needle: pre-Welcome bare desktop (bar row only) |
| `instantOS-e2e/isotests.md` | this document |
| `~/e2e-media/instantos-2026.08.24-x86_64.iso(.sha256)` | downloaded release ISO |

Nothing committed or pushed anywhere (suite convention).

---

## 8. Open questions / next steps

1. ✅ Run 2e settled the `liveautostart` root cause (§3.9: `ins 0.14.8` has
   no live block; v0.14.9+ does); ✅ the "wallpaper frame" question resolved
   differently than planned — killing Welcome can't clear its surface
   (§3.13), so the module captures the pre-Welcome gap instead (`live-bar`
   needle created from the run 3b video).
2. ~~Fix the `liveautostart` wiring per the root cause~~ — the fix already
   ships in instantCLI ≥ v0.14.9 (live block in `src/autostart.rs`); no
   product change needed. **Run 3b proved it** (marker + NM green).
3. ✅ Run 3 against the X-less ISO (build B, `ins 0.14.14`): first attempt
   died on the stale `live-welcome` needle
   (title-shift, §7) → needle rebuilt → **run 3b FULL GREEN** (EXIT=0,
   45/47 details ok): X-less asserts, Wayland socket, marker + NM.
4. ✅ **Build C + run 4**: the §3.14 wallpaper fix validated end to end —
   build C ships `swaybg` + both settings seeds; run 4 **FULL GREEN**
   (EXIT=0, 48 details, 46 ok): `pgrep -x swaybg` rc=0 with
   `swaybg -i …/defaultphoto.png -m fill` in the process dump, the photo
   rendered edge-to-edge in `run4-wallpaper-frame.png`, `live-bar` flow
   green.
5. instantwm stale-surface bug (§3.13): fix in the instantWM repo, then add
   a regression assert (kill a fullscreen client → screen must clear).
6. Boot-splash art: replace Arch splash with instantOS art? (recapture
   `iso-bootloader` needle after.)
7. `startx`/Xwrapper fate with Xorg gone (§3.7).
8. Doc/asset fixes: README GDM→greetd, live `/etc/motd`, getty@tty1
   drop-in removal (§3.6), plymouth-on-live (§3.10), greetd `Type=tty`
   session (§3.11), duplicate dunst D-Bus service (§3.12).
9. CI: widen `iso.yml` trigger; decide release-ISO-download vs build-in-CI
   for the boot test.
10. Promote `diag/liveiso` into the main suite as `--iso` mode (§5).
