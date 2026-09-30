# Boot the install medium, prepare the installer/config, validate the full plan.
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installer_base qw(
    login_instant_iso assert_offline_bundle prepare_questions prepare_installer
    run_dry_run assert_dry_run
);

# Later modules depend on this stage succeeding.
sub test_flags { return {fatal => 1}; }

sub run {
    my $offline = get_var('E2E_FLOW', 'live') eq 'offline';
    assert_screen($offline ? 'iso-bootloader' : 'bootloader', 180);
    send_key 'tab';
    type_string($offline ? ' console=hvc0 console=ttyS0' : ' console=hvc0');
    send_key 'ret';
    if ($offline) {
        login_instant_iso();
        assert_offline_bundle();
    } else {
        assert_screen 'archiso-prompt', 900;
        select_console 'root-console';
        wait_serial 'login:', 300;
        type_string "root\n";
        wait_serial '# ', 300;
        # Arch's root shell is zsh; it expands the backend's ~ exit markers.
        type_string "exec bash --norc\n";
        script_run('stty cols 4096 rows 100');
    }
    prepare_questions();
    prepare_installer();
    run_dry_run();
    assert_dry_run();
}
1;
