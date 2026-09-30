use strict;
use warnings;
use Test::More;

# Fake only the VM API. Load and execute the real guest modules and helpers.
BEGIN {
    package basetest;
    $INC{'basetest.pm'} = 1;
    package testapi;
    use Exporter 'import';
    our @EXPORT = qw(get_var get_required_var assert_script_run script_run script_output upload_logs
        record_info select_console wait_serial type_string type_password send_key
        power check_shutdown eject_cd assert_screen sleep);
    our (%vars, @commands, @uploads, $fail_assert, $output_override);
    sub get_var { exists $vars{$_[0]} ? $vars{$_[0]} : $_[1] }
    sub get_required_var { die "Missing $_[0]" unless exists $vars{$_[0]}; $vars{$_[0]} }
    sub assert_script_run {
        push @commands, $_[0];
        die "Guest command failed: $_[0]\n" if $fail_assert && $_[0] =~ $fail_assert;
        0;
    }
    sub script_run { push @commands, $_[0]; 0 }
    sub script_output {
        push @commands, $_[0];
        return $output_override if defined $output_override;
        return Digest::SHA::sha256_hex("offline log\n") . "  /tmp/dryrun.log\n"
            . MIME::Base64::encode_base64("offline log\n", '');
    }
    sub upload_logs { push @uploads, $_[0] }
    sub record_info {}
    sub select_console {}
    sub wait_serial { 1 }
    sub type_string { push @commands, "type:$_[0]" }
    sub type_password {}
    sub send_key {}
    sub power { push @commands, "power:$_[0]" }
    sub check_shutdown { push @commands, "shutdown-complete" }
    sub eject_cd { push @commands, "eject" }
    sub assert_screen {}
    sub sleep {}
    $INC{'testapi.pm'} = 1;
}
use lib 'casedir/tests';
use installer_base qw(prepare_questions run_dry_run assert_blank_disk);

$testapi::vars{E2E_PROFILE} = 'minimal';
$testapi::vars{E2E_TARGET_DISK} = '/dev/vdb';
prepare_questions();
my ($encoded) = $testapi::commands[-1] =~ /printf '%s' '([^']+)'/;
use MIME::Base64 'decode_base64';
my $questions = decode_base64($encoded);
like($questions, qr/^Disk = "\/dev\/vdb"$/m, 'second-disk config is derived from minimal');
unlike($questions, qr/\/dev\/vda/, 'original target is replaced');
unlike($testapi::commands[-1], qr/\n/, 'file injection uses one shell command');
like($testapi::commands[-1], qr/sha256sum -c -/, 'decoded content is checked for integrity');

$testapi::vars{E2E_INSTALLER} = 'release';
@testapi::commands = ();
run_dry_run();
like($testapi::commands[0], qr/curl .* -o \/tmp\/install.sh/, 'release download has its own assertion');
like($testapi::commands[1], qr/bash \/tmp\/install.sh/, 'release script executes only after download');
ok(grep($_ eq '/tmp/dryrun.log', @testapi::uploads), 'dry-run evidence is uploaded');

{
    package host_install;
    require './casedir/tests/host_install.pm';
}
for my $flow ('host-arch', 'host-ubuntu') {
    %testapi::vars = (E2E_FLOW => $flow, E2E_TARGET_DISK => '/dev/vdb', E2E_INSTALLER => 'checkout');
    @testapi::commands = ();
    @testapi::uploads = ();
    host_install::run(undef);
    my ($capture) = grep { $testapi::commands[$_] =~ /bash \/tmp\/host-state.sh post/ } 0..$#testapi::commands;
    my ($compare) = grep { $testapi::commands[$_] =~ /diff -u \/tmp\/pre-host-config/ } 0..$#testapi::commands;
    ok(defined $capture && defined $compare && $capture < $compare, "$flow captures post-state before comparison");
    ok(grep($_ eq '/tmp/post-host-state.txt', @testapi::uploads), "$flow uploads post-state");
    if ($flow eq 'host-ubuntu') {
        ok(grep(/wipefs .*\/dev\/vdb/, @testapi::commands), 'Ubuntu refusal probes the explicit target');
        ok(grep(/sfdisk -d \/dev\/vdb/, @testapi::commands), 'Ubuntu partition check probes the explicit target');
    }
    ok(!grep($_ eq 'power:reset', @testapi::commands), "$flow does not reboot the source host");
}

