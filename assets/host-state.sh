#!/usr/bin/env bash
# Guest-only: collect protected host configuration and diagnostic disk state.
set -euo pipefail

snapshot_entry() {
    local path=$2 file="$1$2" metadata digest
    if [ -L "$file" ]; then
        printf 'symlink  %s -> %s\n' "$path" "$(readlink "$file")"
        printf 'resolved  %s -> %s\n' "$path" "$(readlink -m "$file")"
    elif [ -d "$file" ]; then
        printf 'directory  %s\n' "$path"
    elif [ ! -e "$file" ]; then
        printf 'missing  %s\n' "$path"
        return
    fi
    # Exclude timestamps: reads and normal service activity can change them.
    metadata=$(stat -c '%a:%u:%g:%F' -- "$file") || return
    printf 'metadata  %s  %s\n' "$metadata" "$path"
    if [ -f "$file" ]; then
        digest=$(sha256sum "$file") || return
        printf 'content  %s  %s\n' "${digest%% *}" "$path"
    fi
}

snapshot_host_config() {
    local root=${1:-} path file
    for path in /etc/pacman.conf /etc/apt/sources.list /etc/fstab /etc/hostname \
        /etc/hosts /etc/passwd /etc/shadow /etc/group /etc/gshadow \
        /etc/subuid /etc/subgid /etc/vconsole.conf /etc/locale.conf /etc/locale.gen \
        /etc/localtime /etc/mkinitcpio.conf /etc/default/grub /etc/crypttab /etc/sudoers; do
        snapshot_entry "$root" "$path"
    done
    # Inventory pacman.d itself, but keyring runtime contents are outside the
    # configuration contract. Hooks and other configuration trees are recursive.
    snapshot_entry "$root" /etc/pacman.d
    if [ -d "$root/etc/pacman.d" ]; then
        while IFS= read -r -d '' file; do
            snapshot_entry "$root" "${file#"$root"}"
        done < <(find "$root/etc/pacman.d" -mindepth 1 -maxdepth 1 -print0)
    fi
    for path in /etc/pacman.d/hooks /etc/apt/sources.list.d /etc/systemd/network \
        /etc/sudoers.d /etc/instant /var/log/instantos; do
        snapshot_entry "$root" "$path"
        if [ -d "$root$path" ]; then
            while IFS= read -r -d '' file; do
                snapshot_entry "$root" "${file#"$root"}"
            done < <(find -H "$root$path" -mindepth 1 -print0)
        fi
    done
}

# Sourcing exposes the collector for tests against an isolated fixture root.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then return; fi
phase=$1 target=$2
case "$phase" in pre|dryrun|post) ;; *) exit 2 ;; esac
snapshot_host_config | LC_ALL=C sort > "/tmp/$phase-host-config.sha"
{
    cat "/tmp/$phase-host-config.sha"
    ls -la /etc/instant /var/log/instantos 2>&1 || true
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$target"
    sfdisk -d "$target" 2>&1 || true
    blkid "$target"* 2>&1 || true
    findmnt /mnt || true
    swapon --show
} > "/tmp/$phase-host-state.txt"
cat "/tmp/$phase-host-state.txt"
