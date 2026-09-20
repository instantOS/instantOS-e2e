# Verify an ALREADY INSTALLED disk image (boots it directly, no installer).
#
# Reuses the login dance and core assertion suite from
# casedir/tests/installed_base.pm (mounted read-only at /casedir — see
# diag/README.md) so this harness cannot drift from the main suite; it only
# adds the network check.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installed_base qw(login_installed_system assert_core_suite);

sub run {
    login_installed_system(600);

    assert_core_suite();

    # Network actually works (slirp gateway answers)
    assert_script_run('ping -c1 -W5 10.0.2.2', 120);

    record_info('verify', 'verification suite passed');
}

1;
