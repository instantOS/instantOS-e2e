# Installed-system login and assertions shared by the main and diagnostic
# harnesses. Callers load this through /tests/tests or /casedir/tests.
package installed_base;
use Mojo::Base -strict;
use Exporter 'import';
use testapi;

our @EXPORT_OK = qw(unlock_encrypted_system login_installed_system assert_core_suite verify_installed_system);

# GRUB decryption can be slow even with KVM. Wait for each prompt so subsequent
# password characters cannot be queued into the boot menu while GRUB decrypts.
sub unlock_encrypted_system {
    my ($timeout) = @_;
    $timeout //= 900;
    my $password = get_required_var('ENCRYPTION_PASSWORD');
    assert_screen 'grub-unlock', $timeout;
    type_password($password);
    send_key 'ret';
    assert_screen 'initramfs-unlock', $timeout;
    type_password($password);
    send_key 'ret';
}

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
    script_run('stty cols 4096 rows 100');
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
    # Raw absolute paths make the ancestry check an exact device comparison.
    assert_script_run(
        "findmnt -n -o SOURCE / | sed 's/\\[.*//' | xargs -r lsblk -snrpo NAME | grep -Fxq '$disk'",
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
    for my $package (qw(linux-firmware-nvidia linux-firmware-amdgpu)) {
        assert_script_run("! pacman -Q $package", 60);
    }
    # This VM shape has no bluetooth adapter; the installer must not pull the
    # bluetooth stack (blueman is an optdepends of instantdepend now and is
    # added by the installer only when /sys/class/bluetooth shows an adapter).
    for my $package (qw(blueman bluez)) {
        assert_script_run("! pacman -Q $package", 60);
    }

    # Offline installs (E2E_FLOW=offline): the finish-time cleanup must have
    # removed every bundle reference, the target must keep a working
    # network mirrorlist, and the [instant] repo must be configured with
    # its unsigned-packages SigLevel (Phase 3 acceptance, offlineiso.md).
    if (get_var('E2E_FLOW', 'live') eq 'offline') {
        assert_script_run('! grep -ri "file://" /etc/pacman.conf /etc/pacman.d/', 60,
            fail_message => 'file:// bundle references survived the offline cleanup');
        assert_script_run('grep -q "^Server" /etc/pacman.d/mirrorlist', 60,
            fail_message => 'no network server left in the target mirrorlist');
        assert_script_run('grep -q "^\[instant\]" /etc/pacman.conf', 60);
        assert_script_run('grep -A2 "^\[instant\]" /etc/pacman.conf | grep -q "Optional TrustAll"', 60);
    }
}


sub verify_installed_system {
    my ($login_timeout) = @_;
    my $profile = get_var('E2E_PROFILE', 'minimal');
    # Which disk the install targeted. /dev/vda for the live-ISO flow and for
    # the diag/verifydisk harness; /dev/vdb for the --host-* flows, where the
    # install lands on the second disk of the machine it ran on.
    my $disk = get_var('E2E_TARGET_DISK', '/dev/vda');

    unlock_encrypted_system($login_timeout) if $profile eq 'encrypted';

    login_installed_system($login_timeout);

    assert_core_suite();

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
        # lsinitcpio reads both the early microcode and compressed main archive.
        assert_script_run('lsinitcpio /boot/initramfs-linux.img | grep -q "plymouth/themes/instantos"', 120);
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
        assert_script_run("lsblk -no TYPE $disk" . '2 | grep -q crypt', 60);
        # root must come from the mapper (LVM inside LUKS), not the raw device
        assert_script_run('findmnt -n -o SOURCE / | grep -q /dev/mapper/', 60);
    }

    # Network actually works (slirp gateway answers). The offline scenario
    # runs with OFFLINE_SUT=1 — there is no gateway, and the absence of any
    # file:// bundle reference (asserted in installed_base) is the
    # network-related proof.
    unless (get_var('E2E_FLOW', 'live') eq 'offline') {
        assert_script_run('ping -c1 -W5 10.0.2.2', 120);
    }

    record_info('verify', 'installed-system verification suite passed');
}

1;
