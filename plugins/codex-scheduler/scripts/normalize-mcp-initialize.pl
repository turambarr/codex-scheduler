use strict;
use warnings;
use JSON::PP ();

# The bundled SDK decodes experimental capabilities as strings. This service
# does not use them, so omit the block while preserving standard capabilities.
my $json = JSON::PP->new->utf8;
$| = 1;
binmode STDIN, ':raw';
binmode STDOUT, ':raw';
while (my $line = <STDIN>) {
    if ($line =~ /"method"\s*:\s*"initialize"/) {
        my $request = eval { $json->decode($line) };
        if (ref($request) eq 'HASH' && ($request->{method} // '') eq 'initialize'
                && ref($request->{params}) eq 'HASH'
                && ref($request->{params}->{capabilities}) eq 'HASH') {
            my $capabilities = $request->{params}->{capabilities};
            if (exists $capabilities->{experimental}) {
                delete $capabilities->{experimental};
                $line = $json->encode($request) . "\n";
            }
        }
    }
    print $line or die "Could not forward MCP input: $!";
}
