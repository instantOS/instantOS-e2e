# CAPTURE: boot the installed disk, log in on tty1, screenshot the prompt.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installed_base qw(unlock_encrypted_system);

sub run {
    unlock_encrypted_system() if get_var('E2E_PROFILE', 'minimal') eq 'encrypted';
    assert_screen 'installed-login', 600;
    type_string "root\n";
    assert_screen 'password-prompt', 60;
    type_password;
    send_key 'ret';
    sleep 25;
    save_screenshot;
    sleep 10;
    save_screenshot;
}

1;
