# Running-Arch installs must preserve their host; Ubuntu must refuse before
# disk writes. The Ubuntu contract is deliberately red on current instantCLI.
# Keep these safety assertions: docs/FINDINGS.md records the product baseline.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installer_base qw(
    run_install assert_install_success capture_host_state assert_host_unchanged
    assert_blank_disk shutdown_guest
);

# Later modules depend on this stage succeeding.
sub test_flags { return {fatal => 1}; }

sub run {
    my $flow = get_var('E2E_FLOW');
    my $target = get_required_var('E2E_TARGET_DISK');
    run_install();
    # Capture and upload all evidence before an assertion can stop the module.
    capture_host_state('post', $target);
    assert_host_unchanged('post');
    if ($flow eq 'host-ubuntu') {
        assert_ubuntu_refused($target);
        assert_script_run('sync', 120);
        power('acpi');
        check_shutdown(600);
    } else {
        assert_arch_installed($target);
        # Leave the host off. run.sh boots the extracted target in a new VM.
        shutdown_guest(0, 0);
    }
    record_info('install', "$flow contract passed for $target");
}

sub assert_arch_installed {
    my ($target) = @_;

    assert_install_success();

    assert_script_run('findmnt -n -o TARGET /mnt | grep -qx /mnt', 60,
        fail_message => '/mnt is not a mount point after the install');
    assert_script_run('findmnt -n -o SOURCE /mnt | grep -q "^' . $target . '"', 60,
        fail_message => "/mnt is not backed by $target — the install went to the wrong disk");
    assert_script_run('ls -A /mnt | grep -qx etc', 60,
        fail_message => '/mnt has no /etc — the target root filesystem is empty');
    assert_script_run('! test -e /mnt/usr/bin/ins-install', 60,
        fail_message => 'the chroot hand-off binary is still in the target: the installer did not '
            . 'run its finish-time cleanup, so this did not complete as a full installation');

}

sub assert_ubuntu_refused {
    my ($target) = @_;

    assert_script_run('grep -Eq "^INSTALL_RC=[1-9][0-9]*$" /tmp/install.log', 30,
        fail_message => 'the installer did not report failure on an unsupported host');
    assert_script_run('grep -q "You appear to be running on" /tmp/install.log', 30,
        fail_message => 'no foreign-distro warning: the installer did not notice it is on Ubuntu');

    assert_script_run('! grep -q "Successfully installed packages" /tmp/install.log', 30,
        fail_message => 'the installer claims it installed packages on Ubuntu');

    assert_blank_disk($target);
    assert_script_run('! findmnt /mnt >/dev/null 2>&1', 30,
        fail_message => '/mnt is still mounted after a refused install');

    assert_script_run('! test -e /etc/pacman.d/mirrorlist', 30,
        fail_message => 'the installer created /etc/pacman.d/mirrorlist on an Ubuntu host');

}

1;
