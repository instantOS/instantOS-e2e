# Run the shared complete installed-system verification suite.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installed_base qw(verify_installed_system);
sub run {
    verify_installed_system();
    if (get_var('E2E_PROFILE', 'minimal') eq 'encrypted') {
        record_info('reboot', 'verify encrypted boot again after a normal restart');
        script_run('systemctl reboot', 0);
        verify_installed_system();
    }
}
1;
