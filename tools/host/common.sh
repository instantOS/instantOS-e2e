# Shared guest setup, sourced after the distro installs its prerequisites.
systemd-machine-id-setup
test -s /etc/machine-id
# Docker mounts its own hostname/hosts files and excludes them from export.
# Stage the intended guest identity as ordinary files for the image assembler.
mkdir -p /e2econfig
printf 'ins-e2e-host\n' > /e2econfig/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tins-e2e-host\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /e2econfig/hosts
printf 'root:%s\n' "$E2E_HOST_PASSWORD" | chpasswd
systemctl --root=/ enable serial-getty@ttyS0.service serial-getty@hvc0.service

# Dedicated test hosts use DHCP on Ethernet, independent of interface naming.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-e2e.network <<'NET'
[Match]
Type=ether

[Network]
DHCP=yes
NET
systemctl --root=/ enable systemd-networkd.service systemd-resolved.service
# Docker bind-mounts resolv.conf. Write the guest's stub address in place;
# docker export excludes mount contents, so the builder also fixes the export.
printf 'nameserver 127.0.0.53\noptions edns0\n' > /etc/resolv.conf
printf 'LABEL=%s / ext4 defaults 0 1\n' "$E2E_HOST_LABEL" > /etc/fstab
ln -sf /proc/self/mounts /etc/mtab
