# Install instantOS onto the SECOND disk from an already-running OS, then
# prove the target is real — and measure what the installer did to the host it
# ran from.
#
# The interesting difference from tests/install.pm is the ending. On the live
# ISO, `power('reset')` boots the freshly installed system because that is the
# only disk with a bootloader. Here the running OS owns /dev/vda and the host
# image has no bootloader at all, so a reset comes straight back to the host.
# Proving the install therefore happens outside this module: run.sh flattens
# casedir/raid/hd1 and boots it standalone through diag/verifydisk, which runs
# the shared login_installed_system() + assert_core_suite(). This module's job
# is to make sure the disk it hands over is worth booting.
#
# Two flows, two different contracts:
#   host-arch     a real install: /dev/vdb partitioned, /mnt a real mount, the
#                 promised packages in the target, and the host's own pacman
#                 configuration still byte-identical afterwards. run.sh then
#                 boots the extracted target and verifies it.
#   host-ubuntu   a refusal: `ins` must not get as far as destroying the
#                 second disk. See the flow-specific blocks below for exactly
#                 what is asserted and why.
#
#   !! host-ubuntu is EXPECTED TO BE RED against instantCLI dev. Read this
#      before "fixing" it. The safety property is real and worth a test, but
#      the product does not implement it on this code path: the host-profile
#      gate lives in `ins arch install` (cli/commands/install.rs, which
#      refuses when `!profile.supports_installation()`), and this module
#      drives `ins arch exec`, which has no such gate. So on Ubuntu the
#      installer repartitions /dev/vdb and only fails afterwards, in the Base
#      step, when it cannot read an /etc/pacman.conf that does not exist.
#      The asserts below are written as the *required* behaviour, so they go
#      green the moment `exec` grows the gate `install` already has. Until
#      then this flow is a red-by-design regression test for a real product
#      gap. CI runs it with continue-on-error for that reason.
#      Do not "fix" it by inverting the asserts to match today's behaviour:
#      that would delete the only thing this flow is for.
use Mojo::Base 'basetest';
use testapi;

