use Mojo::Base -strict;
use testapi;
use autotest;
testapi::set_password(get_var('PASSWORD', ''));
autotest::loadtest 'tests/bootcap.pm';
1;
