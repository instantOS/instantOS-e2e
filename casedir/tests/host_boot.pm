# Log into a running host and dry-run the minimal plan against its spare disk.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installer_base qw(
    prepare_questions prepare_installer run_dry_run assert_dry_run
    capture_host_state assert_host_unchanged assert_blank_disk
);

# Later modules depend on this stage succeeding.
sub test_flags { return {fatal => 1}; }

sub run {
    my $flow = get_var('E2E_FLOW');
    my $target = get_required_var('E2E_TARGET_DISK');
    select_console 'root-console';
    wait_serial 'login:', 600;
    type_string "root\n";
    wait_serial 'Password:', 60;
    type_password;
    send_key 'ret';
    wait_serial '# ', 180;
    type_string "exec bash --norc\n";
    script_run('stty cols 4096 rows 100');

    script_run('uname -srm; cat /etc/os-release /etc/hostname; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL');
    assert_script_run('test -b /dev/vda1', 30);
    assert_script_run('grep -qx ins-e2e-host /etc/hostname', 30);
    assert_script_run('findmnt -n -o OPTIONS / | grep -qw rw', 60);
    assert_script_run('findmnt -n -o SOURCE / | grep -qx /dev/vda1', 60);
    script_run('ip -br address; ip route; networkctl status --all --no-pager -l', 60);
    # Login and network configuration start independently during boot.
    assert_script_run('/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=120', 180);
    assert_script_run('ping -c 2 -W 5 10.0.2.2', 120);
    assert_script_run('getent hosts archlinux.org', 120);
    prepare_questions();
    prepare_installer();
    capture_host_state('pre', $target);
    assert_blank_disk($target);
    assert_host_unchanged('pre');
    run_dry_run();
    capture_host_state('dryrun', $target);
    assert_blank_disk($target);
    assert_host_unchanged('dryrun');

    if ($flow eq 'host-ubuntu') {
        # The real refusal contract is checked in host_install.pm. See FINDINGS.
        assert_script_run('grep -q "You appear to be running on" /tmp/dryrun.log', 30);
        assert_script_run('! grep -q "invalid configuration" /tmp/dryrun.log', 30,
            fail_message => 'invalid fixture data prevented exercising the Ubuntu refusal contract');
    } else {
        assert_dry_run();
    }
    record_info('dryrun', "$flow: dry-run left host configuration and $target untouched");
}
1;