sub run {
    my $flow = get_var('E2E_FLOW', 'host-arch');
    my $target = get_var('E2E_TARGET_DISK', '/dev/vdb');

    # The real thing: no --dry-run. TCG emulation makes this slow (package
    # extraction, mkinitcpio), so allow plenty of time.
    script_run('/tmp/ins arch exec -f /tmp/questions.toml > /tmp/install.log 2>&1; '
            . 'echo "INSTALL_RC=$?" >> /tmp/install.log', 10800);

    # Keep the logs as artifacts and dump the interesting bits to the serial
    # console (which lands in the isotovideo log) before asserting. install.log
    # is not persisted by script_run, so upload first.
    upload_logs('/tmp/install.log', failok => 1);
    # The executor's own log records "[timestamp] RUN:" plus "DONE (Xs):" for
    # every command it spawned, chroot steps included — the raw material for
    # install-time profiling (tools/analyze_install_log.py). Both files are
    # called install.log, hence log_name.
    #
    # /run/ins-install, not /var/log/instantos: on a running system the
    # installer keeps its own log in its ephemeral state directory precisely so
    # it does not truncate the source system's install log
    # (src/arch/execution/paths.rs::host_log_file). The live-ISO flow's
    # install.pm uses the /var/log path because there /etc and /var/log are
    # RAM and there is no host to protect.
    upload_logs('/run/ins-install/install.log', failok => 1,
        log_name => 'executor-install.log');

    script_run('echo "=== timing summary ==="; grep -E "completed in|finished in" /tmp/install.log');
    script_run('echo "=== install.log tail ==="; tail -n 40 /tmp/install.log');
    script_run('echo "=== errors ==="; grep -niE "error|failed|refus" /tmp/install.log | head -n 20');
    # The full command timeline, so a failure names the exact tool that was
    # missing or the exact host file that was rewritten.
    script_run('echo "=== executor RUN lines (host steps) ==="; grep -n "RUN:" /run/ins-install/install.log 2>/dev/null | head -n 40');

    if ($flow eq 'host-ubuntu') {
        assert_ubuntu_refused();
    } else {
        assert_arch_installed($target);
    }

    # --- what did the installer do to the HOST? -----------------------------
    # Same dump as host_boot.pm, then a diff. This is the measurement the whole
    # harness exists for: nonlive_install.md §2.3 claims the Base step rewrites
    # the *host's* /etc/pacman.d/mirrorlist and /etc/pacman.conf (absolute
    # paths in src/arch/execution/base.rs) and that installer state lands in the
    # host's /etc/instant and /var/log/instantos (execution/paths.rs). Reading
    # the code is not evidence; these checksums are.
    script_run('st() { { echo "== pacman.d/mirrorlist =="; md5sum /etc/pacman.d/mirrorlist; '
            . 'echo "== pacman.conf =="; md5sum /etc/pacman.conf; '
            . 'echo "== /etc/instant =="; ls -la /etc/instant; '
            . 'echo "== /var/log/instantos =="; ls -la /var/log/instantos; '
            . 'echo "== installdryrun flag =="; ls -la /etc/instant/installdryrun; '
            . 'echo "== fstab =="; md5sum /etc/fstab; '
            . 'echo "== target disk =="; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT '
            . $target . '; '
            . 'echo "== /mnt =="; findmnt /mnt; ls -A /mnt | head; '
            . 'echo "== passwd/shadow =="; md5sum /etc/passwd /etc/shadow; '
            . 'echo "== swap =="; swapon --show; } 2>&1; }; '
            . 'st > /tmp/post-install.txt; cat /tmp/post-install.txt');
    upload_logs('/tmp/post-install.txt', failok => 1, log_name => 'host-post-install.txt');

    # The target disk's own before/after, extracted as plain text so the
    # assertion is about *content* (a partition table, a filesystem) rather
    # than about lsblk's formatting.
    script_run("sfdisk -d $target > /tmp/post-sfdisk.txt 2>/dev/null || true; "
            . "blkid $target* > /tmp/post-blkid.txt 2>&1 || true; "
            . 'cat /tmp/post-sfdisk.txt; cat /tmp/post-blkid.txt');
    script_run('md5sum /etc/pacman.d/mirrorlist /etc/pacman.conf /etc/fstab 2>/dev/null '
            . '| sort -k2 > /tmp/post-host-mirrorlist.sha || true; '
            . 'echo "=== host config diff (pre -> post) ==="; '
            . 'diff /tmp/pre-host-mirrorlist.sha /tmp/post-host-mirrorlist.sha '
            . '&& echo "(no change)"');
    if ($flow eq 'host-ubuntu') {
        script_run('md5sum /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null '
                . '| sort -k2 > /tmp/post-host-apt.sha; '
                . 'echo "=== host apt sources diff (pre -> post) ==="; '
                . 'diff /tmp/pre-host-apt.sha /tmp/post-host-apt.sha && echo "(no change)"');
    }
    upload_logs('/tmp/post-host-mirrorlist.sha', failok => 1,
        log_name => 'host-post-mirrorlist.sha');
    upload_logs('/tmp/pre-host-mirrorlist.sha', failok => 1,
        log_name => 'host-pre-mirrorlist.sha');

    # --- hand the disk over ------------------------------------------------
    # QEMU's blockdevs use cache.no-flush=on, so a raw system_reset would
    # discard whatever the running system never flushed — which silently
    # reverted grub.cfg to empty in earlier live-ISO runs. swapoff -a is
    # layout-agnostic (plain partition or LVM-inside-LUKS).
    script_run('swapoff -a 2>/dev/null; sync');
    if ($flow ne 'host-ubuntu') {
        assert_script_run('umount -R /mnt', 300);
        assert_script_run('sync', 120);
    }
    # No ISO to eject: run.sh direct-boots the kernel and attaches no CD.
    # Shut the host down cleanly (ACPI) so the qcow2 overlays are consistent;
    # QEMU runs with -no-shutdown, so it stays alive for the next stage.
    power('acpi');
    check_shutdown(600);
    power('reset');

    record_info('install', "second-disk install finished on $target; run.sh now boots that disk standalone");
}

