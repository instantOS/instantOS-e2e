# Verify the installed system.
#
# Sequence: watch tty1 on the VGA console for the installed system's login
# prompt (needle), log in as root on the VGA console (blind typing — the
# colored prompt cannot be text-matched), start a serial getty from that
# session, then run the whole verification suite over the virtio console.
use Mojo::Base 'basetest';
use testapi;

sub run {
    my $profile = get_var('E2E_PROFILE', 'minimal');

    # Encrypted installs boot through two passphrase prompts: GRUB
    # cryptodisk unlock (nothing can be themed there — GRUB has not read any
    # files yet) and the initramfs sd-encrypt prompt (which Plymouth should
    # cover). Blind-type the passphrase with retries; a stray password that
    # lands at the login prompt just fails one login attempt and re-prompts.
    if ($profile eq 'encrypted') {
        for my $i (1 .. 3) {
            sleep 20;
            type_password;
            send_key 'ret';
        }
    }

    # The installed system boots from disk now (the e2e cleaned up and
    # cleanly shut down the live system before resetting).
    assert_screen 'installed-login', 900;

    # Log in as root on the VGA console (root password = user password from
    # the questions file; provided via the PASSWORD var and set_password in
    # main.pm). Assert the Password: prompt before typing so the tty flush
    # cannot eat the password, and assert the shell prompt afterwards (it is
    # colored, so a needle rather than text matching).
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

    # --- verification suite ---------------------------------------------
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

    # Packages the plan promised
    assert_script_run('pacman -Q linux linux-firmware grub networkmanager openssh sudo', 60);

    # --- theming chain (full/encrypted profiles) -------------------------
    # Plymouth runs from the initramfs, so the theme must be embedded in the
    # initramfs IMAGE — a theme only present on the (encrypted) root cannot
    # cover the passphrase prompt. This assert is the regression detector for
    # exactly that. The instantOS theme packages arrive transitively:
    # instantdepend -> plymouth-theme-instantos, instantos -> grub-instantos.
    if ($profile ne 'minimal') {
        assert_script_run('grep -q "^ID=instantos" /etc/os-release', 60);
        assert_script_run('pacman -Q plymouth plymouth-theme-instantos grub-instantos instantos', 60);
        assert_script_run('grep -q "^Theme=instantos" /etc/plymouth/plymouthd.conf', 60);
        assert_script_run('grep -q "^HOOKS=.*systemd" /etc/mkinitcpio.conf', 60);
        assert_script_run('grep -q "^HOOKS=.*plymouth" /etc/mkinitcpio.conf', 60);
        assert_script_run('bsdtar -tf /boot/initramfs-linux.img | grep -q plymouth/themes/instantos', 120);
        assert_script_run('grep -q "^GRUB_THEME=" /etc/default/grub', 60);
        assert_script_run('test -f /usr/share/grub/themes/instantos/theme.txt', 60);
        # On failure dump what grub-mkconfig actually emitted: distinguishes
        # "theme never emitted" from "emitted but asset not loadable"
        # (00_header insmods png but not jpeg — the instantos theme's
        # background is a JPG, so the background silently fails to render).
        assert_script_run('grep -q "instantos" /boot/grub/grub.cfg || { echo "=== /etc/default/grub ==="; cat /etc/default/grub; echo "=== grub.cfg gfx lines ==="; grep -nE "insmod|theme|terminal_output|gfxmode|loadfont" /boot/grub/grub.cfg | head -30; false; }', 60);
    }

    # --- encrypted layout (encrypted profile) ----------------------------
    if ($profile eq 'encrypted') {
        assert_script_run('grep -q "GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub', 60);
        assert_script_run('grep -q "rd.luks" /boot/grub/grub.cfg', 60);
        assert_script_run('grep -q "^HOOKS=.*sd-encrypt" /etc/mkinitcpio.conf', 60);
        assert_script_run('lsblk -no TYPE /dev/vda2 | grep -q crypt', 60);
        # root must come from the mapper (LVM inside LUKS), not the raw device
        assert_script_run('findmnt -n -o SOURCE / | grep -q /dev/mapper/', 60);
    }

    # Network actually works (slirp gateway answers)
    assert_script_run('ping -c1 -W5 10.0.2.2', 120);

    record_info('verify', 'installed-system verification suite passed');
}

1;
