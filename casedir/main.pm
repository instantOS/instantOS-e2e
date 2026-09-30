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

die "Unknown E2E_FLOW: $flow" unless $flow =~ /\A(?:live|offline|host-arch|host-ubuntu)\z/;
my $host = $flow =~ /^host-/;
autotest::loadtest($host ? 'tests/host_boot.pm' : 'tests/boot.pm');
unless (get_var('E2E_SMOKE')) {
    autotest::loadtest($host ? 'tests/host_install.pm' : 'tests/install.pm');
    autotest::loadtest('tests/verify.pm') unless $host;
}
1;
