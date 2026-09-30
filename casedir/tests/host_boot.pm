# Boot a prepared *running* host OS (Arch or Ubuntu 24.04) and prepare it to
# install instantOS onto a second disk.
#
# This is the non-live counterpart of tests/boot.pm. Same end state as that
# module — root shell on the virtio serial console with `ins` and a questions
# file in /tmp — reached a different way:
#
#   * there is no ISO, no syslinux menu and no autologin. run.sh direct-boots
#     the host image (KERNEL/INITRD/APPEND, see tools/mkhost-*.sh) and the
#     image itself enables serial-getty on hvc0 *and* ttyS0, so everything
#     happens over the virtio console with no needles at all;
#   * the questions file is assets/questions-seconddisk.toml — the same shape
#     as questions-minimal.toml with exactly one difference, `Disk = "/dev/vdb"`:
#     the running OS owns /dev/vda and the blank second disk is the target.
#
# Before the dry-run it records the *host* state the report
# (instantCLI/nonlive_install.md) claims the installer clobbers: the host's
# /etc/pacman.d/mirrorlist, /etc/pacman.conf, /etc/instant/ and
# /var/log/instantos/install.log. host_install.pm re-reads the same files after
# the real run and diffs them — the whole point is to measure that empirically
# from inside the guest rather than by reading the code.
use Mojo::Base 'basetest';
use testapi;

