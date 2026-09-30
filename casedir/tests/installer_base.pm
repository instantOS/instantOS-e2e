# Shared guest preparation, execution and evidence collection.
package installer_base;
use Mojo::Base -strict;
use Exporter 'import';
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA 'sha256_hex';
use File::Basename 'basename';
use File::Path 'make_path';
use testapi;
our @EXPORT_OK = qw(
    write_guest_file collect_log prepare_questions prepare_installer installer_binary
    run_dry_run assert_dry_run run_install assert_install_success
    login_instant_iso assert_offline_bundle capture_host_state assert_host_unchanged
    assert_blank_disk shutdown_guest
);

sub write_guest_file {
    my ($destination, $content) = @_;
    my $encoded = encode_base64($content, '');
    my $digest = sha256_hex($content);
    # One shell command keeps script_run's echo/exit handshake intact.
    # The widened terminal fits our small fixtures; verify bytes after decoding.
    assert_script_run("printf '%s' '$encoded' | base64 -d > $destination "
        . "&& echo '$digest  $destination' | sha256sum -c -", 60);
}

sub prepare_questions {
    my $profile = get_var('E2E_PROFILE', 'minimal');
    die "Unknown profile: $profile" unless $profile =~ /\A(?:minimal|full|encrypted)\z/;
    my $path = "/tests/assets/questions-$profile.toml";
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    my $target = get_var('E2E_TARGET_DISK', '/dev/vda');
    die "Unexpected target: $target" unless $target =~ m{\A/dev/vd[ab]\z};
    my $count = ($content =~ s/^Disk = .*$/Disk = "$target"/mg);
    die 'Expected exactly one Disk answer' unless $count == 1;
    write_guest_file('/tmp/questions.toml', $content);
}

