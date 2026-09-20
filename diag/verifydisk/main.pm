use Mojo::Base -strict;
use testapi;
use autotest;
testapi::set_password(get_var('PASSWORD', ''));
$testapi::distri->add_console('root-console', 'virtio-terminal');
$testapi::distri->add_console('user-console', 'tty-console', {tty => 1});
autotest::loadtest 'tests/verifydisk.pm';
1;
