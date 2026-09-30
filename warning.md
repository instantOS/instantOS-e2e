# Host mount cleanup incident

On 2026-09-26, an unversioned `e2e-work/bootstrap-proto.sh` deleted the host's
`/dev` nodes and much of `/run`. It recursively bind-mounted host directories
into a scratch tree, exited without releasing them, and the next invocation
ran `rm -rf` on that tree. The machine needed a reboot.

`rm -rf` descends through mount points. A bind mount aliases the underlying
files: deleting through that alias deletes the host's data too. A private
mount namespace isolates the mount table and propagation; it does **not**
isolate writes or deletions to bind-mounted host files. Never treat a namespace
alone as protection against this failure.

The suite's host-image builder avoids that mechanism entirely: it installs
inside Docker, exports the rootfs and packs it with `mkfs.ext4 -d`. It creates
no host mounts or loop devices. Keep that property when extending it.

If developing a tool that genuinely needs mounts:

- Keep its implementation and tests under version control.
- Prefer a container or VM, and avoid writable aliases of host state.
- Use a private mount namespace to contain mounts and propagation.
- Track mounts and release them in reverse order from an exit trap.
- Before recursive deletion, reject the path if it is a mount point or
  contains live mounts. If unmounting fails, leave the tree for inspection.
- Scope deletion to a known work directory and check resolved paths.
- Use a fresh scratch directory so a leaked mount cannot become the next
  invocation's cleanup target.

For an existing suspect tree, inspect the mount table first:

```sh
findmnt -rn -o TARGET
mountpoint /path/to/scratch
```

Unmount its aliases before deleting anything. If the host's `/dev` or `/run`
has already been damaged, rebooting restores the runtime filesystems.
Symptoms from the incident included missing `/dev/null`, non-root commands
failing with permission errors, missing D-Bus sockets and `systemctl` reporting
`offline` even though PID 1 was still running.

The prototype and its marker-extracted guard test were outside the reproducible
suite boundary. The suite no longer ships a test that silently skips unless
that external script exists. Any future mount implementation must bring its
actual code and tests into the repository together.