for my $flow ('host-arch', 'host-ubuntu') {
    %testapi::vars = (E2E_FLOW => $flow, E2E_TARGET_DISK => '/dev/vdb', E2E_INSTALLER => 'checkout');
    @testapi::commands = ();
    @testapi::uploads = ();
    local $testapi::fail_assert = qr{bash /tmp/host-state.sh post};
    my $ok = eval { host_install::run(undef); 1 };
    ok(!$ok, "$flow fails when post-install snapshot collection fails");
    like($@, qr{Guest command failed: bash /tmp/host-state.sh post}, 'snapshot failure is propagated');
    ok(!grep(m{/tmp/post-host-}, @testapi::uploads), 'failed snapshot is not uploaded as evidence');
    ok(!grep(/diff -u|power:/, @testapi::commands), 'failed snapshot stops comparison and shutdown');
}

{
    package boot;
    require './casedir/tests/boot.pm';
}
for my $flow ('live', 'offline') {
    %testapi::vars = (E2E_FLOW => $flow, E2E_INSTALLER => 'shipped');
    @testapi::commands = ();
    boot::run(undef);
    my ($shell) = grep { $testapi::commands[$_] eq "type:exec bash --norc\n" } 0..$#testapi::commands;
    my ($first_script) = grep { $testapi::commands[$_] eq 'stty cols 4096 rows 100' } 0..$#testapi::commands;
    ok(defined $shell && defined $first_script && $shell < $first_script,
        "$flow selects Bash before the backend shell handshake");
}

{
    require File::Temp;
    require Cwd;
    my $previous = Cwd::getcwd();
    my $temp = File::Temp::tempdir(CLEANUP => 1);
    chdir $temp or die $!;
    %testapi::vars = (OFFLINE_SUT => 1);
    @testapi::uploads = ();
    installer_base::collect_log('/tmp/dryrun.log');
    open my $fh, '<', 'ulogs/dryrun.log' or die $!;
    is(do {local $/; <$fh>}, "offline log\n", 'offline log bytes are saved over serial');
    close $fh;
    ok(!@testapi::uploads, 'offline evidence collection uses no HTTP upload');
    for my $output (
        Digest::SHA::sha256_hex("different bytes") . "  /tmp/dryrun.log\n"
            . MIME::Base64::encode_base64("offline log\n", ''),
        Digest::SHA::sha256_hex("offline log\n") . "  /tmp/dryrun.log\n"
            . MIME::Base64::encode_base64("offline", ''),
        "missing checksum\n" . MIME::Base64::encode_base64("offline log\n", ''),
    ) {
        local $testapi::output_override = $output;
        my $ok = eval { installer_base::collect_log('/tmp/dryrun.log'); 1 };
        ok(!$ok, 'corrupt serial transfer fails collection');
        like($@, qr{Corrupt serial log: /tmp/dryrun.log}, 'corrupt transfer reports its source');
        open my $saved, '<', 'ulogs/dryrun.log' or die $!;
        is(do {local $/; <$saved>}, "offline log\n", 'rejected transfer preserves existing evidence');
        close $saved;
    }
    chdir $previous or die $!;
}

{
    @testapi::commands = ();
    installer_base::shutdown_guest(1, 1);
    my @lifecycle = grep { /^(?:power:|shutdown-complete|eject)/ } @testapi::commands;
    is_deeply(\@lifecycle, ['power:acpi', 'shutdown-complete', 'eject', 'power:reset'],
        'live root keeps its ISO until shutdown completes, then boots the target');
}

done_testing();
