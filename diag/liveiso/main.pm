use Mojo::Base -strict;
use testapi;
use autotest;

testapi::set_password(get_var('PASSWORD', ''));

# Same console declarations as the main suite: virtio serial for scripted
# interaction, tty1 to watch the graphical session.
$testapi::distri->add_console('root-console', 'virtio-terminal');
$testapi::distri->add_console('user-console', 'tty-console', {tty => 1});

autotest::loadtest 'tests/liveiso.pm';

1;
