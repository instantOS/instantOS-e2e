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

autotest::loadtest 'tests/boot.pm';

# Smoke mode (E2E_SMOKE=1): stop after the boot module — the in-VM dry-run
# covers config validation without the ~25 min install. Full mode continues
# with the real installation and the post-reboot verification.
unless (get_var('E2E_SMOKE')) {
    autotest::loadtest 'tests/install.pm';
    autotest::loadtest 'tests/verify.pm';
}

1;
