# Boot an install medium, add a serial console, make `ins` and the
# questions file available in the live system, and run the installer's
# non-interactive path (dry-run first).
#
# Two media:
#   default            the Arch ISO: inject `ins` + questions over slirp HTTP
#                      (dev) or install.sh (release), install from mirrors
#   E2E_OFFLINE=1      the offline-injected instantOS ISO (Phase 3,
#                      instantOS/offlineiso.md): no NIC at all — the
#                      questions file is typed in as a base64 heredoc
#                      (network-free, same trick as release mode) and the
#                      shipped `ins` installs from the on-ISO bundle
use Mojo::Base 'basetest';
use testapi;
use MIME::Base64 'encode_base64';

sub run {
    my $profile = get_var('E2E_PROFILE', 'minimal');
    my $is_release = get_var('E2E_RELEASE');
    my $offline = get_var('E2E_OFFLINE');
    my $ins_bin;

    if ($offline) {
        # The instantOS live ISO boots the same syslinux menu (shared needle)
        # and takes the same Tab cmdline edit.
        assert_screen 'iso-bootloader', 180;
        send_key 'tab';
        type_string ' console=hvc0 console=ttyS0';
        send_key 'ret';

        # greetd autologins the live user on tty1 (the VGA console shows the
        # desktop); scripted interaction happens as root on hvc0, which has
        # an empty password on the live image.
        select_console 'root-console';
        my $got_login = 0;
        for (1 .. 40) {
            $got_login = wait_serial('instantlive login:', timeout => 15, quiet => 1);
            last if $got_login;
            type_string "\n";
        }
        die 'no getty on hvc0 (console=hvc0 did not produce a serial login)'
            unless $got_login;
        type_string "root\n";
        wait_serial '# ', 300;
        # zsh marker-hostility: continue under bash --norc (see
        # diag/liveiso/tests/liveiso.pm for the full story).
        type_string "exec bash --norc\n";
        wait_serial '# ', 60;
        script_run('stty cols 400 rows 100');

        # Fail fast on the Phase 0 preconditions before a long install: the
        # bundle must be mounted where the installer probes it, and the
        # offline image wiring must have shipped.
        assert_script_run('test -e /run/archiso/bootmnt/offline-repo/core/os/x86_64/core.db', 60,
            fail_message => 'offline bundle not mounted at /run/archiso/bootmnt');
        assert_script_run('test -e /usr/share/instantos/offline-image', 60);
        assert_script_run('test -e /usr/share/instantos/build-inputs/dotfiles/.git/config', 60,
            fail_message => 'dotfiles snapshot missing (build-inputs was deleted)');
        assert_script_run('grep -m1 "^Server" /etc/pacman.d/mirrorlist | grep -Fq "file://"', 60,
            fail_message => 'mirrorlist does not prefer the offline bundle');

        # Questions file over serial: base64 heredoc, no network involved.
        my $qfile = "/tests/assets/questions-$profile.toml";
        open my $fh, '<', $qfile or die "Cannot open $qfile: $!";
        my $raw_toml = do { local $/; <$fh> };
        close $fh;
        my $b64_toml = encode_base64($raw_toml);
        assert_script_run("base64 -d > /tmp/questions.toml << 'EOF'\n${b64_toml}EOF\n", 60);

        # The shipped installer: LOCAL_INS_BIN (injected at ISO build time)
        # lives at /usr/local/bin/ins, shadowing the packaged /usr/bin/ins.
        assert_script_run('test -x /usr/local/bin/ins', 30,
            fail_message => 'no /usr/local/bin/ins: ISO was not built with LOCAL_INS_BIN');
        $ins_bin = '/usr/local/bin/ins';
        script_run("$ins_bin arch exec --dry-run -f /tmp/questions.toml > /tmp/dryrun.log 2>&1; echo \"DRYRUN_RC=\$?\" >> /tmp/dryrun.log", 900);
    } else {
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