sub collect_log {
    my ($file, %args) = @_;
    my $name = basename($args{log_name} // $file);
    unless (get_var('OFFLINE_SUT')) {
        return upload_logs($file, failok => 1, log_name => $name);
    }
    if (script_run("test -f '$file'", 30)) {
        record_info('log absent', $file);
        return;
    }
    # The backend skips HTTP uploads for OFFLINE_SUT. Transfer exact bytes over
    # the serial console and save them beside ordinary uploaded logs instead.
    my $output = script_output("sha256sum '$file'; base64 -w0 '$file'", 180);
    my ($header, $encoded) = split /\r?\n/, $output, 2;
    my ($digest) = $header =~ /\A([a-f0-9]{64}) /;
    my $content = decode_base64($encoded // '');
    die "Corrupt serial log: $file" unless $digest && sha256_hex($content) eq $digest;
    make_path('ulogs');
    open my $fh, '>:raw', "ulogs/$name" or die "Cannot save $name: $!";
    print {$fh} $content or die "Cannot write $name: $!";
    close $fh or die "Cannot close $name: $!";
}

sub installer_binary {
    my $source = get_var('E2E_INSTALLER', 'checkout');
    return '/tmp/ins' if $source eq 'checkout';
    return 'ins' if $source eq 'shipped';
    return '/usr/local/bin/ins';
}

sub prepare_installer {
    my $source = get_var('E2E_INSTALLER', 'checkout');
    if ($source eq 'checkout') {
        my $url = get_required_var('E2E_ASSET_URL');
        assert_script_run("curl -fsS -o /tmp/ins $url/ins", 600);
        assert_script_run('chmod +x /tmp/ins', 30);
    } elsif ($source eq 'shipped') {
        # Published images use packaged /usr/bin/ins. Local builds may shadow
        # it with LOCAL_INS_BIN in /usr/local/bin; both are shipped on the ISO.
        assert_script_run('command -v ins >/dev/null', 30,
            fail_message => 'offline ISO is missing its shipped ins');
        script_run('command -v ins; ins --version', 60);
    } elsif ($source ne 'release') {
        die "Unknown installer source: $source";
    }
}

sub run_dry_run {
    if (get_var('E2E_INSTALLER', 'checkout') eq 'release') {
        # Download separately so a failed curl cannot be hidden by the pipeline.
        assert_script_run('curl -fsSL -o /tmp/install.sh https://instantos.io/install', 600);
        script_run('bash /tmp/install.sh --config /tmp/questions.toml --dry-run '
            . '> /tmp/dryrun.log 2>&1; echo "DRYRUN_RC=$?" >> /tmp/dryrun.log', 1800);
    } else {
        my $binary = installer_binary();
        script_run("$binary arch exec --dry-run -f /tmp/questions.toml "
            . '> /tmp/dryrun.log 2>&1; echo "DRYRUN_RC=$?" >> /tmp/dryrun.log', 900);
    }
    collect_log('/tmp/dryrun.log');
    script_run('tail -n 40 /tmp/dryrun.log');
    assert_script_run(installer_binary() . ' arch list | grep -q Keymap', 120);
}

sub assert_dry_run {
    assert_script_run('grep -qx "DRYRUN_RC=0" /tmp/dryrun.log', 60);
    assert_script_run('grep -E "useradd .*tester" /tmp/dryrun.log', 30);
    assert_script_run('grep -E "pacstrap .*linux" /tmp/dryrun.log', 30);
    assert_script_run('grep -q "grub-install" /tmp/dryrun.log', 30);
}

sub run_install {
    my $binary = installer_binary();
    script_run("$binary arch exec -f /tmp/questions.toml > /tmp/install.log 2>&1; "
        . 'echo "INSTALL_RC=$?" >> /tmp/install.log', 10800);
    collect_log('/tmp/install.log');
    my $executor = get_var('E2E_FLOW', 'live') =~ /^host-/
        ? '/run/ins-install/install.log' : '/var/log/instantos/install.log';
    collect_log($executor, log_name => 'executor-install.log');
    script_run('grep -E "completed in|finished in" /tmp/install.log; tail -n 40 /tmp/install.log');
    script_run("grep -n 'RUN:' $executor | head -n 40");
}

sub assert_install_success {
    assert_script_run('grep -qx "INSTALL_RC=0" /tmp/install.log', 60);
    # Check the target's output, independent of the installer's status wording.
    assert_script_run('test -x /mnt/usr/bin/pacman', 60);
    assert_script_run('test -s /mnt/etc/fstab', 60);
    assert_script_run('test -s /mnt/boot/grub/grub.cfg', 60);
}

sub login_instant_iso {
    select_console 'root-console';
    my $login = 0;
    for (1 .. 40) {
        $login = wait_serial('instantlive login:', timeout => 15, quiet => 1);
        last if $login;
        type_string "\n";
    }
    die 'No getty on hvc0' unless $login;
    type_string "root\n";
    wait_serial '# ', 300;
    # zsh expands some script_run markers; use bash for the serial handshake.
    type_string "exec bash --norc\n";
    # script_run waits for the new shell prompt itself.
    script_run('stty cols 4096 rows 100');
}

sub assert_offline_bundle {
    assert_script_run('test -e /run/archiso/bootmnt/offline-repo/core/os/x86_64/core.db', 60);
    assert_script_run('test -e /run/archiso/bootmnt/offline-repo/packages.list', 60);
    assert_script_run('test -e /run/archiso/bootmnt/offline-repo/regions/regions.html', 60);
    assert_script_run('test -e /usr/share/instantos/offline-image', 60);
    assert_script_run('test -e /usr/share/instantos/build-inputs/dotfiles/.git/config', 60);
    assert_script_run('grep -m1 "^Server" /etc/pacman.d/mirrorlist '
        . '| grep -Fq "file:///run/archiso/bootmnt/offline-repo"', 60);
}

sub capture_host_state {
    my ($phase, $target) = @_;
    die 'Invalid snapshot phase' unless $phase =~ /\A(?:pre|dryrun|post)\z/;
    # The same shipped script produces every snapshot; no copied shell functions.
    if ($phase eq 'pre') {
        open my $fh, '<', '/tests/assets/host-state.sh' or die "Cannot read host-state.sh: $!";
        write_guest_file('/tmp/host-state.sh', do { local $/; <$fh> });
        close $fh;
    }
    assert_script_run("bash /tmp/host-state.sh $phase $target", 60);
    collect_log("/tmp/$phase-host-state.txt");
    collect_log("/tmp/$phase-host-config.sha");
}

sub assert_host_unchanged {
    my ($phase) = @_;
    assert_script_run("diff -u /tmp/pre-host-config.sha /tmp/$phase-host-config.sha", 60,
        fail_message => 'installer changed the running host configuration');
    assert_script_run('! test -e /etc/instant/questions.toml', 30);
    assert_script_run('! test -e /etc/instant/installdryrun', 30);
}

sub assert_blank_disk {
    my ($target) = @_;
    # wipefs probes partition tables and filesystem signatures without writing.
    assert_script_run("test -b $target && wipefs -n --noheadings $target > /tmp/disk-signatures "
        . '&& test ! -s /tmp/disk-signatures', 60,
        fail_message => "$target is no longer blank");
    assert_script_run("! sfdisk -d $target 2>/dev/null | grep -q '^label:'", 60);
    assert_script_run("! blkid $target >/dev/null 2>&1", 60);
}

sub shutdown_guest {
    my ($eject, $reset) = @_;
    assert_script_run('swapoff -a', 120);
    assert_script_run('umount -R /mnt', 300);
    assert_script_run('sync', 120);
    eject_cd if $eject;
    power('acpi');
    check_shutdown(600);
    power('reset') if $reset;
}
1;
