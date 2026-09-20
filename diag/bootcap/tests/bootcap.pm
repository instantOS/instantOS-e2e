# CAPTURE: boot the installed disk, log in on tty1, screenshot the prompt.
use Mojo::Base 'basetest';
use testapi;

sub run {
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
