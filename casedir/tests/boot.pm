# Boot the Arch ISO, add a serial console, inject the `ins` binary from the
# host and run the installer's non-interactive path (dry-run first).
use Mojo::Base 'basetest';
use testapi;
use MIME::Base64 'encode_base64';

sub run {
    # Wait for the syslinux bootloader menu of the Arch ISO (it auto-boots
    # after 10 seconds; Enter boots immediately).
    assert_screen 'bootloader', 120;

    # Add the virtio console (hvc0) to the kernel cmdline so the test can
    # drive the VM through script_run/assert_script_run (text matching)
    # instead of needles for every command.
    send_key 'tab';
    type_string ' console=hvc0';
    send_key 'ret';

    # The VGA console still comes up (autologin as root on tty1).
    assert_screen 'archiso-prompt', 900;

    # Switch to the serial console for scripted interaction. The live ISO
    # spawns a getty on hvc0 via systemd-getty-generator (console=hvc0).
    select_console 'root-console';
    wait_serial 'login:', 300;
    type_string "root\n";

    # The prompt is colored, so "root@archiso" never appears contiguously in
    # the raw stream; match the plain "# " prompt instead.
    wait_serial '# ', 300;

    # Widen the terminal: long typed commands would wrap at the 80-column
    # default and bash's line redraws (ESC[K) would break script_run's echo
    # confirmation.
    script_run('stty cols 400 rows 100');

    my $profile = get_var('E2E_PROFILE', 'minimal');
    my $is_release = get_var('E2E_RELEASE');
    my $ins_bin;

    if ($is_release) {
        # Release mode: inject the ~1 KB questions file directly over serial via
        # base64 heredoc, eliminating the need for a local HTTP server on port 8000.
        my $qfile = "/tests/assets/questions-$profile.toml";
        open my $fh, '<', $qfile or die "Cannot open $qfile: $!";
        my $raw_toml = do { local $/; <$fh> };
        close $fh;
        my $b64_toml = encode_base64($raw_toml);
        assert_script_run("base64 -d > /tmp/questions.toml << 'EOF'\n${b64_toml}EOF\n", 60);

        # Fetch and run the release installer script in unattended dry-run mode.
        my $install_url = get_var('E2E_INSTALL_URL', 'https://instantos.io/install');
        assert_script_run("curl -fsSL '$install_url' | bash -s -- --config /tmp/questions.toml --dry-run > /tmp/dryrun.log 2>&1; echo \"DRYRUN_RC=\$?\" >> /tmp/dryrun.log", 1800);
        $ins_bin = '/usr/local/bin/ins';
    } else {
        # Fetch the `ins` binary and the questions file from the host machine
        # (slirp NAT: host = 10.0.2.2, python3 -m http.server on port 8000).
        assert_script_run('curl -fsS -o /tmp/ins http://10.0.2.2:8000/ins', 600);
        assert_script_run('chmod +x /tmp/ins', 30);
        assert_script_run("curl -fsS -o /tmp/questions.toml http://10.0.2.2:8000/questions-$profile.toml", 60);
        $ins_bin = '/tmp/ins';

        # Full plan in dry-run mode: validates the hand-written config end to end
        # without touching the (empty) disk.
        script_run("$ins_bin arch exec --dry-run -f /tmp/questions.toml > /tmp/dryrun.log 2>&1; echo \"DRYRUN_RC=\$?\" >> /tmp/dryrun.log", 900);
    }

    # Smoke: the binary runs on the live ISO.
    assert_script_run("$ins_bin arch list | grep -q Keymap", 120);

    # The recorded result of this assert carries the log tail into the test
    # results when it fails (script_run output is not persisted).
    assert_script_run('grep -q "DRYRUN_RC=0" /tmp/dryrun.log || { echo "=== dryrun.log ==="; tail -n 25 /tmp/dryrun.log; false; }', 60);
    assert_script_run('grep -q "Loaded configuration for user: tester" /tmp/dryrun.log', 30);
    assert_script_run('grep -q "Installing base system" /tmp/dryrun.log', 30);
    assert_script_run('grep -q "grub-install" /tmp/dryrun.log', 30);
}

1;
