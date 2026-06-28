#!/usr/bin/perl

# api() version-clamp unit tests (issue #17).
#
# PVE's plugin loader DIES if a plugin's api() is greater than the host's APIVER,
# DIES if it is below APIVER-APIAGE, and WARNS if it differs from APIVER. So api()
# reports the host's own APIVER, capped at the newest version we have validated
# (HB_MAX_APIVER), and never reports higher than the host (which would be refused).
#
# As in blockdev.t we stub the PVE modules the plugin imports so the REAL plugin
# loads and the REAL api() runs; PVE::Storage::APIVER is made redefinable so each
# case can pretend to run on a different host.

use strict;
use warnings;

use Test::More;

# ── Minimal PVE stubs so HitachiBlockPlugin.pm compiles standalone ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { -1 }    # sentinel: must never be returned (real plugin overrides)
}
BEGIN {
    $INC{'PVE/JSONSchema.pm'} = 1;
    package PVE::JSONSchema;
    require Exporter;
    our @ISA       = ('Exporter');
    our @EXPORT_OK = ('get_standard_option');
    sub get_standard_option { return {} }
}
BEGIN {
    $INC{'PVE/Tools.pm'} = 1;
    package PVE::Tools;
    require Exporter;
    our @ISA       = ('Exporter');
    our @EXPORT_OK = ('run_command');
    sub run_command { die "run_command stub should not be called\n" }
}
BEGIN {
    # Redefinable host APIVER: set $HOST before each call.
    $INC{'PVE/Storage.pm'} = 1;
    package PVE::Storage;
    our $HOST;
    sub APIVER { return $HOST }
}

use lib 'src';
require_ok('PVE::Storage::Custom::HitachiBlockPlugin');

my $CLASS = 'PVE::Storage::Custom::HitachiBlockPlugin';

my $MIN = $CLASS->HB_MIN_APIVER;
my $MAX = $CLASS->HB_MAX_APIVER;
is($MIN, 9,  'HB_MIN_APIVER documented floor');
is($MAX, 14, 'HB_MAX_APIVER validated ceiling');
ok($MIN <= $MAX, 'min <= max');

# Helper: set the pretend host APIVER, capture any warning, return api().
sub api_on {
    my ($host) = @_;
    local $PVE::Storage::HOST = $host;
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my $v = $CLASS->api();
    return ($v, join('', @warns));
}

subtest 'within range -> mirrors host (no warning, no refusal)' => sub {
    for my $h ($MIN, 11, $MAX) {
        my ($v, $w) = api_on($h);
        is($v, $h, "host APIVER $h reported verbatim");
        is($w, '', "no warning at host APIVER $h");
    }
};

subtest 'above ceiling -> capped at HB_MAX_APIVER' => sub {
    my ($v, $w) = api_on($MAX + 1);
    is($v, $MAX, 'host newer than tested is capped to the validated ceiling');
    is($w, '', 'capping does not warn (loader will emit the upgrade advisory)');

    ($v) = api_on(99);
    is($v, $MAX, 'far-future host still capped to ceiling');

    # Critical safety property: we must never report higher than the host, or the
    # loader refuses us. Capping guarantees api() <= host for any host >= MAX.
    ok($v <= $MAX, 'capped value never exceeds the host APIVER');
};

subtest 'below floor -> mirrors host, never clamps UP (would break loading)' => sub {
    my $below = $MIN - 1;
    my ($v, $w) = api_on($below);
    is($v, $below, "host APIVER $below reported verbatim (not clamped up to $MIN)");
    ok($v <= $below, 'never reports higher than an old host (would be refused)');
    like($w, qr/below the validated floor/, 'warns that the host predates validation');
};

subtest 'undetectable host -> claims validated ceiling' => sub {
    my ($v, $w) = api_on(undef);
    is($v, $MAX, 'falls back to HB_MAX_APIVER when APIVER is unreadable');
    is($w, '', 'no warning on fallback');
};

done_testing();
