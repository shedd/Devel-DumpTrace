use Test::More tests => 18;
use strict;
use warnings;

# check output of Devel::DumpTrace module, compare with reference output.
# run code that uses a core module, and see if we are doing what
# we are supposed to about tracing through that core module

my $dmodule = "-d:DumpTrace::noPPI";

open T, '>', "$0.pl";
print T <<'EO_T;';

# test program for t/84-smoke.t, t/ppi/87-smoke.t
# assert that each %hash expression does not cause infinite loop
# v0.17 - include GLOB and CODE in the hash
%hash = (foo => 1, bar => *STDERR, baz => sub { 42 }, quux => 'xyz');
while ( my ($k,$v) = each %hash ) {
    exit 1 if length($y) > 1000;
    $y .= "$k,$v; ";
}

EO_T;

for my $level (1,2,3,4,5,103) {

    my $file = "$0.out.$level";
    $ENV{DUMPTRACE_FH} = $file;
    my $c1 = system($^X, "$dmodule=$level", "-Iblib/lib", "-Ilib", "$0.pl");

    my $keep = $ENV{KEEP} || 0;

    ok($c1 == 0, "ran level $level") or $keep++;

    open XH, '<', $file;
    my @xh = <XH>;
    close XH;

    ok( $xh[-1] !~ /exit/, 'last line was not exit' );
    ok( $xh[-1] =~ /\$y/ || $xh[-3] =~ /\$y/,
	'last line(s) referred to $y' );

    unlink $file unless $keep;
}
unlink "$0.pl";
