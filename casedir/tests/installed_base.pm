# Shared helpers for verifying an already-installed system. Used by
# casedir/tests/verify.pm (main suite) and
# diag/verifydisk/tests/verifydisk.pm (offline disk harness). Keeping the
# login dance and the assertion suite in one place stops them from drifting
# apart between the two callers — which is exactly how a stale
# `linux-firmware` assert survived in one copy after the installer switched
# to firmware vendor splits.
#
# Where to find this module: the main suite mounts casedir/ at /tests
# (run.sh), the diag harnesses mount it read-only at /casedir (see
# diag/README.md) — hence the two-element `use lib` in the callers.
package installed_base;
use Mojo::Base -strict;
use Exporter 'import';
use testapi;

our @EXPORT_OK = qw(login_installed_system assert_core_suite);

# Log in as root on the VGA console and open a root shell on the virtio
# console for scripted interaction. Works identically right after the
# installer's reboot (verify.pm) and on a copied-out disk image
# (verifydisk.pm): the root password is the user password from the questions
# file, provided via the PASSWORD var and set_password in main.pm. Assert
# the Password: prompt before typing so the tty flush cannot eat the
# password, and assert the shell prompt afterwards (it is colored, so a
# needle rather than text matching).
sub login_installed_system {
    my ($login_timeout) = @_;
    $login_timeout //= 900;

    assert_screen 'installed-login', $login_timeout;

    type_string "root\n";
    assert_screen 'password-prompt', 60;
    type_password;
    send_key 'ret';
    assert_screen 'installed-root-prompt', 180;

    # Bring up a getty on the virtio console so the rest of the checks can
    # run over serial (text matching, no more needles).
    type_string "systemctl start serial-getty\@hvc0\n";

    select_console 'root-console';
    # The freshly started serial getty asks for credentials like any other.
    wait_serial 'login:', 300;
    type_string "root\n";
    wait_serial 'Password:', 60;
    type_password;
    send_key 'ret';
    wait_serial '# ', 180;
}

# Assertion suite every installed system must pass: boot identity, systemd
# health, filesystem/swap layout, bootloader and the promised package set.
sub assert_core_suite {
    # Which disk the installed system lives on. Defaults to /dev/vda because
    # that is what the live-ISO flow boots, and what the second verification
    # stage sees: it boots the extracted target on its own, so the disk that
    # was /dev/vdb during the install is /dev/vda there (run.sh passes
    # E2E_TARGET_DISK explicitly for that reason).
    my $disk = get_var('E2E_TARGET_DISK', '/dev/vda');

    # Boot identity
    assert_script_run('cat /etc/hostname | grep -qx ins-e2e-vm', 60);
    assert_script_run('id tester', 60);

    # systemd healthy: nothing in failed state, key services active
    assert_script_run('systemctl is-system-running | grep -qv failed', 180);
    assert_script_run('test "$(systemctl --failed --no-legend | wc -l)" = 0', 60);
    assert_script_run('systemctl is-active NetworkManager', 60);
    assert_script_run('systemctl is-active sshd', 60);

    # Filesystem + swap
    assert_script_run('findmnt -n -o FSTYPE / | grep -qx ext4', 60);
    assert_script_run('swapon --show=NAME --noheadings | grep -q .', 60);
    # fstab columns: <file system> <dir> <type> <options>
    assert_script_run('awk \'$2=="/" && $3=="ext4"\' /etc/fstab | grep -q .', 60);
    # The root really is on the disk we installed to. Without this an install
    # that silently landed on the wrong device would still pass every other
    # check in this suite.
    #
    # Resolved through the device stack rather than string-matched: an
    # encrypted install puts / on a LUKS mapper over an LVM volume, so SOURCE
    # is /dev/mapper/... and a `^$disk` match can never succeed. `lsblk -s`
    # walks parents, so this asks the only question that matters — is $disk in
    # the root filesystem's ancestry? — for a plain, an LUKS and an LVM root
    # alike. The btrfs subvolume suffix findmnt appends is stripped first.
    #
    # `-p` (absolute paths) plus a suffix-anchored match, rather than `-r`
    # (raw) plus an exact match: lsblk prefixes parent devices with box-drawing
    # characters unless -r is given, and -r is the flag most likely to change
    # under us. Anchoring on "/<name>$" is correct either way.
    assert_script_run(
        "findmnt -n -o SOURCE / | sed 's/\\[.*//' | xargs -r lsblk -snpo NAME | grep -q '$disk\$'",
        60,
        fail_message => "the running root filesystem is not on $disk"
    );

    # Bootloader: GRUB stage 1 in the MBR + generated config with entries
    assert_script_run("dd if=$disk bs=512 count=1 2>/dev/null | tail -c +385 | head -c 4 | grep -q GRUB", 60);
    assert_script_run('grep -q menuentry /boot/grub/grub.cfg', 60);
    assert_script_run('test -s /boot/grub/grub.cfg', 60);

    # Packages the plan promised. The installer installs firmware vendor
    # splits matching the detected hardware instead of the full meta package,
    # so assert the always-present catch-all and — this is a VM with no
    # passthrough GPU/NIC vendors — that the big vendor splits stayed out.
    assert_script_run('pacman -Q linux linux-firmware-other grub networkmanager openssh sudo', 60);
    assert_script_run('! pacman -Q linux-firmware-nvidia linux-firmware-amdgpu', 60);
    # This VM shape has no bluetooth adapter; the installer must not pull the
    # bluetooth stack (blueman is an optdepends of instantdepend now and is
    # added by the installer only when /sys/class/bluetooth shows an adapter).
    assert_script_run('! pacman -Q blueman bluez', 60);

    # Offline installs (E2E_OFFLINE=1): the finish-time cleanup must have
    # removed every bundle reference, the target must keep a working
    # network mirrorlist, and the [instant] repo must be configured with
    # its unsigned-packages SigLevel (Phase 3 acceptance, offlineiso.md).
    if (get_var('E2E_OFFLINE')) {
        assert_script_run('! grep -ri "file://" /etc/pacman.conf /etc/pacman.d/', 60,
            fail_message => 'file:// bundle references survived the offline cleanup');
        assert_script_run('grep -q "^Server" /etc/pacman.d/mirrorlist', 60,
            fail_message => 'no network server left in the target mirrorlist');
        assert_script_run('grep -q "^\[instant\]" /etc/pacman.conf', 60);
        assert_script_run('grep -A2 "^\[instant\]" /etc/pacman.conf | grep -q "Optional TrustAll"', 60);
    }
}

1;
