# WARNING: `mount --rbind` + `rm -rf` will destroy the host

**Read this before writing or running any script that mounts host paths and
deletes directories.**

This is not theoretical. On **2026-09-26** a script in this project's scratch
area deleted every device node and most of `/run` on the development host. The
machine had to be rebooted to recover. The mechanism is a two-line footgun
that is easy to write by accident and has no obvious warning attached to it.

---

## The one rule

> **`rm -rf` descends *through* mount points.**
>
> Never bind-mount a host directory and then recursively delete an ancestor of
> that mount point.

`rm -rf` is not filesystem-aware. If `$DIR/dev` is a bind mount of the host's
`/dev`, then `rm -rf "$DIR"` will happily `unlink` every device node on the
machine, because as far as `rm` is concerned it is just a directory full of
files it was told to delete.

## The exact sequence that did it

From `e2e-work/bootstrap-proto.sh` (a prototype, since hardened):

```bash
# Step 3 of run N: alias the host's real filesystems into the scratch dir
for m in proc sys dev run; do mount --rbind "/$m" "$B/$m"; done

# ... script dies partway through (set -e, Ctrl-C, a failed chroot) ...

# Step 1 of run N+1: "clean up my scratch dir"
rm -rf "$B"
```

Two independent bugs had to line up, and both are ordinary:

1. **The mounts were never released.** Cleanup was written inline at the *end*
   of the script, so any early exit leaked the mounts. There was no `trap`.
2. **The scratch dir was reused across runs**, so the *next* invocation began
   with `rm -rf "$B"` — through the still-live mounts from the previous run.

The result, confirmed on the host:

| path | `st_dev` | |
| --- | --- | --- |
| host `/dev` | 5 | |
| `e2e-work/boot/dev` | 5 | same superblock — a live alias |
| host `/run` | 25 | |
| `e2e-work/boot/run` | 25 | same superblock — a live alias |
| host `/sys` | 22 | |
| `e2e-work/boot/sys` | 22 | same superblock — a live alias |

`/sys` survived only because sysfs refuses to be unlinked. `/dev` and `/run`
are ordinary writable tmpfs-backed trees, so they did not.

## Why the symptom looked like "systemd is down"

This is worth internalising, because it sends you looking in the wrong place:

- `rm` deleted every entry under the host's `/dev`.
- `systemd-udevd` died (or was never able to recreate nodes) and `/run/udev`
  was gone, so **nothing repopulated `/dev`**. Only a reboot brings it back.
- `rm` also deleted `/run/dbus`, so `systemctl` had no system bus to connect
  to. `systemctl is-system-running` reported **`offline`** and every `systemctl`
  command failed — while PID 1 was alive and still scheduling units normally.
- `/dev/null` was recreated by the next cron job as a **regular file**, because
  `> /dev/null` on a missing path just makes a file. Every non-root process
  doing `2>/dev/null` then failed with `permission denied`.
- `git` refused to run at all: `fatal: could not open '/dev/null'`.

So: **`offline` from `systemctl` on a machine whose journal is still being
written means suspect `/run`, not systemd.** Check `ls /dev` first.

## The dangerous patterns

Grep for these before running anything as root:

```sh
# scope the grep to the repos: ~/stuff also holds a 370G docker-data tree and
# will crawl for minutes
cd ~/stuff
grep -rn --include='*.sh' -- '--rbind\|-o bind\|mount .* /dev\|mount .* /run' \
  instantCLI instantOS instantOS-e2e instantMENU instantWM grub-instantos packages
grep -rn --include='*.sh' 'rm -rf' .   # then check each hit for a mountpoint above it
```

Specifically, never:

- `mount --rbind /dev "$DIR/dev"` (or `/run`, `/sys`, `/proc`) in a script that
  also does `rm -rf "$DIR"` or any ancestor of `"$DIR"`.
- Put cleanup at the end of the script. Use a `trap`.
- Reuse a fixed scratch directory across runs *and* start by `rm -rf`-ing it.
  That combination turns any leaked mount into a delayed destructive weapon.
- Trust `rm -rf` to stay on one filesystem. It will not.

## The safe pattern

Four independent layers. All four matter; the first is the one that actually
protects the host, the rest stop it being one `rm -rf` away from happening
again.

### 1. Run the mounts in a private mount namespace

```bash
# One-shot re-exec. `unshare --mount` also makes propagation private, so
# nothing mounted below is ever published back to the host. Leaked mounts
# die with the process.
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
if [ -z "${MY_MNTNS:-}" ]; then
    MY_MNTNS=1 exec unshare --mount --propagation private "$(readlink -f "$0")" "$@"
fi
```

This is the structural fix. Inside a namespace, even a leaked alias of the
host's `/dev` is harmless, because unmounting or ignoring it cannot affect the
host's own mount table.

### 2. Trap the cleanup, and track every mount

