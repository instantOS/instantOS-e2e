#!/usr/bin/env bash
# Guest-only: collect protected host configuration and diagnostic disk state.
set -euo pipefail
phase=$1 target=$2
case "$phase" in pre|dryrun|post) ;; *) exit 2 ;; esac
{
    for file in /etc/pacman.conf /etc/pacman.d/mirrorlist /etc/fstab /etc/hostname /etc/hosts \
        /etc/passwd /etc/shadow /etc/apt/sources.list /etc/apt/sources.list.d/* \
        /etc/systemd/network/*.network; do
        if [ -f "$file" ]; then sha256sum "$file"; else printf 'missing  %s\n' "$file"; fi
    done
} | sort -k2 > "/tmp/$phase-host-config.sha"
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
