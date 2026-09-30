# Run the shared complete installed-system verification suite.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installed_base qw(verify_installed_system);
sub run { verify_installed_system(); }
1;