```bash
MOUNTS=()
track() { MOUNTS+=("$1"); }

release_mounts() {                     # reverse order: nested mounts first
    local i n=${#MOUNTS[@]}
    i=$((n - 1 ))
    while [ "$i" -ge 0 ]; do
        mountpoint -q "${MOUNTS[$i]}" && umount -R -- "${MOUNTS[$i]}" || true
        i=$((i - 1 ))
    done
    MOUNTS=()
}

trap 'release_mounts' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

### 3. Refuse to delete through a live mount

```bash
mounts_under() { awk -v d="${1%/}/" 'index($2, d) == 1 { print $2 }' /proc/self/mounts; }

safe_rm_rf() {
    case "$1" in "$W"/*) : ;; *) die "refusing to touch '$1': outside $W" ;; esac
    while read -r m; do
        [ -n "$m" ] || continue
        # Safe *only* because we are inside our own namespace: this drops our
        # view of the alias and leaves the host's /dev untouched.
        umount -R -- "$m" || true
    done < <(mounts_under "$1")
    [ -z "$(mounts_under "$1")" ] ||
        die "refusing to rm -rf '$1': a mount is live underneath it"
    rm -rf -- "$1"
}
```

`/proc/self/mounts` is namespace-local, so this answers "what is mounted under
this path *as I see it*". The final `[ -z ... ]` re-check is the backstop that
still holds when the detach could not happen.

### 4. Scope every delete

Only ever delete paths under a known work directory, and assert it. A stray
empty variable in `rm -rf "$PREFIX/$THING"` is the same class of bug.

## Prefer not to rbind the host at all

The safest bind mount is one that does not alias host state. Inside a namespace
you can usually get away with a fresh instance instead:

```sh
mount -t tmpfs tmpfs "$DIR/run"                  # empty, private, throwaway
```

A fresh `devtmpfs` instance is private too, whereas `mount --rbind /dev` is a
window onto the host's *actual* devices. Prefer `systemd-nspawn` when you want
a real container; it builds all of this correctly for you.

## Checking for and cleaning up leaked mounts

```sh
# everything currently mounted, deepest last
findmnt -rn -o TARGET

# is this path a mountpoint, or does it contain mountpoints?
mountpoint "$DIR"
findmnt -rn -o TARGET | grep -F "$DIR/"
```

### Clean up leaked mounts — in this order

> **Unmount first, then `rm -rf`. Doing it the other way round re-runs the
> original bug.**

```sh
# 1. detach the aliases (repeat per leaked mountpoint)
sudo umount -R /home/benjamin/stuff/e2e-work/boot/sys
sudo umount -R /home/benjamin/stuff/e2e-work/boot/dev
sudo umount -R /home/benjamin/stuff/e2e-work/boot/run

# 2. only once nothing under it is mounted, remove the directory
findmnt -rn -o TARGET | grep -F "/home/benjamin/stuff/e2e-work/boot/" || echo "clear"
sudo rm -rf /home/benjamin/stuff/e2e-work/boot
```

A reboot also clears leaked mounts, because the mount table is rebuilt at
boot. That is the cheapest recovery when in doubt.

## Status of the scripts in this project

| script | mounts on the host? | verdict |
| --- | --- | --- |
| `e2e-work/bootstrap-proto.sh` | yes, was `--rbind` | **was the bug**; now hardened with all four layers above |
| `tools/mkhost-arch.sh` | no | safe — builds the rootfs inside Docker, `docker export`s it out |
| `tools/mkhost-ubuntu.sh` | no | safe — same |
| `run.sh` | no | safe — only `docker run -v` |
| `instantCLI/tests/*.sh` | no | safe — no `mount` at all |

As of this writing, `--rbind` matches exactly one file across the project
repos: `e2e-work/bootstrap-proto.sh`. Re-run the grep above before trusting
this table.

## Before running any root + mount script

- [ ] Does it create a private mount namespace, or is every mount inside
      something that already isolates (Docker, nspawn, a VM)?
- [ ] Does it `rbind` any host directory, and if so what deletes an ancestor of
      that mount?
- [ ] Is cleanup on a `trap`, not on the last line?
- [ ] Does the script reuse a directory it also `rm -rf`s?
- [ ] If it dies mid-run, what is left mounted, and what would the *next* run
      do about it?
- [ ] Have you checked `findmnt -rn -o TARGET` for leftovers from last time?

## Regression test

`tools/test-mount-guards.sh` covers the guards, and runs in two tiers:

```sh
./tools/test-mount-guards.sh                    # tier 1: logic, no privileges
sudo ./tools/test-mount-guards.sh <script>       # + tier 2: a real bind mount
```

It extracts the guard block from the script by marker and sources it, so it
tests the shipped code rather than a copy. Tier 1 drives the guard logic
against a synthetic mount table; tier 2 bind-mounts a directory with a canary
file on the far side and asserts that `safe_rm_rf` refuses and the canary
survives — i.e. the exact behaviour whose absence destroyed the host. Tier 2
skips itself when it cannot mount.

The script under test lives outside this repo, so pass its path (or set
`E2E_BOOTSTRAP_PROTO`); otherwise the test skips with a message.

## One more thing

`e2e-work/` is **not** under version control. Scripts that run as root and
mount things do not belong only there — a mistake like this is invisible in a
scratch directory, unreviewable, and unrecoverable from history. Keep
destructive prototypes in this repository where they get read and reviewed.
