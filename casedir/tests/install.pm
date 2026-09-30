# Install from live media and reboot into the target.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installer_base qw(run_install assert_install_success shutdown_guest);

# Later modules depend on this stage succeeding.
sub test_flags { return {fatal => 1}; }

sub run {
    run_install();
    assert_install_success();
    if (get_var('E2E_FLOW', 'live') eq 'offline') {
        assert_script_run('grep -q "Bound the offline bundle into the target" /tmp/install.log', 60);
        assert_script_run('grep -q "Copied the offline dotfiles snapshot" /tmp/install.log', 60);
        assert_script_run('grep -q "Removed offline bundle references" /tmp/install.log', 60);
    }
    # Unmount and shut down before reset: QEMU ignores flushes in this harness.
    shutdown_guest(1, 1);
    select_console 'user-console';
}
1;