# A running Arch must be able to install instantOS onto a spare disk, and the
# only disk it may touch is the one it was told to.
sub assert_arch_installed {
    my ($target) = @_;

    assert_script_run('grep -q "INSTALL_RC=0" /tmp/install.log || '
            . '{ echo "=== install.log ==="; tail -n 40 /tmp/install.log; false; }', 60);
    assert_script_run('grep -q "Successfully installed packages" /tmp/install.log', 60,
        fail_message => 'pacstrap/base step did not report success');
    assert_script_run('grep -q "grub-install" /tmp/install.log', 60,
        fail_message => 'bootloader step never ran');

    # /mnt is a real mount, on the *second* disk. This is the assertion that
    # makes the run mean "install onto a spare disk" rather than "install
    # somewhere and hope".
    assert_script_run('findmnt -n -o TARGET /mnt | grep -qx /mnt', 60,
        fail_message => '/mnt is not a mount point after the install');
    assert_script_run('findmnt -n -o SOURCE /mnt | grep -q "^' . $target . '"', 60,
        fail_message => "/mnt is not backed by $target — the install went to the wrong disk");
    assert_script_run('ls -A /mnt | grep -qx etc', 60,
        fail_message => '/mnt has no /etc — the target root filesystem is empty');
    assert_script_run('! test -e /mnt/usr/bin/ins-install', 60,
        fail_message => 'the chroot hand-off binary is still in the target: the installer did not '
            . 'run its finish-time cleanup, so this did not complete as a full installation');

    # --- the host must be unharmed ----------------------------------------
    # These encode the property the non-live design actually promises: an
    # install from a running system must not reconfigure the system it ran
    # from. They are written as the *correct* behaviour, not as a snapshot of
    # a past bug, so they are GREEN on a product that isolates its pacman
    # configuration (PackageSource::Isolated) and RED on one that does not.
    #
    # History, because it is easy to get this backwards: at instantCLI 49ff5bb9
    # — before the non-live install work — the Base step wrote the host's
    # /etc/pacman.d/mirrorlist and /etc/pacman.conf with absolute paths, and
    # these asserts failed. They are regression tests for that bug, not
    # characterisation of it. If one goes red, the product regressed; do not
    # "restore" the old behaviour to make it pass.
    assert_script_run('diff -q /tmp/pre-host-mirrorlist.sha /tmp/post-host-mirrorlist.sha',
        60,
        fail_message => 'the installer rewrote the HOST\'s package-manager configuration '
            . '(/etc/pacman.d/mirrorlist and/or /etc/pacman.conf) — an install from a running '
            . 'system must leave the source system alone. This is a product regression, not a '
            . 'test problem: see docs/FINDINGS.md "non-live install characterisation" and '
            . 'instantCLI nonlive_install.md §2.3.');

    # Nothing of the installer's state may leak into the host's /etc either.
    # /etc/instant on a real system is the source system's own state, not
    # scratch space (nonlive_install.md §2.3, second landmine).
    assert_script_run('! test -e /etc/instant/questions.toml', 30,
        fail_message => 'the installer wrote its questions into the HOST\'s /etc/instant/');
    assert_script_run('! test -e /etc/instant/installdryrun', 30,
        fail_message => 'the installer left the force-dry-run flag in the HOST\'s /etc/instant/ '
            . '— every future install on this machine would silently become a no-op');
}

# A foreign distro has no Arch toolchain, so the installer must bail out
# *before* it repartitions the second disk. Assert on the message rather than
# the exit code: the refusal paths in the product print to stderr and return
# Ok(()) (cli/commands/install.rs), so `ins arch install` exits 0 after
# refusing, and an exit-code-only assertion would pass on a run that installed
# nothing *and* on a run that installed everything.
#
# See the module header: these asserts are RED on instantCLI dev because
# `ins arch exec` has no host-profile gate. They are the required behaviour,
# not a snapshot of the current one.
sub assert_ubuntu_refused {
    my ($target) = @_;

    record_info('host-ubuntu',
        'foreign-distro run: the asserts below encode the REQUIRED behaviour (refuse before '
            . 'writing the disk). They are expected to fail against a product whose '
            . '`ins arch exec` has no HostProfile gate — see docs/FINDINGS.md.');

    # The soft warning the product emits for every non-`info` `ins arch`
    # subcommand on a non-Arch distro (cli/commands/mod.rs). This one DOES pass
    # today: the warning lives in the shared command dispatcher.
    assert_script_run('grep -q "You appear to be running on" /tmp/install.log', 30,
        fail_message => 'no foreign-distro warning: the installer did not notice it is on Ubuntu');

    # The run must not report success. A completed install on Ubuntu would
    # print "Successfully installed packages"; assert its absence.
    assert_script_run('! grep -q "Successfully installed packages" /tmp/install.log', 30,
        fail_message => 'the installer claims it installed packages on Ubuntu');

    # And it must not have destroyed the second disk. A blank disk has no
    # partition table at all, so any of these appearing means it was written.
    assert_script_run("! sfdisk -d $target 2>/dev/null | grep -q '^label:'", 60,
        fail_message => "$target was partitioned before the installer refused — the refusal "
            . 'happens too late, because `ins arch exec` has no HostProfile gate (the gate is '
            . 'in `ins arch install`, which this flow does not use). Expected to fail on '
            . 'instantCLI dev; see /tmp/post-sfdisk.txt and docs/FINDINGS.md. See also '
            . 'instantCLI nonlive_install.md §4.');
    assert_script_run("! blkid $target >/dev/null 2>&1", 60,
        fail_message => "$target has a signature (a filesystem was made on it) "
            . 'even though the installer must have refused');
    assert_script_run('! findmnt /mnt >/dev/null 2>&1', 30,
        fail_message => '/mnt is still mounted after a refused install');

    # The host's own package manager configuration must be untouched too:
    # the Base step writes /etc/pacman.d/mirrorlist with absolute paths, and
    # on Ubuntu that path does not even exist.
    assert_script_run('! test -e /etc/pacman.d/mirrorlist', 30,
        fail_message => 'the installer created /etc/pacman.d/mirrorlist on an Ubuntu host');
    assert_script_run('diff -q /tmp/pre-host-apt.sha /tmp/post-host-apt.sha', 30,
        fail_message => 'the installer rewrote the Ubuntu host\'s apt sources');
}

1;
