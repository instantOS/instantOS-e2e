# Verify an ALREADY INSTALLED disk image (boots it directly, no installer).
use Mojo::Base 'basetest';
use testapi;

sub run {
    assert_screen 'installed-login', 600;

    type_string "root\n";
    assert_screen 'password-prompt', 60;
    type_password;
    send_key 'ret';
    assert_screen 'installed-root-prompt', 180;

    type_string "systemctl start serial-getty\@hvc0\n";

    select_console 'root-console';
    wait_serial 'login:', 300;
    type_string "root\n";
    wait_serial 'Password:', 60;
    type_password;
    send_key 'ret';
    wait_serial '# ', 180;

    assert_script_run('cat /etc/hostname | grep -qx ins-e2e-vm', 60);
    assert_script_run('id tester', 60);
    assert_script_run('systemctl is-system-running | grep -qv failed', 180);
    assert_script_run('test "$(systemctl --failed --no-legend | wc -l)" = 0', 60);
    assert_script_run('systemctl is-active NetworkManager', 60);
    assert_script_run('systemctl is-active sshd', 60);
    assert_script_run('findmnt -n -o FSTYPE / | grep -qx ext4', 60);
    assert_script_run('swapon --show=NAME --noheadings | grep -q .', 60);
    assert_script_run('awk \'$2=="/" && $3=="ext4"\' /etc/fstab | grep -q .', 60);
    assert_script_run('dd if=/dev/vda bs=512 count=1 2>/dev/null | tail -c +385 | head -c 4 | grep -q GRUB', 60);
    assert_script_run('grep -q menuentry /boot/grub/grub.cfg', 60);
    assert_script_run('test -s /boot/grub/grub.cfg', 60);
    assert_script_run('pacman -Q linux linux-firmware grub networkmanager openssh sudo', 60);
    assert_script_run('ping -c1 -W5 10.0.2.2', 120);

    record_info('verify', 'verification suite passed');
}

1;
