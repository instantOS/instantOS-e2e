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

    # Bootloader: GRUB stage 1 in the MBR + generated config with entries
    assert_script_run('dd if=/dev/vda bs=512 count=1 2>/dev/null | tail -c +385 | head -c 4 | grep -q GRUB', 60);
    assert_script_run('grep -q menuentry /boot/grub/grub.cfg', 60);
    assert_script_run('test -s /boot/grub/grub.cfg', 60);

    # Packages the plan promised. The installer installs firmware vendor
    # splits matching the detected hardware instead of the full meta package,
    # so assert the always-present catch-all and — this is a VM with no
    # passthrough GPU/NIC vendors — that the big vendor splits stayed out.
    assert_script_run('pacman -Q linux linux-firmware-other grub networkmanager openssh sudo', 60);
    assert_script_run('! pacman -Q linux-firmware-nvidia linux-firmware-amdgpu', 60);
}

1;
