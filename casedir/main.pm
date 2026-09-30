use Mojo::Base -strict;
use testapi;
use autotest;

# Populate the secret used by type_password (openQA normally does this).
testapi::set_password(get_var('PASSWORD', ''));

# Declare the virtio console as 'root-console'. The QEMU backend already
# attaches FIFO pipes to the first virtio-console device; the guest kernel is
# booted with console=hvc0 so a serial getty appears there.
$testapi::distri->add_console('root-console', 'virtio-terminal');
# VGA console tty1: needed to watch the installed system boot and to log in
# on it (the installer does not put console= on the installed kernel cmdline).
$testapi::distri->add_console('user-console', 'tty-console', {tty => 1});

my $flow = get_var('E2E_FLOW', 'live');

if ($flow eq 'live') {
    autotest::loadtest 'tests/boot.pm';

    # Smoke mode (E2E_SMOKE=1): stop after the boot module — the in-VM
    # dry-run covers config validation without the ~25 min install. Full mode
    # continues with the real installation and the post-reboot verification.
    unless (get_var('E2E_SMOKE')) {
        autotest::loadtest 'tests/install.pm';
        autotest::loadtest 'tests/verify.pm';
    }
} else {
    # The non-live flows replace boot.pm wholesale: there is no ISO menu to
    # type into and no autologin, just a getty on hvc0 (the host images enable
    # serial-getty on hvc0 and ttyS0) and a real root password.
    autotest::loadtest 'tests/host_boot.pm';

    # Smoke mode here means the same thing it means on the live ISO: host_boot
    # logs in, injects `ins` and dry-runs the second-disk plan, and that is
    # the whole run. Without this guard `--host-arch --smoke` would perform the
    # full ~50 min install and then skip verification, which is neither the
    # cheap loop the docs promise nor a smoke test.
    unless (get_var('E2E_SMOKE')) {
        autotest::loadtest 'tests/host_install.pm';
    }
}

1;
