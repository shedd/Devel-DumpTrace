package main;

use Test::More;
BEGIN {
  if (eval "use PPI;1") {
    plan tests => 1;
  } else {
    plan skip_all => "PPI not available\n";
  }
}
use strict;
use warnings;
use Devel::DumpTrace::PPI;
use POSIX ();


Devel::DumpTrace::import_all();

$Devel::DumpTrace::DUMPTRACE_FH = *STDOUT;

my $status;
system($^X, "-e", "exit 4");

save_pads(0);
my $line = __LINE__ + 3;
evaluate_and_display_line('$status = $?;'."\n", __PACKAGE__, __FILE__, $line, '__top__');
$status = $?;
Devel::DumpTrace::handle_deferred_output('__top__', __FILE__);
ok(1);
