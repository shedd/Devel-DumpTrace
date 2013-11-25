package Devel::DumpTrace::PPI;          ## no critic (FilenameMatchesPackage)

use Devel::DumpTrace;
use Devel::DumpTrace::Const;
use PadWalker;
use Scalar::Util;
use Data::Dumper;
use Carp;
use strict;
use warnings;

# functions in this file that override functions in Devel/DumpTrace.pm

*Devel::DumpTrace::get_source = *get_source_PPI;
*Devel::DumpTrace::evaluate_and_display_line = *evaluate_and_display_line_PPI;
*Devel::DumpTrace::handle_deferred_output = *handle_deferred_output_PPI;

*evaluate = *Devel::DumpTrace::evaluate;
*current_position_string = *Devel::DumpTrace::current_position_string;

local $| = 1;

croak "Devel::DumpTrace::PPI may not be used when \$Devel::DumpTrace::NO_PPI ",
        "is set (Did you load 'Devel::DumpTrace::noPPI'?\n"
    if $Devel::DumpTrace::NO_PPI;
eval {use PPI;
      1}
  or croak "PPI not installed. Can't use Devel::DumpTrace::PPI module";

$Devel::DumpTrace::PPI::VERSION = '0.18';
use constant ADD_IMPLICIT_ => 1;
use constant DECORATE_FOR => 1;
use constant DECORATE_FOREACH => 1;
use constant DECORATE_WHILE => 1;
use constant DECORATE_ELSIF => 1;

# built-in functions that may use $_ implicitly
my %implicit_
    = (abs=>1, alarm=>1, chomp=>1, chop=>1, chr=>1, chroot=>1, cos=>1,
       defined=>1, eval=>1, exp=>1, glob=>1, hex=>1, int=>1, lc=>1,
       lcfirst=>1, length=>1, log=>1, lstat=>1, mkdir=>1, oct=>1, ord=>1,
       pos=>1, print=>1, quotemeta=>1, readlink=>1, readpipe=>1, ref=>1,
       require=>1, reverse=>1, rmdir=>1, sin=>1, split=>1, sqrt=>1, stat=>1,
       study=>1, uc=>1, ucfirst=>1, unlink=>1, unpack=>1,);

# for persisting the PPI documents we create
my (%ppi_src, %ppi_doc);

my $last_file_sub_displayed = '';
my $last_file_line_displayed = '';
my %IGNORE_FILE_LINE = ();

sub Devel::DumpTrace::PPI::import {
    foreach my $PPI_package (grep { m{^PPI[/.]} } keys %INC) {
	$PPI_package =~ s/\.pm$//;
	$PPI_package =~ s{/}{::}g;
	$Devel::DumpTrace::EXCLUDE_PKG{$PPI_package} = 1;
    }
    $Devel::DumpTrace::EXCLUDE_PKG{"Carp::Always"} = 1;
    goto &Devel::DumpTrace::import;
}

# Overrides &get_source in Devel/DumpTrace.pm
sub get_source_PPI {
    my ($file, $line) = @_;

    if (!defined $ppi_src{$file}) {
	eval { _update_ppi_src_for_file($file) };
    }
    return \@{$ppi_src{$file}[$line]};
}

