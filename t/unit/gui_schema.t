#!/usr/bin/perl

# GUI/schema drift guard (issue #9)
#
# The manager6 Web UI form (src/www/manager6/hitachiblock.js) should expose a
# control for every backend config property the plugin accepts. When a new
# property is added to options()/properties() in HitachiBlockPlugin.pm but not
# wired into the GUI, the create/edit dialog silently stops being a complete
# front-end for the schema (this is exactly how skip_unmap_io_check, then later
# rest_keepalive and lock_timeout, were missed).
#
# This test parses both source files textually (the plugin can't be `use`d here
# without the PVE framework) and fails if any accepted property has no matching
# `name:` field in the GUI, except for an explicit allow-list of keys handled by
# the PVE base storage edit panel (PVE.panel.StorageBase) rather than our module.

use strict;
use warnings;

use Test::More;
use FindBin qw($RealBin);

my $plugin_pm = "$RealBin/../../src/PVE/Storage/Custom/HitachiBlockPlugin.pm";
my $gui_js    = "$RealBin/../../src/www/manager6/hitachiblock.js";

# Keys accepted by the backend but intentionally NOT in the custom GUI module
# because PVE.panel.StorageBase / the framework provide them:
#   nodes, disable  -> rendered by StorageBase (Nodes + Enable controls)
# username/password/content/shared ARE in our module, so they are NOT here.
my %framework_handled = map { $_ => 1 } qw(nodes disable);

# ── Read both sources ──

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot open $path: $!";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

my $pm_src  = slurp($plugin_pm);
my $gui_src = slurp($gui_js);

# ── Extract the keys the backend accepts from options() ──
# options() is the authoritative list of config keys the plugin accepts. It is a
# flat hash of `key => { ... }`, one per line, so a line-anchored match is robust.

my ($options_body) = $pm_src =~ /sub\s+options\s*\{(.*?)\n\}/s
    or die "could not locate sub options() in $plugin_pm";

my @accepted = $options_body =~ /^\s*(\w+)\s*=>/mg;
ok(scalar(@accepted) > 0, 'parsed accepted keys from options()');

# ── Extract the field names the GUI references ──

my %gui_fields = map { $_ => 1 } ($gui_src =~ /\bname:\s*'([^']+)'/g);
ok(scalar(keys %gui_fields) > 0, 'parsed name: fields from the GUI module');

# ── Every accepted, non-framework key must have a GUI control ──

my @missing;
for my $key (@accepted) {
    next if $framework_handled{$key};
    push @missing, $key unless $gui_fields{$key};
}

is_deeply(\@missing, [],
    'every backend config property is exposed in the Web UI')
    or diag("Missing GUI controls for: @missing\n"
        . "Add a field with name: '<key>' to src/www/manager6/hitachiblock.js,\n"
        . "or add the key to %framework_handled in this test if PVE's base\n"
        . "storage panel provides it.");

# ── Sanity: the property this guard was created for is present ──
ok($gui_fields{skip_unmap_io_check},
    'skip_unmap_io_check (the original gap, issue #9) is exposed in the GUI');

done_testing();