sub run {
    my $flow = get_var('E2E_FLOW', 'host-arch');
    my $profile = get_var('E2E_PROFILE', 'minimal');
    my $target = get_var('E2E_TARGET_DISK', '/dev/vdb');

    # --- get a root shell on hvc0 ------------------------------------------
    select_console 'root-console';

    # hvc0 getty. The host images enable serial-getty@hvc0 explicitly, so this
    # is a plain password login (unlike the live ISO, which autologins).
    assert_script_run_login();

    # Widen the terminal before anything long is typed: at the 80-column
    # default long commands wrap and bash's line redraws (ESC[K) break
    # script_run's echo confirmation. exec bash --norc drops any rc files that
    # might colour the prompt (the ISO ships a coloured zsh prompt; script_run
    # markers starting with ~ get tilde-expanded, see isotests.md).
    type_string "exec bash --norc\n";
    wait_serial '# ', 120;
    script_run('stty cols 400 rows 100');

    # --- the environment we think we are in --------------------------------
    # Cheap, and it turns a silently wrong image into an immediate failure.
    script_run('echo "=== host identity ==="; uname -srm; cat /etc/os-release; hostname');
    script_run('echo "=== disks ==="; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL');
    assert_script_run('test -b /dev/vda', 30,
        fail_message => 'no /dev/vda: the host image is not attached as disk 1');
    assert_script_run("test -b $target", 30,
        fail_message => "no $target: the second (blank) disk is missing");
    assert_script_run('test -b /dev/vda1', 30,
        fail_message => 'host image has no GPT partition on /dev/vda — the mkfs.ext4 -d step is broken');
    # The kernel mounts / ro by default and only systemd-remount-fs makes it
    # writable (the cmdline carries no `rw`, because os-autoinst cannot pass a
    # multi-token -append). If that did not happen the installer would fail
    # later on a write to /etc, so assert it here where the cause is obvious.
    assert_script_run('findmnt -n -o OPTIONS / | grep -qw rw', 60,
        fail_message => 'the running root filesystem is read-only');
    # The running root must be on the *other* disk, or the whole flow is
    # testing the destructive in-place case by accident.
    assert_script_run('findmnt -n -o SOURCE / | grep -q "^/dev/vda"', 60,
        fail_message => 'the running root filesystem is not on /dev/vda');
    # DHCP on the slirp NIC: the guest reaches the host (asset server) at
    # 10.0.2.2. Also proves the direct-boot kernel has working virtio-net.
    assert_script_run('ping -c 2 -W 5 10.0.2.2', 120);
    assert_script_run('getent hosts archlinux.org > /dev/null || ping -c1 -W5 1.1.1.1 > /dev/null',
        120, fail_message => 'no working network/DNS in the host image');

    # --- inject ins + the second-disk questions file ------------------------
    assert_script_run('curl -fsS -o /tmp/ins http://10.0.2.2:8000/ins', 600);
    assert_script_run('chmod +x /tmp/ins', 30);
    assert_script_run(
        "curl -fsS -o /tmp/questions.toml http://10.0.2.2:8000/questions-seconddisk.toml", 60);
    assert_script_run("grep -qx 'Disk = \"$target\"' /tmp/questions.toml", 30,
        fail_message => 'questions-seconddisk.toml does not target the second disk');

    # --- snapshot the host state BEFORE the installer runs -----------------
    # Checksummed from inside the guest: reading the code says the Base step
    # rewrites /etc/pacman.d/mirrorlist and /etc/pacman.conf with absolute
    # paths (src/arch/execution/base.rs), and that installer state is written
    # under the host's /etc/instant and /var/log/instantos (execution/paths.rs).
    # A checksum before/after settles it without trusting either claim.
    # One single-line command on purpose: a multi-line heredoc fed through
    # script_run is a known trap (the marker/echo handshake times out — see
    # isotests.md), so the state dump is a one-liner shell function.
    script_run('st() { { echo "== pacman.d/mirrorlist =="; md5sum /etc/pacman.d/mirrorlist; '
            . 'echo "== pacman.conf =="; md5sum /etc/pacman.conf; '
            . 'echo "== /etc/instant =="; ls -la /etc/instant; '
            . 'echo "== /var/log/instantos =="; ls -la /var/log/instantos; '
            . 'echo "== installdryrun flag =="; ls -la /etc/instant/installdryrun; '
            . 'echo "== fstab =="; md5sum /etc/fstab; '
            . 'echo "== target disk =="; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT '
            . get_var('E2E_TARGET_DISK', '/dev/vdb') . '; '
            . 'echo "== /mnt =="; findmnt /mnt; ls -A /mnt | head; '
            . 'echo "== passwd/shadow =="; md5sum /etc/passwd /etc/shadow; '
            . 'echo "== swap =="; swapon --show; } 2>&1; }; '
            . 'st > /tmp/pre-install.txt; cat /tmp/pre-install.txt');

    # A tiny sentinel the post-run check can compare against, so the diff is
    # a single readable file rather than a pile of md5 lines.
    script_run('md5sum /etc/pacman.d/mirrorlist /etc/pacman.conf /etc/fstab 2>/dev/null '
            . '| sort -k2 > /tmp/pre-host-mirrorlist.sha || true');
    # Ubuntu has no pacman at all: record its apt sources with the same shape
    # so the post-run diff works for both flows.
    if ($flow eq 'host-ubuntu') {
        script_run('md5sum /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null '
                . '| sort -k2 > /tmp/pre-host-apt.sha; cat /tmp/pre-host-apt.sha');
    }

    # --- dry run -------------------------------------------------------------
    # Same command the live-ISO flow uses, against the second-disk questions.
    # A dry run must not touch the disk, so it is also the first check that
    # the target really is untouched by the non-destructive path.
    script_run('/tmp/ins arch exec --dry-run -f /tmp/questions.toml '
            . '> /tmp/dryrun.log 2>&1; echo "DRYRUN_RC=$?" >> /tmp/dryrun.log');
    upload_logs('/tmp/dryrun.log', failok => 1);
    upload_logs('/tmp/pre-install.txt', failok => 1, log_name => 'host-pre-install.txt');
    script_run('echo "=== dryrun.log ==="; cat /tmp/dryrun.log');
    script_run('echo "=== dryrun errors ==="; grep -niE "error|fail|warn|refus" /tmp/dryrun.log | head -n 20');

    # `ins` runs at all on this host.
    assert_script_run('/tmp/ins arch list | grep -q Keymap', 120);
    assert_script_run("grep -q 'Disk = \"$target\"' /tmp/questions.toml", 30);

    if ($flow eq 'host-ubuntu') {
        # Foreign distro: today the *only* thing the product does about it is a
        # soft warning on every `ins arch` subcommand except `info`
        # (src/arch/cli/commands/mod.rs:29-34). The hard refusal lives only in
        # the interactive wizard (cli/commands/install.rs:120-131), which
        # `ins arch exec` never reaches. Assert the warning is there so the
        # characterisation is anchored on the real message, and leave the
        # verdict on the dry-run outcome to host_install.pm.
        assert_script_run('grep -q "You appear to be running on" /tmp/dryrun.log', 30,
            fail_message => 'no foreign-distro warning in the dry-run output');
        record_info('dryrun', 'foreign-distro dry-run finished; see host-dryrun.log for the full output');
    }
    else {
        # Running Arch: the full plan must validate end to end, exactly as on
        # the live ISO. This is the assertion that proves the disk guard lets a
        # *different* disk through (questions/disk.rs::validate compares the
        # answer against findmnt's root device and the traced boot disk).
        assert_script_run('grep -q "DRYRUN_RC=0" /tmp/dryrun.log || '
                . '{ echo "=== dryrun.log ==="; tail -n 30 /tmp/dryrun.log; false; }', 60);
        assert_script_run('grep -q "Loaded configuration for user: tester" /tmp/dryrun.log', 30);
        assert_script_run('grep -q "Installing base system" /tmp/dryrun.log', 30);
        assert_script_run('grep -q "grub-install" /tmp/dryrun.log', 30);
        record_info('dryrun', 'running-Arch dry-run against the second disk passed');
    }

    record_info('flow', "non-live flow $flow: running host on /dev/vda, target $target");
}

# Log in as root over the virtio console. Kept here (rather than reused from
# installed_base::login_installed_system) because the dance is different in
# every detail: the host images have no VGA getty we use, no getty we have to
# start, and the password prompt is plain ASCII on serial, so no needles are
# needed at all.
sub assert_script_run_login {
    wait_serial 'login:', 600;
    type_string "root\n";
    wait_serial 'Password:', 60;
    type_password;
    send_key 'ret';
    wait_serial '# ', 180;
}

1;