sub _update_ppi_src_for_file {
    my $file = shift;

    my $doc;
    if ($file eq '-e'                       # code from  perl -e '...'
	|| $file eq '-'                     # code from  cat prog.pl | perl
	|| $file =~ /^\(eval \d+\)\[/) {    # code from an eval statement
	no strict 'refs';                     ## no critic (NoStrict)
	my $all_code = join "", @{"::_<$file"}[1 .. $#{"::_<$file"}];
	$doc = $ppi_doc{$file} = PPI::Document->new(\$all_code);
    } else {
	$doc = $ppi_doc{$file} = PPI::Document->new($file);
    }
    $doc->index_locations;

    # find every separate statement in the document
    # and store by its line number.

    # there may be more than one distinct statement per line ($a=4; $b=6;)
    # but statements that are children of other statements should not
    # be included ... ( if ($cond) { $x++ }\n   ===>   don't store  $x++ )

    my $statements = $doc->find('PPI::Statement') || [];
    foreach my $element (@$statements) {
	my $_line = $element->line_number;
	__decorate1($element, $file);
	next if _element_has_ancestor_on_same_line($element,$_line);
	__decorate2($element, $file);
	_update_ppi_src_for_element($element, $file, $_line);
    }
    return;
}

sub _element_has_ancestor_on_same_line {
    my ($element,$_line) = @_;
    #my $_line = $element->line_number;
    my $parent = $element->parent;
    while ($parent && ref($parent) ne 'PPI::Document') {
	my $parent_line = $parent->line_number;
	if (defined($parent_line) 
	    && $parent_line == $_line
	    && ref($parent) =~ /^PPI::Statement/) {
	    return 1;
	}
	$parent = $parent->parent;
    }
    return 0;
}

sub _update_ppi_src_for_element {
    my ($element, $file, $_line) = @_;
    # my $_line = $element->line_number;
    $ppi_src{$file}[$_line] ||= [];
    if (ref($element) =~ /^PPI::Statement/) {
	my ($d1, $d2) = (0,0);
	my @zrc = _get_source($file, $_line, $element, $d1, $d2);
	my $elem = { %$element };
	$elem->{children} = [ @zrc ];
	push @{$ppi_src{$file}[$_line]}, bless $elem, ref $element;
    } else {
	push @{$ppi_src{$file}[$_line]}, $element;
    }
}

# decorate 
sub __decorate1 {
    my ($element, $file) = @_;
    if (ADD_IMPLICIT_) {
	__add_implicit_elements($element);
	if (ref($element) eq 'PPI::Statement::Given') {
	    __add_implicit_to_given_when_blocks($element);
	}
    }
    __decorate_first_statement_in_for_block($element, $file);
    __decorate_first_statement_in_foreach_block($element, $file);
    return;
}

sub __decorate2 {
    my ($element, $file) = @_;
    __remove_whitespace_and_comments_just_before_end_of_statement($element);
    __decorate_first_statement_in_while_block($element, $file);
    __decorate_statements_in_ifelse_block($element, $file);
    __decorate_last_statement_in_dowhile_block($element, $file);
    return;
}

# extract source from a compound statement that goes with the
# specified line. This involves removing tokens that appear on
# other lines AFTER a block opening ("{") has been observed.
sub _get_source {
    my ($file, $line, $node, undef, undef, @src) = @_;
    my @children = $node->elements;

    for my $element (@children) {
	if (defined($element->line_number) && $element->line_number != $line) {
	    $_[3]++;
	}
	last if $_[3] && $_[4];
	if ($element->first_token ne $element) {
	    my @zrc = _get_source($file, $line, $element, $_[3], $_[4]);
	    push @src, bless( { children=>[@zrc] }, ref($element) );
	} else {
	    push @src, $element;
	}
	if (ref $element eq 'PPI::Token::Structure' && $element eq '{') {
	    $_[4]++;
	}
    }
    return @src;
}

sub _get_decorated_statements {

    # Many Perl flow control constructs are optimized to not
    # allow a breakpoint at each iteration of a loop or at each
    # condition evaluation of a complex if-elsif-else statement.
    # So there are times when, while evaluating the first statement
    # in a block, we also want to evaluate some other expressions
    # from the parent flow control structure.

    my ($statements, $style) = @_;
    my @s = @{$statements};
    foreach my $ss (grep { $_->{__DECORATED__} } @{$statements}) {
	my $ws = $style == DISPLAY_TERSE ? "\n\t\t\t" : " ";

	if ($ss->{__DECORATED__} eq 'foreach'
	    && $last_file_line_displayed ne $ss->{__FOREACH_LINE__}) {

	    unshift @s, 
	        __new_token('FOREACH: {'),
	        $ss->{__UPDATE__},
	        __new_token("} \t");    # don't use newline even in terse mode
	    
	} elsif ($ss->{__DECORATED__} eq 'for'
		 && $last_file_line_displayed ne $ss->{__FOR_LINE__}) {

	    unshift @s, __new_token("FOR-UPDATE: {"), $ss->{__CONTINUE__},
	        __new_token(" } FOR-COND: {"), $ss->{__CONDITION__},
	        __new_token(" }" . $ws);

	} elsif ($ss->{__DECORATED__} eq 'while/until'
		 && $last_file_line_displayed ne $ss->{__WHILE_LINE__}) {
	    unshift @s, 
	        __new_token($ss->{__BLOCK_NAME__} . ": "), 
	        $ss->{__CONDITION__}, __new_token(" " . $ws);
	} elsif ($ss->{__DECORATED__} eq 'if-elsif-else'
		 && $last_file_line_displayed eq $ss->{__IF_LINE__}) {

	    unshift @s, @{$ss->{__CONDITIONS__}}, __new_token(" ". $ws);
	} elsif ($ss->{__DECORATED__} eq 'do-while'
		 && $last_file_line_displayed ne $ss->{__DOWHILE_LINE__}) {
	    push @s, __new_token(" " . $ws),
	        __new_token($ss->{__SENSE__} . ": {"),
	        @{$ss->{__CONDITION__}},
	        __new_token("}");
	}
    }
    return @s;
}

# Overrides &evaluate_and_display_line in Devel/DumpTrace.pm
sub evaluate_and_display_line_PPI {
    my ($statements, $pkg, $file, $line, $sub) = @_;

    if (ref $statements ne 'ARRAY') {
	my $doc = PPI::Document->new(\$statements);
	$ppi_doc{"$file:$line"} = $doc;
	$statements = [$doc->elements];
    }

    my $style = Devel::DumpTrace::_display_style();
    my $code;
    my @s = _get_decorated_statements($statements, $style);
    $code = join '', map { "$_" } @s;
    chomp $code;
    $code .= "\n";
    $code =~ s/\n(.)/\n\t\t $1/g;

    my $fh = $Devel::DumpTrace::DUMPTRACE_FH;
    if ($style > DISPLAY_TERSE) {
	Devel::DumpTrace::separate();
	print {$fh} ">>    ", current_position_string($file,$line,$sub), "\n";
	print {$fh} ">>>   \t\t $code";
	unless ($IGNORE_FILE_LINE{"$file:$line"}) {
	    $last_file_sub_displayed = "$file:$sub";
	    $last_file_line_displayed = "$file:$line";
	}
    }

    my $xcode;
    my @preval = ();

    # for a simple lexical declaration with no assignments,
    # don't evaluate the code:
    #           my ($a, @b, %c);
    #           our $ZZZ;
    # XXX - these expressions lifted from Devel::DumpTrace. Is that
    #       sufficient or should we analyze the PPI tokens?
    if ($code    =~ /^ \s* (my|our) \s*
                       [\$@%*\(] /x           # lexical declaration
	&& $code =~ / (?<!;) .* ;
                      \s* (\# .* )? $/x      # single statement, single line
	&& $code !~ /=/) {                   # NOT an assignment

	$xcode = $code;

    } else {

	# recursive preval calls will increase the depth levels
	local $Devel::DumpTrace::DB_ARGS_DEPTH = 4;

	for my $s (@s) {
	    push @preval, preval($s, $style, $pkg);
	}
	$xcode = join '', @preval;
    }

    chomp $xcode;
    $xcode .= "\n";
    $xcode =~ s/\n(.)/\n\t\t $1/g;

    if ($style >= DISPLAY_GABBY && $xcode ne $code) {
	print {$fh} ">>>>  \t\t $xcode";
    }
    my $deferred = 0;
    for my $preval (@preval) {
	if (ref $preval) {

	    $deferred++;
	    $Devel::DumpTrace::DEFERRED{"$sub : $file"} ||= [];
	    push @{$Devel::DumpTrace::DEFERRED{"$sub : $file"}},
	        { EXPRESSION => [ @preval ],
		  PACKAGE    => $pkg,
		  MY_PAD     => $Devel::DumpTrace::PAD_MY,
		  OUR_PAD    => $Devel::DumpTrace::PAD_OUR,
		  SUB        => $sub,
		  FILE       => $file,
		  LINE       => $line,
		  DISPLAY_FILE_AND_LINE => $style <= DISPLAY_TERSE,
		};
	    last;
	}
    }
    if ($deferred == 0) {
	if ($style > DISPLAY_TERSE) {
	} else {
	    print {$fh} ">>>   ", 
	        current_position_string($file,$line,$sub),
	        "\t$xcode";
	    unless ($IGNORE_FILE_LINE{"$file:$line"}) {
		$last_file_sub_displayed = "$file:$sub";
		$last_file_line_displayed = "$file:$line";
	    }
	}
    }
    return;
}

# any elements that appear AFTER the last assignment operator
# are evaluated and tokenized.
sub preval {
    my ($statement,$style,$pkg) = @_;
    if (ref($statement) =~ /PPI::Token/) {
	if ($statement->{_PREVAL}) {
	    perform_variable_substitution($statement, 0, $style, $pkg)
      		unless $statement->{_DEFER};
	    return map { ref($_) eq 'ARRAY' ? @{$_} : $_ } $statement;
	} else {
	    return map {"$_"} $statement->tokens;
	}
    }
    $Devel::DumpTrace::DB_ARGS_DEPTH++;

    if (ref($statement) !~ /^PPI::/) {
	Carp::confess "$statement is not a PPI token -- ", %$statement,
	    "\nThis is a bug. Report to bug-Devel-DumpTrace\@rt.cpan.org\n";
    }

    my @e = $statement->elements;

    # look for implicit uses of special vars
    if (ADD_IMPLICIT_) {
	__append_implicit_to_naked_shift_pop(\@e);
    }

    # find last assignment operator in this expression, if any.
    my $lao_index = 0;
    for my $i (0 .. $#e) {
	if (ref($e[$i]) eq 'PPI::Token::Operator'
	    && $e[$i]->is_assignment_operator) {
	    $lao_index = $i;
	}
    }
    _preval_render(\@e, $lao_index, $style, $pkg);
    my @output = map { ref($_) eq 'ARRAY' ? @{$_} : $_ } @e;
    $Devel::DumpTrace::DB_ARGS_DEPTH--;
    return @output;
}

sub _preval_render {

    # evaluate any PPI::Token::Symbol elements after element $z
    # tokenize other PPI::Token::* elements
    # pass other elements back to &preval recursively

    my ($e, $lao_index, $style, $pkg) = @_;
    $Devel::DumpTrace::DB_ARGS_DEPTH++;
    for (my $i=$lao_index; $i < @$e; $i++) {
	if (ref($e->[$i]) eq 'PPI::Token::Symbol') {
	    next if $e->[$i]{_DEFER};
	    perform_variable_substitution(@$e, $i, $style, $pkg);
	    if ($i > 0 && ref($e->[$i-1]) eq 'PPI::Token::Cast') {
		if ($e->[$i-1] eq '@' && $e->[$i] =~ /^\[(.*)\]$/) {

		    # @$a => @[1,2,3]   should render as   @$a => (1,2,3)

		    $e->[$i-1] = '';
		    $e->[$i] = '(' . substr($e->[$i],1,-1) . ')';
		} elsif ($e->[$i-1] eq '%' && $e->[$i] =~ /^\{(.*)\}$/) {

		    # render  %$a  as  ('a'=>1;'b'=>2) , not  %{'a'=>1;'b'=>2}

		    $e->[$i-1] = '';
		    $e->[$i] = '(' . substr($e->[$i],1,-1) . ')';
		}
	    }
	} elsif (ref $e->[$i] eq 'PPI::Token::Magic') {
	    next if $e->[$i]{_DEFER};
	    perform_variable_substitution(@$e, $i, $style, '<magic>');
	} elsif (ref($e->[$i]) =~ /PPI::Token/) {
	    $e->[$i] = "" . $e->[$i] if ref($e->[$i]) ne 'PPI::Token::Cast';
	} else {
	    $e->[$i] = [ preval($e->[$i],$style,$pkg) ];
	}
    }
    $Devel::DumpTrace::DB_ARGS_DEPTH--;
    return;
}

sub perform_variable_substitution_on_tokens {
    # needed to evaluate complex lvalues
    my ($elem, $style, $dpkg) = @_;
    my @out = ();
    my $ref = ref($elem);
    if ($ref =~ /^PPI::Statement/ || $ref =~ /^PPI::Structure/) {
	foreach my $e ($elem->elements()) {
	    $Devel::DumpTrace::DB_ARGS_DEPTH++;
	    push @out, 
	        perform_variable_substitution_on_tokens($e, $style, $dpkg);
	    $Devel::DumpTrace::DB_ARGS_DEPTH--;
	}
    } elsif ($ref eq 'PPI::Token::Symbol') {
	my @e = ($elem);
	perform_variable_substitution(@e, 0, $style, $dpkg);
	@out = "$e[0]";
    } elsif ($ref eq 'PPI::Token::Magic') {
	my @e = ($elem);
	perform_variable_substitution(@e, 0, $style, '<magic>');
	@out = "$e[0]";
    } else {
	@out = "$elem";
    }
    return join '', @out;
}

# Overrides &handle_deferred_output in Devel/DumpTrace.pm
sub handle_deferred_output_PPI {

    my ($sub, $file) = @_;
    my $deferred = pop @{$Devel::DumpTrace::DEFERRED{"$sub : $file"}};
    return unless defined($deferred);

    my $fh = $Devel::DumpTrace::DUMPTRACE_FH;
    my @e = @{$deferred->{EXPRESSION}};
    my $undeferred_output = join '', @e;
    my $deferred_pkg = $deferred->{PACKAGE};
    $Devel::DumpTrace::PAD_MY = $deferred->{MY_PAD};
    $Devel::DumpTrace::PAD_OUR = $deferred->{OUR_PAD};
    Devel::DumpTrace::refresh_pads();

    my $style = Devel::DumpTrace::_display_style();
    for my $i (0 .. $#e) {
	if (ref $e[$i] eq 'PPI::Token::Symbol') {
	    perform_variable_substitution(@e, $i, $style, $deferred_pkg);
	} elsif (ref $e[$i] eq 'PPI::Token::Magic') {
	    perform_variable_substitution(@e, $i, $style, '<magic>');
	} elsif (ref $e[$i] eq 'PPI::Token::Cast') {
	    eval { $e[$i] = "$e[$i]"; };
	} elsif (ref($e[$i]) =~ /^PPI::/) {
	    $Devel::DumpTrace::DB_ARGS_DEPTH++;
	    $e[$i] = perform_variable_substitution_on_tokens(
		$e[$i],$style,$deferred_pkg);
	    $Devel::DumpTrace::DB_ARGS_DEPTH--;
	}
    }
    my $deferred_output = join '', @e;
    chomp($undeferred_output,$deferred_output);
    $undeferred_output .= "\n";
    $undeferred_output =~ s/\n(.)/\n\t\t $1/g;
    $deferred_output .= "\n";
    $deferred_output =~ s/\n(.)/\n\t\t $1/g;
    my $line = $deferred->{LINE};
    $file = $deferred->{FILE};
    $sub = $deferred->{SUB};
    if ($deferred->{DISPLAY_FILE_AND_LINE}
	|| "$file:$sub" ne $last_file_sub_displayed) {

	if (Devel::DumpTrace::_display_style() > DISPLAY_TERSE) {
	    Devel::DumpTrace::separate();
	    print {$fh} ">>>>  ", 
	        current_position_string($file,$line,$sub), "\n";
	    print {$fh} ">>>> \t\t $undeferred_output";
	    print {$fh} ">>>>>\t\t $deferred_output";
	} else {
	    print {$fh} ">>>>> ", 
	        current_position_string($file,$line,$sub),
	        "\t$deferred_output";
	}
    } else {
	print {$fh} ">>>>>\t\t $deferred_output";
    }
    unless ($IGNORE_FILE_LINE{"$file:$line"}) {
	$last_file_sub_displayed = "$file:$sub";
	$last_file_line_displayed = "$file:$line";
    }
    return;
}

sub perform_variable_substitution {
    my $pkg = pop @_;
    my $style = pop @_;
    my $i = pop @_;

    my $sigil = substr $_[$i], 0, 1;
    return if $sigil eq '&' || $sigil eq '*';
    my $varname = substr $_[$i], 1;
    $varname =~ s/^\s+//;
    $varname =~ s/\s+$//;
    my $deref_op = '';
    my $index_op = '';
    my @keys;

    my $j = $i+1;
    while ($j < @_ && ref($_[$j]) eq 'PPI::Token::Whitespace') {
	$j++;
    }
    if (ref($_[$j]) eq 'PPI::Token::Operator' && $_[$j] eq '->') {
	$deref_op = '->';
	$j++;
	while ($j < @_ && ref $_[$j] eq 'PPI::Token::Whitespace') {
	    $j++;
	}
    }
    if (ref($_[$j]) =~ /^PPI::Structure::/) {
	my @t = $_[$j]->tokens();
	if ($t[0] eq '[') {
	    $index_op = '[';
	    push @keys, evaluate_subscript($pkg,@t);
	} elsif ($t[0] eq '{') {
	    $index_op = '{';
	    push @keys, evaluate_subscript($pkg,@t);
	}
    }

    $_[$i] = evaluate($sigil,$varname,$deref_op,$index_op, $pkg, @keys);
    $_[$i] =~ s/[\[\{]$//;
    $_[$i] =~ s/\-\>$//;
    if ($style < DISPLAY_GABBY) {
	$_[$i] = "$sigil$varname$Devel::DumpTrace::XEVAL_SEPARATOR" . $_[$i];
    }
    return $_[$i];
}

sub evaluate_subscript {
    my ($pkg, @tokens) = @_;

    my $abbrev_style = Devel::DumpTrace::_abbrev_style();
    if ($abbrev_style != ABBREV_SMART && $abbrev_style != ABBREV_MILD_SM) {
	return ();
    }

    shift @tokens;
    pop @tokens;

    for (my $i=0; $i<@tokens; $i++) {
	if (ref $tokens[$i] eq 'PPI::Token::Symbol') {
	    my $y0 = $tokens[$i];
	    my $y1 = perform_variable_substitution(
		@tokens, $i, DISPLAY_GABBY, $pkg);
	}
    }

    my $ref = join ' ', map { ref($_), ref(\$_) } @tokens;
    my $key;

    # don't evaluate expressions that may have side-effects
    #    Any PPI::Token::Symbol's left are probably function calls
    #    PPI::Token::Word could be function calls
    #    Avoid expressions with assignment, postfix operators
    #    Typeglobs won't get eval'd well
    #    actually, any tied variable can have side effects (through FETCH, e.g.)

    return if $ref =~ /PPI::Token::Symbol/;
    return if $ref =~ /PPI::Token::Word/;
    return if $ref =~ /GLOB/;

    my $expr = join '', @tokens;

    return if $expr =~ /=/;
    return if $expr =~ /\+\+/;
    return if $expr =~ /--/;

    $key = eval $expr;

    if ($@ || !defined $key) {
	return;
    } else {
	return ($key);
    }
}

sub PPI::Token::Operator::is_assignment_operator {
    my $op = $_[0]->{content};
    for my $aop (qw(= += -= *= /= %= &= |= ^= .= x=
		    **= &&= ||= //= <<= >>= ++ --)) {
	return 1 if $op eq $aop;
    }
    return;
}

# 0.07: If a statement ends with whitespace and/or comments before the
#       ';' token, remove them for appearances sake.
sub __remove_whitespace_and_comments_just_before_end_of_statement {
    my $element = shift;
    my @tokens = $element->tokens();
    return if @tokens <= 3
	|| ref($tokens[-1]) ne 'PPI::Token::Structure'
	|| $tokens[-1] ne ';';

    my $j = -2;
    while (defined($tokens[$j]) 
	   && (ref($tokens[$j]) eq 'PPI::Token::Whitespace' 
	       || ref($tokens[$j]) eq 'PPI::Token::Comment'
	       || ref($tokens[$j]) eq 'PPI::Token::POD')) {
	$j--;
    }
    if ($j < -3 && defined($tokens[$j])) {
	for my $k ($j+1 .. -1) {
	    $tokens[$k]->delete();
	}
    }
    return;
}

sub __add_implicit_elements {
    my ($statement) = @_;

    my $e = $statement->{children};
    __prepend_implicit_to_naked_regexp($e);
    __append_implicit_to_naked_filetest($e);
    __append_implicit_to_naked_builtins($e);
    __insert_implicit_into_default_foreach($e);
    return;
}

sub __prepend_implicit_to_naked_regexp {
    my $e = shift;

    #
    # /pattern/    means    $_ =~ /pattern/
    #
    for (my $i = 0; $i < @$e; $i++) {
	next unless ref($e->[$i]) =~ /^PPI::Token::Regexp/;
	my $j = $i-1;
	$j-- while $j >= 0 && ref($e->[$j]) eq 'PPI::Token::Whitespace';
	if ($j < 0 || ref($e->[$j]) ne 'PPI::Token::Operator'
	    || ($e->[$j] ne '=~' && $e->[$j] ne '!~')) {

	    splice @$e, $i, 0,
	    bless( { content => '$_' }, 'PPI::Token::Magic' ),
	    bless( { content => '=~' }, 'PPI::Token::Operator' );
	}
    }
    return;
}

sub __append_implicit_to_naked_filetest {
    my $e = shift;

    #
    # bare  -X   means    -X $_   (except for -t)
    # 
    for (my $i=0; $i<@$e; $i++) {
	if (ref $e->[$i] eq 'PPI::Token::Operator'
	    && $e->[$i] =~ /^-[a-su-zA-Z]$/) {
	    my $j = $i + 1;
	    while ($j <= @$e && ref($e->[$j]) eq 'PPI::Token::Whitespace') {
		$j++;
	    }
	    if ($j >= @$e || ref($e->[$j]) eq 'PPI::Token::Operator'
		|| ref($e->[$j]) eq 'PPI::Token::Structure') {
		splice @$e, $i+1, 0,
		bless( { content=>' ' }, 'PPI::Token::Whitespace' ),
		bless( { content=>'$_' }, 'PPI::Token::Magic' );
	    }
	}
    }
    return;
}

sub __append_implicit_to_naked_builtins {
    my $e = shift;

    #
    # for many builtin functions (print, sin, log, ...)
    #
    # func;    means   func($_);
    #
    #
    # 0.12: but       $hash{bareword} 
    # should not be   $hash{bareword $_}
    #
    for (my $i=0; $i<@$e; $i++) {
	if (ref($e->[$i]) eq 'PPI::Token::Word' 
	    && defined $implicit_{"$e->[$i]"}) {
	    my $j = $i + 1;
	    my $gparent = $e->[$i]->parent && $e->[$i]->parent->parent;
	    next if $gparent && ref($gparent) eq 'PPI::Structure::Subscript'
		&& $gparent =~ /^{/;
	    $j++ while $j <= @$e && ref($e->[$j]) eq 'PPI::Token::Whitespace';
	    if ($j >= @$e || ref($e->[$j]) eq 'PPI::Token::Structure') {
		if ($e->[$i] eq 'split') {
		    # naked  split  is parsed as  split /\s+/, $_
		    splice @$e, $i+1, 0,
		        bless({content=>' '}, 'PPI::Token::Whitespace'),
		        bless({content=>'m/\\s+/'},
			      'PPI::Token::Regexp::Match'),
		        bless({content=>','}, 'PPI::Token::Operator'),
			# XXX - why _DEFER => 1 here ???
#	                bless({content=>'$_', _DEFER => 1}, 
#		               'PPI::Token::Magic');
		        bless({content=>'$_'}, 'PPI::Token::Magic');
		} else {
		    splice @$e, $i+1, 0,
		        bless({content=>' '}, 'PPI::Token::Whitespace'),
#	                bless({content=>'$_', _DEFER => 1}, 
#			      'PPI::Token::Magic');
		        bless({content=>'$_'}, 'PPI::Token::Magic');
		}
	    }
	}
    }
    return;
}

sub __insert_implicit_into_default_foreach {
    my $e = shift;

    # for (LIST)        means    for $_ (LIST)

    for (my $i=0; $i<@$e; $i++) {
	next unless ref($e->[$i]) eq 'PPI::Token::Word'
	    && ($e->[$i] eq 'for' || $e->[$i] eq 'foreach');

	my $j = $i + 1;
	$j++ while $j < @$e && ref($e->[$j]) eq 'PPI::Token::Whitespace';
	if ($j < @$e && ref($e->[$j]) eq 'PPI::Structure::List') {

	    splice @$e, $i+1, 0,
	        bless({content=>' '}, 'PPI::Token::Whitespace'),
	        bless({content=>'$_', _DEFER => 1}, 'PPI::Token::Magic');

	}
    }
    return;
}

sub __append_implicit_to_naked_shift_pop {
    #
    # look for use of implicit @_/@ARGV with shift/pop.
    #
    # This cannot be done when the document is initially parsed
    # (in &__add_implicit_elements, for example) because
    # we can only definitively determine whether or not we
    # are inside a subroutine at runtime.
    #
    my $e = shift;
    for (my $i=0; $i<@$e; $i++) {
	next if ref($e->[$i]) ne 'PPI::Token::Word';
	next if $e->[$i] ne 'shift' && $e->[$i] ne 'pop';

	my $j = $i + 1;
	while ($j <= @$e && ref($e->[$j]) eq 'PPI::Token::Whitespace') {
	    $j++;
	}
	if ($j >= @$e || ref($e->[$j]) eq 'PPI::Token::Operator'
	    || ref($e->[$j]) eq 'PPI::Token::Structure') {

	    # found naked pop/shift. Determine if we are inside a sub
	    # so we know whether to apply @ARGV or @_.
	    my $n = 0;
	    my $xp = 0;
	    while (my @p = caller($n++)) {
		$xp += $p[CALLER_PKG] !~ /^Devel::DumpTrace/ &&
		    $p[CALLER_SUB] !~ /^\(eval/;
	    }

	    if ($xp >= 2) { # inside sub, manip @_
		splice @$e, $i+1, 0,
		    bless({content=>' '}, 'PPI::Token::Whitespace'),
		    bless({content=>'@_'}, 'PPI::Token::Magic');
	    } else {        # not inside sub, manip @ARGV
		splice @$e, $i+1, 0,
		    bless({content=>' '}, 'PPI::Token::Whitespace'),
		    bless({content=>'@ARGV'}, 'PPI::Token::Symbol');
	    }
	}
    }
}

sub __add_implicit_to_given_when_blocks {

    # given($foo)
    #    when($bar)     means     when ($foo ~~ $bar)
    #    when(\@list)   means     when ($foo ~~ \@list)
    #    when(&func)    means     ???
    #    when(\&func)   means     when (&func($foo))
    #    when(m/patt/)  means     when ($foo ~= m/patt/)
    #    when($a <=> cmp $b) means  what it says
    #    when(defined ... exists ... eof)    means what it says
    #    when(!something) means   what it says
    #    when(-X file)  means what it says for X not in {sMAC}
    #    when(flip..flop) means   what it says


    # there are probably a lot of incorrect edge cases,
    # but this is a good start



    my $given = shift;

    # what to do with a given block:
    #     extra token(s) from child PPI::Structure::Given
    #         extract structure tokens from front,back
    #         this becomes the _given_ expression
    #     find child PPI::Structure::Block
    #     find grandchild PPI::Statement::When
    #     find greatgrandchild PPI::Structure::When
    #         analyze PPI::Structure::When element
    #             if there is an "implicit smart match",
    #             insert  << $_ ~~ >>  at the beginning of the struct
    my $given_child = $given->find('PPI::Structure::Given') or next;
    my $given_expr 
	= $given_child->[0]->find('PPI::Statement::Expression') or next;

    my $given_tok = join '', $given_expr->[0]->tokens;

    my $whens = $given->find('PPI::Statement::When') || [];
    foreach my $when (@$whens) {
	if ($when->parent->parent ne $given) {
	    next;
	}
	my $structure = $when->find('PPI::Structure::When');
	unless ($structure) {
	    next;
	}
	$structure = $structure->[0];
	
	my $when_expr = $structure->find('PPI::Statement::Expression');
	unless ($when_expr) {
	    $when_expr = $structure->find('PPI::Statement');
	    next unless $when_expr;
	}
	my $first_when_expr = $when_expr->[0];
	my $is_implicit_smart_match = 0;

	my @e = $first_when_expr->elements();

	if (ref($e[0]) eq 'PPI::Token::Word'
	    || ref($e[0]) =~ /PPI::Token::Quote::/) {

	    $is_implicit_smart_match = 2;

	    if ($e[0] eq 'defined' || $e[0] eq 'exists' || $e[0] eq 'eof') {
		$is_implicit_smart_match = 0;
	    }

	} elsif (ref($e[0]) eq 'PPI::Structure::Constructor'
		 && $e[0] =~ /^\[/) {

	    $is_implicit_smart_match = 3;

	} elsif (@e == 1 && 
		 (ref($e[0]) eq 'PPI::Token::Symbol' ||
		  ref($e[0]) eq 'PPI::Token::Magic' ||
		  ref($e[0]) =~ 'PPI::Token::Number')) {

	    $is_implicit_smart_match = 1;

	} elsif (ref($e[0]) eq 'PPI::Token::Cast' && $e[0] eq '\\'
		 && ref($e[1]) =~ /PPI::Token::(Symbol|Magic)/
		 && $e[1] !~ /[&*]/) {

	    $is_implicit_smart_match = 4;

	}

	for (my $i=0; $i<@e; $i++) {
	    my $e = $e[$i];

	    if (ref($e) =~ /Operator/
		&& ($e eq '<' || $e eq '>' || $e eq '==' ||
		    $e eq '<=' || $e eq '>=' || $e eq 'le' || $e eq 'ge' ||
		    $e eq 'lt' || $e eq 'gt' || $e eq 'eq' || $e eq 'ne' ||
		    $e eq '<=>' || $e eq 'cmp' || $e eq '!' || $e eq 'not' ||
		    $e eq '^' || $e eq 'xor' || $e eq '~~' || $e eq '..')) {

		$is_implicit_smart_match = 0;
		last;
	    } elsif (ref($e) =~ /::Regexp/) {

		$is_implicit_smart_match = 0;
		last;
	    } elsif (ref($e) eq 'PPI::Token::Cast' && $e eq '\\'
		     && ref($e[$i+1]) eq 'PPI::Token::Symbol'
		     && $e[$i+1] =~ /^&/) {

		$is_implicit_smart_match = 0;
		last;
	    } elsif (ref($e) =~ /Operator/
		     && ($e eq '||' || $e eq '&&' || $e eq '//' ||
			 $e eq 'or' || $e eq 'and')) {

		# these operators make it ambiguous whether an implicit
		# smart match is being used. Disable for now and the task
		# of making this more sophisticated will go on the todo list.

		$is_implicit_smart_match = 0;

	    }
			 
	}

	if ($is_implicit_smart_match) {
	    my $elem = $first_when_expr->{children};
	    my $location = $elem->[0]->location;

	    unshift @$elem,
	        bless( { content => '$_', _location => $location }, 
		       'PPI::Token::Magic' ),
	        bless( { content => '~~', _location => $location },
		       'PPI::Token::Operator');
	    $first_when_expr->{children} = $elem;
	}
    }
    return;
}

# A C-style for-loop has the structure:
#     for (INIT ; CONDITION ; CONTINUE) BLOCK
#
# The CONDITION expression (and sometimes the CONTINUE) expression sure
# would be interesting to see while you are tracing through a program.
# Unfortunately, DB::DB will typically only get called at the very
# start of the loop.
#
# One workaround might be to prepend the for statement to the
# source code associated with the first statement in the BLOCK.
# That way, each time a new iteration starts, you would get
# the chance to observe the CONDITION and CONTINUE expressions.
#
sub __decorate_first_statement_in_for_block {

    # We expect a particular pattern of PPI code to describe the
    # "first statement in the block of a C-style for-loop":
    #
    # PPI::Statement::Compound                     $gparent
    #   PPI::Token::Word (for/foreach)
    #   zero of more PPI::Token::Whitespace
    #   PPI::Structure::For                        $for
    #     ...
    #   zero or more PPI::Token::Whitespace
    #   PPI::Structure::Block                      $parent
    #     zero or more PPI::Token::xxx
    #     PPI::Statement::xxx                      $element
    #
    return unless DECORATE_FOR;

    my ($element, $file) = (@_);
    return if ref($element) !~ /^PPI::Statement/;
    my $parent = $element->parent;
    return if !defined($parent) || ref($parent) ne 'PPI::Structure::Block';

    my $gparent = $parent->parent;
    return if !defined($gparent) || ref($gparent) ne 'PPI::Statement::Compound';

    my @parent_elem = grep { ref($_) !~ /^PPI::Token/ } $parent->elements();
    return if $parent_elem[0] ne $element;

    my @gparent_elem = grep { ref($_) !~ /^PPI::Token/ } $gparent->elements();
    my $for = $gparent_elem[0];
    return if ref($for) ne 'PPI::Structure::For';
    return if @gparent_elem < 2 || $gparent_elem[1] ne $parent;

    # now what do we do with it ... ?
    # we want to _prepend_ the tokens^H^H^H^H^H elements of $element
    # with all the tokens in $gparent up to $parent, plus all
    # the tokens of $parent up to $element.

    foreach my $gparent_elem ($gparent->elements()) {

	last if $gparent_elem eq $parent;
	if ($gparent_elem eq $for) {

	    my @for_statements
		= grep { ref($_) =~ /^PPI::Statement/ } $for->elements();

	    my $condition_statement = $for_statements[1]->clone();
	    $element->{__CONDITION__} = $condition_statement;

	    if (@for_statements > 2) {
		my $continue_statement = $for_statements[2]->clone();
		$element->{__CONTINUE__} = $continue_statement->clone();
	    } else {
		$element->{__CONTINUE__} = __new_null_statement()->clone();
	    }

	    my $line = $for->line_number;
	    my $line2 = ($gparent->tokens)[-1]->line_number;
	    $element->{__FOR_LINE__} = "$file:$line";
	    $IGNORE_FILE_LINE{"$file:$line2"} = 1;
	    $element->{__DECORATED__} = 'for';
	}
    }
    return;
}

sub __decorate_first_statement_in_foreach_block {
    # Description of "first statement in block of a foreach loop"
    #
    #PPI::Statement::Compound                      $gparent
    #  PPI::Token::Word       for/foreach
    #  zero or more PPI::Token::Whitespace
    #  optional PPI::Token::Symbol                 optional $loop_var
    #  zero or more PPI::Token::Whitespace
    #  PPI::Structure::List                        $list
    #    ...
    #  zero or more PPI::Token::Whitespace
    #  PPI::Structure::Block                       $parent
    #    optional PPI::Token::Structure
    #    zero or more PPI::Token::Whitespace
    #    PPI::Statement                            $element

    return unless DECORATE_FOREACH;

    my ($element, $file) = @_;
    return if ref($element) !~ /^PPI::Statement/;

    my $parent = $element->parent;
    return if !defined($parent) || ref($parent) ne 'PPI::Structure::Block';

    my @parent_sts = grep { ref($_) !~ /^PPI::Token/ } $parent->elements();
    return if $parent_sts[0] ne $element;  # not the first statement in block

    my $gparent = $parent->parent;
    return if !defined($gparent) || ref($gparent) ne 'PPI::Statement::Compound';
    my $keyword = ($gparent->elements())[0];
    return if $keyword ne 'foreach' && $keyword ne 'for';

    my @gparent_elem = grep { ref($_) !~ /^PPI::Token/ } $gparent->elements();
    return if @gparent_elem < 2 || $gparent_elem[1] ne $parent;
    my $list = $gparent_elem[0];
    return if ref($list) ne 'PPI::Structure::List';

    # find the name of the loop var. Could be implicit $_ if var can't be
    # found in the PPI.
    my ($loop_var) = grep { 
      ref($_) eq 'PPI::Token::Symbol'
	  || ref($_) eq 'PPI::Token::Magic' 
    } $gparent->elements();
    if (!defined($loop_var)) {
	$loop_var = bless { content => '$_' }, 'PPI::Token::Magic';
    } else {
	$loop_var = $loop_var->clone;
    }
    $loop_var->{_PREVAL} = 1;
  

    $element->{__DECORATED__} = 'foreach';
    my $line = $keyword->line_number;
    $element->{__FOREACH_LINE__} = "$file:$line";
    $element->{__UPDATE__} = $loop_var;
    return;
}

sub __decorate_first_statement_in_while_block {
    # We expect a particular pattern of PPI code to describe the
    # "first statement in the block of a C-style for-loop":
    #
    # PPI::Statement::Compound                     $gparent
    #   PPI::Token::Word (while/until)
    #   zero of more PPI::Token::Whitespace
    #   PPI::Structure::Condition                  $cond
    #     ...
    #   zero or more PPI::Token::Whitespace
    #   PPI::Structure::Block                      $parent
    #     zero or more PPI::Token::xxx
    #     PPI::Statement::xxx                      $element
    #
    return unless DECORATE_WHILE;

    my ($element, $file) = (@_);
    return if ref($element) !~ /^PPI::Statement/;
    my $parent = $element->parent;
    return if !defined($parent) || ref($parent) ne 'PPI::Structure::Block';

    my $gparent = $parent->parent;
    return if !defined($gparent) || ref($gparent) ne 'PPI::Statement::Compound';

    my @parent_elem = grep { ref($_) !~ /^PPI::Token/ } $parent->elements();
    return if $parent_elem[0] ne $element;

    my @gparent_elem = grep { ref($_) !~ /^PPI::Token/ } $gparent->elements();
    my $cond = $gparent_elem[0];
    return if ref($cond) ne 'PPI::Structure::Condition';
    return if @gparent_elem < 2 || $gparent_elem[1] ne $parent;

    my $cond_name = '';
    foreach my $gparent_elem ($gparent->elements()) {

	if (ref($gparent_elem) eq 'PPI::Token::Word' && $cond_name eq '') {
	    $cond_name = "$gparent_elem";
	}

	last if $gparent_elem eq $parent;
	if ($gparent_elem eq $cond) {

	    $element->{__BLOCK_NAME__} = uc ($cond_name || 'COND');
	    $element->{__CONDITION__} = $cond->clone();
	    my $line = $cond->line_number;
	    $element->{__WHILE_LINE__} = "$file:$line";
	    $element->{__DECORATED__} = 'while/until';
	    return;
	}
    }
    return;
}

sub __decorate_last_statement_in_dowhile_block {
    # Looking for (optional whitespace removed):
    # PPI::Statement                                  $gparent
    #   PPI::Token::Word              "do"
    #   PPI::Structure::Block                         $parent
    #     PPI::Token::Structure       "{"
    #     *PPI::Statement, PPI::Statement::xxx
    #     PPI::Statement                              $element
    #       ...
    #     PPI::Token::Structure       "}"
    #   PPI::Token::Word              "while/until"
    #   ...                                           @condition

    my ($element, $file) = @_;
    return if ref($element) !~ /^PPI::Statement/;

    my $parent = $element->parent;
    return if ref($parent) ne 'PPI::Structure::Block';
    my @parent_stmnts = grep {
	ref($_) =~ /^PPI::Statement/
    } $parent->elements;
    return if @parent_stmnts < 1 || $parent_stmnts[-1] ne $element;

    my $gparent = $parent->parent;
    return if ref($gparent) !~ /^PPI::Statement/;
    my @gparent_elem = grep {
	ref($_) ne 'PPI::Token::Whitespace'
    } $gparent->elements();

    return if $gparent_elem[0] ne "do";
    return if $gparent_elem[1] ne $parent;
    my $sense = $gparent_elem[2];
    return if $sense ne 'while' && $sense ne 'until';
    my @condition = map {
	my $z = $_->clone;
	$z->{_PREVAL} = $z->{_DEFER} = 1
	    if ref($z) eq 'PPI::Token::Symbol'
	    || ref($z) eq 'PPI::Token::Magic';
	$z
    } grep {
	$_->line_number > $sense->line_number
	    || ($_->line_number == $sense->line_number
		&& $_->column_number > $sense->column_number)
    } $gparent->elements();

    $element->{__DECORATED__} = 'do-while';
    my $line = $sense->line_number;
    $element->{__DOWHILE_LINE__} = "$file:$line";
    $element->{__SENSE__} = "DO-" . uc "$sense";
    $element->{__CONDITION__} = [ @condition ];
    return;
}

# in a long chain of if/elsif/else blocks, 
# say if(COND1) BLOCK1 elsif(COND2) BLOCK2 elsif(COND3) BLOCK3 else BLOCK4,
# only the first condition (COND1) gets displayed in a trace. To get more
# useful trace output, prepend conditions to the first statement in
# each block to be displayed with the trace. That is, display
#   COND2 with the first statement in BLOCK2,
#   COND2 and COND3 with the first statement in BLOCK3, and
#   COND2 and COND3 with the first statement in BLOCK4.
# 
sub __decorate_statements_in_ifelse_block {

    return unless DECORATE_ELSIF;

    my ($element, $file) = @_;
    return if ref($element) !~ /^PPI::Statement/;
    my $parent = $element->parent;
    return if !defined($parent) || ref($parent) ne 'PPI::Structure::Block';

    my $gparent = $parent->parent;
    return if !defined($gparent) || ref($gparent) ne 'PPI::Statement::Compound';

    my @parent_elem = grep { ref($_) !~ /^PPI::Token/ } $parent->elements();
    return if $parent_elem[0] ne $element;

    my @gparent_elem = grep { ref($_) !~ /^PPI::Token/ } $gparent->elements();
    my $cond = $gparent_elem[0];
    return if ref($cond) ne 'PPI::Structure::Condition';

    my @gparent_blocks = grep { ref($_) eq 'PPI::Structure::Block' 
                              } $gparent->elements();
    return if @gparent_blocks < 2 || $gparent_blocks[0] eq $parent;

    my @gparent_cond = grep { ref($_) eq 'PPI::Structure::Condition' 
			    } $gparent->elements();

    my $line = $gparent_cond[0]->line_number;
    $element->{__IF_LINE__} = "$file:$line";
    $element->{__DECORATED__} = 'if-elsif-else';
    $element->{__CONDITIONS__} = [];
    my $ws = '';
    my $style = Devel::DumpTrace::_display_style();
    for (my $i=0; $i<@gparent_blocks; $i++) {
	if ($i < @gparent_cond) {
	    push @{$element->{__CONDITIONS__}}, 
	        __new_token("${ws}ELSEIF "),
	        $gparent_cond[$i]->clone();
	} else {
	    push @{$element->{__CONDITIONS__}}, __new_token("${ws}ELSE");
	}
	if ($gparent_blocks[$i] eq $parent) {
	    return;
	}
	$ws ||= $style == DISPLAY_TERSE ? "\n\t\t\t" : " ";
    }
    return;
}

sub __new_token {
    my ($text) = @_;
    my $element = bless { content => $text }, 'PPI::Token';
    return $element->clone();
}

our $NULL_DOC = '';
our $NULL_STATEMENT;
sub __new_null_statement {
    unless ($NULL_STATEMENT) {
	$NULL_DOC = PPI::Document->new(\' ');           #' \');
        $NULL_STATEMENT = ($NULL_DOC->elements)[0];
    }
    return $NULL_STATEMENT->clone();
}

1;

__END__

=head1 NAME

Devel::DumpTrace::PPI - PPI-based version of Devel::DumpTrace

=head1 VERSION

0.18

=head1 SYNOPSIS

    perl -d:DumpTrace::PPI demo.pl
    >>>>> demo.pl:3:[__top__]:        $a:1 = 1;
    >>>>> demo.pl:4:[__top__]:        $b:3 = 3;
    >>>>> demo.pl:5:[__top__]:        $c:23 = 2 * $a:1 + 7 * $b:3;
    >>>>> demo.pl:6:[__top__]:        @d:(1,3,26) = ($a:1, $b:3, $c:23 + $b:3);

    perl -d:DumpTrace::PPI=verbose demo.pl
    >>   demo.pl:3:[__top__]:
    >>>              $a = 1;
    >>>>>            1 = 1;
    ------------------------------------------
    >>   demo.pl:4:[__top__]:
    >>>              $b = 3;
    >>>>>            3 = 3;
    ------------------------------------------
    >>   demo.pl:5:[__top__]:
    >>>              $c = 2 * $a + 7 * $b;
    >>>>             $c = 2 * 1 + 7 * 3;
    >>>>>            23 = 2 * 1 + 7 * 3;
    ------------------------------------------
    >>   demo.pl:6:[__top__]:
    >>>              @d = ($a, $b, $c + $b);
    >>>>             @d = (1, 3, 23 + 3);
    >>>>>            (1,3,26) = (1, 3, 23 + 3);
    ------------------------------------------

=head1 DESCRIPTION

C<Devel::DumpTrace::PPI> is a near drop-in replacement
to L<Devel::DumpTrace|Devel::DumpTrace> that uses the L<PPI module|PPI>
for parsing the source code.
PPI overcomes some of the limitations of the original C<Devel::DumpTrace>
parser and makes a few other features available, including

=over 4

=item * handling statements with chained assignments of complex assignment
expressions

  $ perl -d:DumpTrace=verbose -e '$a=$b[$c=2]="foo"'
  >>  -e:1:[__top__]:
  >>>              $a=$b[$c=2]="foo"
  >>>>             $a=()[undef=2]="foo"
  >>>>>            'foo'=()[undef=2]="foo"
  -------------------------------------------

  $ perl -d:DumpTrace::PPI=verbose -e '$a=$b[$c=2]="foo"'
  >>   -e:1:[__top__]:
  >>>              $a=$b[$c=2]="foo"
  >>>>>            'foo'=(undef,undef,'foo')[$c=2]="foo"
  ------------------------------------------

=item * multi-line statements

  $ cat multiline.pl
  $b = 4;
  @a = (1 + 2,
        3 + $b);

    $ perl -d:DumpTrace=verbose multiline.pl
    >>  multiline.pl:1:[__top__]:
    >>>              $b = 4;
    >>>>>            4 = 4;
    -------------------------------------------
    >>  multiline.pl:2:[__top__]:
    >>>              @a = (1 + 2,
    >>>>>            (3,7) = (1 + 2,
    -------------------------------------------

    $ perl -d:DumpTrace::PPI=verbose multiline.pl
    >>   multiline.pl:1:[__top__]:
    >>>              $b = 4;
    >>>>>            4 = 4;
    ------------------------------------------
    >>   multiline.pl:2:[__top__]:
    >>>              @a = (1 + 2,
                           3 + $b);
    >>>>             @a = (1 + 2,
                           3 + 4);
    >>>>>            (3,7) = (1 + 2,
                           3 + 4);
    ------------------------------------------

=item * string literals with variable names

    $ perl -d:DumpTrace=verbose -e '$email = q/mob@cpan.org/'
    >>  -e:1:[__top__]:
    >>>              $email = q/mob@cpan.org/
    >>>>             $email = q/mob().org/
    >>>>>            "mob\@cpan.org" = q/mob().org/
    -------------------------------------------

    $ perl -d:DumpTrace::PPI=verbose -e '$email = q/mob@cpan.org/'
    >>   -e:1:[__top__]:
    >>>              $email = q/mob@cpan.org/
    >>>>>            "mob\@cpan.org" = q/mob@cpan.org/
    ------------------------------------------

=item * Better recognition of Perl's magic variables

    $ perl -d:DumpTrace=verbose -e '$"="\t";'  -e 'print join $", 3, 4, 5'
    >>  -e:1:[__top__]:
    >>>              $"="\t";
    >>>>>            $"="\t";
    -------------------------------------------
    >>  -e:2:[__top__]:
    >>>              print join $", 3, 4, 5
    -------------------------------------------
    3       4       5

    $ perl -d:DumpTrace::PPI=verbose -e '$"="\t";' -e 'print join $", 3, 4, 5'
    >>   -e:1:[__top__]:
    >>>              $"="\t";
    >>>>>            "\t"="\t";
    ------------------------------------------
    >>   -e:2:[__top__]:
    >>>              print join $", 3, 4, 5
    >>>>             print join "\t", 3, 4, 5
    ----------------------------------------------
    3       4       5

=item * Can insert implicitly used C<$_>, C<@_>, C<@ARGV> variables

C<$_> is often used as the implicit target of regular expressions
or an implicit argument to many standard functions. Since Perl v5.10,
C<$_> can take on the value in a C<given> expression and used in an
implicit smart match of a C<when> expression.
C<@_> and C<@ARGV> are often implicitly used as arguments to
C<shift> or C<pop>. This module can identify some places where
these variables are used implicitly and include their values
in the trace output.

    $ perl -d:DumpTrace::PPI=verbose -e '$_=pop;' \
          -e 'print m/hello/ && sin' hello

    >>    -e:1:[__top__]:
    >>>              $_=pop;
    >>>>             $_=pop ('hello');
    >>>>>            'hello'=pop ('hello');
    -------------------------------------------
    >>    -e:2:[__top__]:
    >>>              print m/hello/ && sin
    >>>>             print 'hello'=~m/hello/ && sin $_
    0>>>>>           print 'hello'=~m/hello/ && sin 'hello'
    -------------------------------------------

=back

The PPI-based parser has more overhead than the simpler parser from
L<Devel::DumpTrace|Devel::DumpTrace> (benchmarks forthcoming),
so you may not want to always favor
C<Devel::DumpTrace::PPI> over C<Devel::DumpTrace>.
Plus it requires L<PPI|PPI> to be installed. You can force 
the basic (non-PPI) parser to be used by either invoking your
program with the C<-d:DumpTrace::noPPI> switch, or by setting
the environment variable C<DUMPTRACE_NOPPI> to a true value.

See L<Devel::DumpTrace|Devel::DumpTrace> for far more information
about what this module is supposed to do, including the variables
and configuration settings.

=head1 SPECIAL HANDLING FOR FLOW CONTROL STRUCTURES

Inside a Perl debugger, there are many expressions evaluated
inside Perl flow control structures that "cannot hold a breakpoint"
(to use the language of L<perldebguts|perldebguts>). As a result,
these expressions never appear in a normal trace ouptut (using
C<-d:Trace>, for example).

For example, a trace for a line containing a C-style C<for> loop 
typically appears only once, during the first iteration of the loop:

    $ perl -d:Trace -e 'for ($i=0; $i<3; $i++) {' -e '$j = $i ** 2;' -e '}'
    >> -e:3: }
    >> -e:1: for ($i=0; $i<3; $i++) {
    >> -e:2: $j = $i ** 2;
    >> -e:2: $j = $i ** 2;
    >> -e:2: $j = $i ** 2;

Perl is supposed to be evaluating the expressions C<$i++> and C<< $i<3 >>
at each iteration, but those steps are optimized out of the trace output.

Or for another example, a trace through a complex C<if-elsif-else>
structure only produces the condition expression for the initial
C<if> statement:

    $ perl -d:Trace -e '$a=3;
    > if ($a==1) {
    >   $b=$a;
    > } elsif ($a==2) {
    >   $b=0;
    > } else {
    >   $b=9;
    > }'
    >> -e:1: $a=3;
    >> -e:2: if ($a==1) {
    >> -e:7:   $b=9;

To get to the assignment C<$b=9>, Perl needed to have evaluated
the expression C<$a==2>, but this step did not make it to the
trace output.

There's a lot of value in seeing these expressions, however,
so C<Devel::DumpTrace::PPI> takes steps to attach these
expressions to the existing source code and to display and
evaluate these expressions when they would have been evaluated
in the Perl program.

=head2 Special handling for C-style for loops

A C-style for loop has the structure

    for ( INITIALIZER ; CONDITION ; UPDATE ) BLOCK

In debugging a program with such a control structure, it is helpful
to observe how the C<CONDITION> and C<UPDATE> expressions are
evaluated at each iteration of the loop. At times the first statement
of a C<BLOCK> inside a for loop will be decorated with the relevant
expressions from the C<for> loop:

    $ cat ./simple-for.pl
    for ($i=0; $i<3; $i++) {
      $y += $i;
    }

    $ perl -d:DumpTrace::PPI ./simple-for.pl
    >>>   ./simple-for.pl:3:[__top__]:
    >>>>> ./simple-for.pl:1:[__top__]:      for ($i:0=0; $i:0<3; $i:0++) {
    >>>>> ./simple-for.pl:2:[__top__]:      $y:0 += $i:0;
    >>>>> ./simple-for.pl:2:[__top__]:      FOR-UPDATE: {$i:1++ } FOR-COND: {$i:1<3; }
                                            $y:1 += $i:1;
    >>>>> ./simple-for.pl:2:[__top__]:      FOR-UPDATE: {$i:2++ } FOR-COND: {$i:2<3; }
                                            $y:3 += $i:2;

    $ perl -d:DumpTrace::PPI=verbose ./simple-for.pl
    >>    ./simple-for.pl:3:[__top__]:
    >>>
    -------------------------------------------
    >>    ./simple-for.pl:1:[__top__]:
    >>>              for ($i=0; $i<3; $i++) {
    >>>>             for ($i=0; 0<3; 0++) {
    >>>>>            for (0=0; 0<3; 0++) {
    -------------------------------------------
    >>    ./simple-for.pl:2:[__top__]:
    >>>              $y += $i;
    >>>>             $y += 0;
    >>>>>            0 += 0;
    -------------------------------------------
    >>    ./simple-for.pl:2:[__top__]:
    >>>              FOR-UPDATE: {$i++ } FOR-COND: {$i<3; } $y += $i;
    >>>>             FOR-UPDATE: {1++ } FOR-COND: {1<3; } $y += 1;
    >>>>>            FOR-UPDATE: {1++ } FOR-COND: {1<3; } 1 += 1;
    -------------------------------------------
    >>    ./simple-for.pl:2:[__top__]:
    >>>              FOR-UPDATE: {$i++ } FOR-COND: {$i<3; } $y += $i;
    >>>>             FOR-UPDATE: {2++ } FOR-COND: {2<3; } $y += 2;
    >>>>>            FOR-UPDATE: {2++ } FOR-COND: {2<3; } 3 += 2;
    -------------------------------------------

The first time the loop's block code is executed, there is no need
to evaluate the conditional or the update expression, because
they were just evaluated in the previous line. But the second and third
time through the loop, the original source code is decorated with
C<FOR-UPDATE: {> I<expression> C<}> and C<FOR-COND: {> I<expression>
C<}>, showing what code was executed when the previous iteration 
finished, and what expression was evaluated to determine whether to
continue with the C<for> loop, respectively. 

Unfortunately, this example still does not show the expressions
that were evaluated at the end of the third loop, when the
update and condition expressions are evaluated another time.
In the last iteration, the condition expression evaluates to false
and the program breaks out of the loop.

=head2 Special handling for other foreach loops

When a program containing the regular C<foreach [$var] LIST> construction
is traced, the C<foreach ...> statement only appears in the trace 
output for the first iteration of the loop, just like the C-style
for loop construct. For all subsequent iterations the 
C<Devel::DumpTrace::PPI> module will prepend the first statement in the
block with C<FOREACH: {> I<loop-variable> C<}> to show the new
value of the loop variable at the beginning of each iteration.

    $ perl -d:DumpTrace::PPI -e '
    for (1 .. 6) {
    $n += 2 * $_ - 1;
    print $_, "\t", $n, "\n"
    }
    '
    >>>>> -e:2:[__top__]:   for $_:1 (1 .. 6) {
    >>>>> -e:3:[__top__]:   $n:1 += 2 * $_:1 - 1;
    >>>   -e:4:[__top__]:   print $_:1, "\t", $n:1, "\n"
    1       1
    >>>>> -e:3:[__top__]:   FOREACH: {$_:2}         $n:4 += 2 * $_:2 - 1;
    >>>   -e:4:[__top__]:   print $_:2, "\t", $n:4, "\n"
    2       4
    >>>>> -e:3:[__top__]:   FOREACH: {$_:3}         $n:9 += 2 * $_:3 - 1;
    >>>   -e:4:[__top__]:   print $_:3, "\t", $n:9, "\n"
    3       9
    >>>>> -e:3:[__top__]:   FOREACH: {$_:4}         $n:16 += 2 * $_:4 - 1;
    >>>   -e:4:[__top__]:   print $_:4, "\t", $n:16, "\n"
    4       16
    >>>>> -e:3:[__top__]:   FOREACH: {$_:5}         $n:25 += 2 * $_:5 - 1;
    >>>   -e:4:[__top__]:   print $_:5, "\t", $n:25, "\n"
    5       25
    >>>>> -e:3:[__top__]:   FOREACH: {$_:6}         $n:36 += 2 * $_:6 - 1;
    >>>   -e:4:[__top__]:   print $_:6, "\t", $n:36, "\n"
    6       36

=head2 Special handle for while/until loops

As with a C<for> loop, the conditional expression of a 
C<while> or C<until> loop is only included in trace output
on the initial entrance to the loop. C<Devel::DumpTrace::PPI>
decorates the first statement of the block inside the C<while/until>
loop to show how the conditional expression is evaluated at the
beginning of every iteration of the loop:

    $ cat ./simple-while.pl
    my ($i, $j, $l) = (0, 9, 0);
    while ($i++ < 6) {
      my $k = $i * $j--;
      next if $k % 5 == 1;
      $l = $l + $k;
    }

    $ perl -d:DumpTrace::PPI ./simple-while.pl   
    >>>   /tmp/while3.pl:1:[__top__]:
    >>>   /tmp/while3.pl:2:[__top__]:       while ($i:0++ < 6) {
    >>>>> /tmp/while3.pl:3:[__top__]:       my $k:9 = $i:1 * $j:9--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:9 % 5 == 1;
    >>>>> /tmp/while3.pl:5:[__top__]:       $l:9 = $l:0 + $k:9;
    >>>>> /tmp/while3.pl:3:[__top__]:       WHILE: ($i:2++ < 6)
                                            my $k:16 = $i:2 * $j:8--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:16 % 5 == 1;
    >>>>> /tmp/while3.pl:3:[__top__]:       WHILE: ($i:3++ < 6)
                                            my $k:21 = $i:3 * $j:7--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:21 % 5 == 1;
    >>>>> /tmp/while3.pl:3:[__top__]:       WHILE: ($i:4++ < 6)
                                            my $k:24 = $i:4 * $j:6--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:24 % 5 == 1;
    >>>>> /tmp/while3.pl:5:[__top__]:       $l:33 = $l:9 + $k:24;
    >>>>> /tmp/while3.pl:3:[__top__]:       WHILE: ($i:5++ < 6)
                                            my $k:25 = $i:5 * $j:5--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:25 % 5 == 1;
    >>>>> /tmp/while3.pl:5:[__top__]:       $l:58 = $l:33 + $k:25;
    >>>>> /tmp/while3.pl:3:[__top__]:       WHILE: ($i:6++ < 6)
                                            my $k:24 = $i:6 * $j:4--;
    >>>   /tmp/while3.pl:4:[__top__]:       next if $k:24 % 5 == 1;
    >>>>> /tmp/while3.pl:5:[__top__]:       $l:82 = $l:58 + $k:24;

In this example, a C<WHILE: {> I<expression> C<}> decorator
(capitalized to indicate that it is not a part of the actual source
code) shows how the conditional statement was evaluated prior to
each iteration of the loop (the output is a little misleading because
the conditional expression contains a C<++> postfix operator,
but this module does not evaluate the expression until after the
real conditional expression has actually been evaluated).

Again, the output does not show the conditional expression being
evaluated for the final time, right before the program breaks out
of the while loop control structure.

=head2 do-while and do-until loops

Like regular C<while> and C<until> loops, the C<do-while> and
C<do-until> constructions do not include evaluation of the final
conditional expression in the trace output. So C<Devel::DumpTrace::PPI>
decorates the last statement of a C<do-while> or C<do-until> block
to print out the condition:

    $ perl -d:DumpTrace::PPI -e 'do {
    > $k++;
    > $l += $k;
    > } while $l < 40'
    >>>   -e:1:[__top__]:   do {
    >>>>> -e:2:[__top__]:   $k:1++;
    >>>>> -e:3:[__top__]:   $l:1 += $k:1;
                                            DO-WHILE: { $l:1 < 40}
    >>>>> -e:2:[__top__]:   $k:2++;
    >>>>> -e:3:[__top__]:   $l:3 += $k:2;
                                            DO-WHILE: { $l:3 < 40}
    >>>>> -e:2:[__top__]:   $k:3++;
    >>>>> -e:3:[__top__]:   $l:6 += $k:3;
                                            DO-WHILE: { $l:6 < 40}
    >>>>> -e:2:[__top__]:   $k:4++;
    >>>>> -e:3:[__top__]:   $l:10 += $k:4;
                                            DO-WHILE: { $l:10 < 40}
    >>>>> -e:2:[__top__]:   $k:5++;
    >>>>> -e:3:[__top__]:   $l:15 += $k:5;
                                            DO-WHILE: { $l:15 < 40}
    >>>>> -e:2:[__top__]:   $k:6++;
    >>>>> -e:3:[__top__]:   $l:21 += $k:6;
                                            DO-WHILE: { $l:21 < 40}
    >>>>> -e:2:[__top__]:   $k:7++;
    >>>>> -e:3:[__top__]:   $l:28 += $k:7;
                                            DO-WHILE: { $l:28 < 40}
    >>>>> -e:2:[__top__]:   $k:8++;
    >>>>> -e:3:[__top__]:   $l:36 += $k:8;
                                            DO-WHILE: { $l:36 < 40}
    >>>>> -e:2:[__top__]:   $k:9++;
    >>>>> -e:3:[__top__]:   $l:45 += $k:9;
                                            DO-WHILE: { $l:45 < 40}

The conditional expression is displayed and evaluated after the
last statement of the block has been executed but before the
actual C<while/until> condition has been evaluated. The trace
output in the expression labeled C<DO-WHILE:> or C<DO-UNTIL:> may be
misleading if the conditional expression makes function calls
or has any other side-effects.

=head2 Complex if - elsif - ... - else blocks

Although a long sequence of expressions might need to be
evaluated to determine program flow through a complex 
C<if> - C<elsif> - ... - C<else> statement, the normal trace output
will always only show the initial condition (that is, the
condition associated with the C<if> keyword). C<Devel::DumpTrace::PPI>
will decorate the first statement in blocks after the C<elsif>
or C<else> keywords to show all of the expressions that 
had to be evaluated to get to a particular point of execution, and
how (subject to side-effects of the conditional expressions) those
expressions were evaluated:

    $ cat ./if-elsif-else.pl
    for ($a=-1; $a<=3; $a++) {
      if ($a == 1) {
        $b = 1;
      } elsif ($a == 2) {
        $b = 4;
      } elsif ($a == 3) {
        $b = 9;
      } elsif ($a < 0) {
        $b = 5;
        $b++;
      } else {
        $b = 20;
      }
    }

    $ perl -d:DumpTrace::PPI ./if-elsif-else.pl
    >>>   /tmp/if4.pl:14:[__top__]:
    >>>>> /tmp/if4.pl:1:[__top__]:  for ($a:-1=-1; $a:-1<=3; $a:-1++) {
    >>>   /tmp/if4.pl:2:[__top__]:  if ($a:-1 == 1) {
    >>>>> /tmp/if4.pl:9:[__top__]:  ELSEIF ($a:-1 == 1)
                                            ELSEIF ($a:-1 == 2)
                                            ELSEIF ($a:-1 == 3)
                                            ELSEIF ($a:-1 < 0)
                                            $b:5 = 5;
    >>>   /tmp/if4.pl:10:[__top__]: $b:5++;
    >>>   /tmp/if4.pl:2:[__top__]:  FOR-UPDATE: {$a:0++ } FOR-COND: {$a:0<=3; }
                                            if ($a:0 == 1) {
    >>>>> /tmp/if4.pl:12:[__top__]: ELSEIF ($a:0 == 1)
                                            ELSEIF ($a:0 == 2)
                                            ELSEIF ($a:0 == 3)
                                            ELSEIF ($a:0 < 0)
                                            ELSE
                                            $b:20 = 20;
    >>>   /tmp/if4.pl:2:[__top__]:  FOR-UPDATE: {$a:1++ } FOR-COND: {$a:1<=3; }
                                            if ($a:1 == 1) {
    >>>>> /tmp/if4.pl:3:[__top__]:  $b:1 = 1;
    >>>   /tmp/if4.pl:2:[__top__]:  FOR-UPDATE: {$a:2++ } FOR-COND: {$a:2<=3; }
                                            if ($a:2 == 1) {
    >>>>> /tmp/if4.pl:5:[__top__]:  ELSEIF ($a:2 == 1)
                                            ELSEIF ($a:2 == 2)
                                            $b:4 = 4;
    >>>   /tmp/if4.pl:2:[__top__]:  FOR-UPDATE: {$a:3++ } FOR-COND: {$a:3<=3; }
                                            if ($a:3 == 1) {
    >>>>> /tmp/if4.pl:7:[__top__]:  ELSEIF ($a:3 == 1)
                                            ELSEIF ($a:3 == 2)
                                            ELSEIF ($a:3 == 3)
                                            $b:9 = 9;

In this example, the C<ELSEIF> (I<expression>) and C<ELSE> decorators
indicate what expressions must have been evaluated to reach
the particular block of the statement that is to be executed.

=head2 Some TODOs

Other flow control structures in Perl could benefit from 
similar treatment. These will be addressed in future versions
of this distribution.

=over 4

=item C<do-while> and C<do-until> loops

=item C<for[each]> [variable] LIST loops

=item C<map BLOCK LIST> and C<grep BLOCK LIST> blocks

=item postfix C<EXPR for LIST>, C<EXPR while/until CONDITION> statements

Postfix expressions are typically executed as a single operation
(with no place to hold a breakpoint). This item might need some L<B-fu|B>.

=back

=head1 OTHER FEATURES

=head2 "Smart" abbreviation of large arrays and hashes

When displaying the contents of a large array or hash table,
C<Devel::DumpTrace> can abbreviate the output.

When displaying the contents of an array or hash table,
the PPI-based parser can sometimes evaluate the expressions
inside subscripts. When the array or hash is large and
abbreviated output is used, the abbreviation can use the
value of the subscript expression to provide better context.

    $ perl -d:DumpTrace::noPPI=quiet -e '@r=(0..99);' -e '$s=$r[50];'
    >>>>> -e:1:[__top__]:   @r:(0,1,2,3,4,5,6,7,...)=(0..99);
    >>>>> -e:2:[__top__]:   $s:50=$r:(0,1,2,3,4,5,6,7,...)[50];

In some cases, the PPI-based parser can evaluate the expressions inside
subscripts. This value can be used to produce an abbreviation with
some context:

    $ perl -Ilib -d:DumpTrace::PPI=quiet -e '@r=(0..99);' -e '$s=$r[50];'
    >>>>> -e:1:[__top__]:   @r:(0,1,2,3,4,5,6,7,...)=(0..99);
    >>>>> -e:2:[__top__]:   $s:50=$r:(0,1,2,...,50,...,99)[50];

For some complex cases (like programs with C<tie>'d variables where just
reading a variable's value can have side effects) you may want to 
disable the context-sensitive abbreviation of large arrays and hashes.
This can be done by passing a true value in the environment variable
C<DUMPTRACE_DUMB_ABBREV>. 

=head1 SUBROUTINES/METHODS

None to worry about.

=head1 EXPORT

Nothing is or can be exported from this module.

=head1 DIAGNOSTICS

None

=head1 CONFIGURATION AND ENVIRONMENT

Like L<Devel::DumpTrace|Devel::DumpTrace>, this module also reads
the C<DUMPTRACE_FH> and C<DUMPTRACE_LEVEL> environment variables.
See C<Devel::DumpTrace> for details about how to use these variables.

=head1 DEPENDENCIES

L<PPI|PPI> for understanding the structure of your Perl script.

L<PadWalker|PadWalker> for arbitrary access to lexical variables.

L<Scalar::Util|Scalar::Util> for the reference identification
convenience methods.

L<Text::Shorten|Text::Shorten> (bundled with this distribution)
for abbreviating long output, when desired.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The PPI-based parser in this module runs 3-6 times slower than the
basic parser (which runs 7-10 times slower than the basic
L<Devel::Trace|Devel::Trace>).

See L<Devel::DumpTrace/"SUPPORT"> for other support information.
Report issues for this module with the C<Devel-DumpTrace> distribution.

=head1 AUTHOR

Marty O'Brien, E<lt>mob at cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright 2010-2012 Marty O'Brien.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut
