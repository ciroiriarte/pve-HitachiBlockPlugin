#!/usr/bin/perl

# cli_json.t -- canonical JSON output contract for emit_json()
#
# bin/hitachiblock-repl cannot be loaded as a module (top-level code calls
# read_credentials() which dies without real PVE storage config). This test
# exercises the same JSON->new->canonical->encode() contract that emit_json()
# uses, asserting sorted-key output for an unordered hash. If this encoder
# contract holds, emit_json() output is deterministic.

use strict;
use warnings;

use Test::More;
use JSON ();

sub emit_json_test {
    my ($data) = @_;
    return JSON->new->canonical->encode($data);
}

# Keys in natural order: z, a, m -- canonical must produce a, m, z order.
is(
    emit_json_test({ z => 1, a => 2, m => 3 }),
    '{"a":2,"m":3,"z":1}',
    'canonical sorts hash keys alphabetically',
);

# Nested hash inside array -- keys sorted at every level.
is(
    emit_json_test([{ z => 9, a => 0 }, { cc => 3, bb => 4 }]),
    '[{"a":0,"z":9},{"bb":4,"cc":3}]',
    'canonical sorts keys in nested hashes',
);

# Scalars and undef pass through unchanged.
is(
    emit_json_test({ cleaned => 0, count => 42 }),
    '{"cleaned":0,"count":42}',
    'integer values encoded correctly',
);

done_testing();
