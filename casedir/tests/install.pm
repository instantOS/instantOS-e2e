# Run the real installation, then reboot into the installed system.
#
# Continues from tests/boot.pm: we are root on the hvc0 serial console of the
# live ISO, with /tmp/ins and /tmp/questions.toml in place.
use Mojo::Base 'basetest';
use testapi;

sub run {
    # The real thing: no --dry-run. TCG emulation makes this slow (package
    # extraction, mkinitcpio), so allow plenty of time.
    my $ins_bin = get_var('E2E_RELEASE') ? '/usr/local/bin/ins' : '/tmp/ins';
    script_run("$ins_bin arch exec -f /tmp/questions.toml > /tmp/install.log 2>&1; echo \"INSTALL_RC=\$?\" >> /tmp/install.log", 10800);

    # Keep the logs as artifacts and dump the interesting bits to the serial
    # console (which lands in the isotovideo log) before asserting.
    upload_logs('/tmp/install.log', failok => 1);
    # The executor's own log records "[timestamp] RUN:" plus "DONE (Xs):" for
    # every command it spawned, chroot steps included — the raw material for
    # install-time profiling (tools/analyze_install_log.py). log_name keeps
    # the two artifacts apart (both files are called install.log).
    upload_logs('/var/log/instantos/install.log', failok => 1,
        log_name => 'executor-install.log');
    script_run('echo "=== timing summary ==="; grep -E "completed in|finished in" /tmp/install.log');
    script_run('echo "=== bootloader section ==="; sed -n "/Installing bootloader/,/Executing single step: Post/p" /tmp/install.log | tail -n 60');
    script_run('echo "=== install.log tail ==="; tail -n 40 /tmp/install.log');
    script_run('echo "=== errors ==="; grep -niE "error|failed|refusing" /tmp/install.log | head -n 20');

    assert_script_run('grep -q "INSTALL_RC=0" /tmp/install.log', 60);
    assert_script_run('grep -q "Successfully installed packages" /tmp/install.log', 60);

    # The installer prints this at the very end of the post step.
    assert_script_run('grep -q "grub-install" /tmp/install.log', 60);

    # Cleanly release the target filesystem like a user-initiated reboot
    # would. QEMU blockdevs use cache.no-flush=on, so a raw system_reset
    # would discard whatever pages the live system never flushed — which
    # silently reverted grub.cfg to empty in earlier runs.
    # swapoff -a is layout-agnostic (plain partition or LVM-inside-LUKS).
    assert_script_run('swapoff -a', 120);
    assert_script_run('umount -R /mnt', 300);
    assert_script_run('sync', 120);

    # Remove the ISO from the (SCSI) CD drive, shut the live system down
    # cleanly (ACPI), then reset — QEMU runs with -no-shutdown, so the
    # process survives and SeaBIOS falls through to the hard disk.
    eject_cd;
    power('acpi');
    check_shutdown(600);
    power('reset');

    # The installed system has no getty on the serial console (the installer
    # does not put console=hvc0 on the installed kernel cmdline), so switch
    # to the VGA console and watch it boot there. tests/verify.pm takes it
    # from here.
    select_console 'user-console';
}

1;
