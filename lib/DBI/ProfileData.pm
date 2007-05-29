package DBI::ProfileData;
use strict;

=head1 NAME

DBI::ProfileData - manipulate DBI::ProfileDumper data dumps

=head1 SYNOPSIS

The easiest way to use this module is through the dbiprof frontend
(see L<dbiprof> for details):

  dbiprof --number 15 --sort count

This module can also be used to roll your own profile analysis:

  # load data from dbi.prof
  $prof = DBI::ProfileData->new(File => "dbi.prof");

  # get a count of the records (unique paths) in the data set
  $count = $prof->count();

  # sort by longest overall time
  $prof->sort(field => "longest");

  # sort by longest overall time, least to greatest
  $prof->sort(field => "longest", reverse => 1);

  # exclude records with key2 eq 'disconnect'
  $prof->exclude(key2 => 'disconnect');

  # exclude records with key1 matching /^UPDATE/i
  $prof->exclude(key1 => qr/^UPDATE/i);

  # remove all records except those where key1 matches /^SELECT/i
  $prof->match(key1 => qr/^SELECT/i);

  # produce a formatted report with the given number of items
  $report = $prof->report(number => 10); 

  # clone the profile data set
  $clone = $prof->clone();

  # get access to hash of header values
  $header = $prof->header();

  # get access to sorted array of nodes
  $nodes = $prof->nodes();

  # format a single node in the same style as report()
  $text = $prof->format($nodes->[0]);

  # get access to Data hash in DBI::Profile format
  $Data = $prof->Data();

=head1 DESCRIPTION

This module offers the ability to read, manipulate and format
DBI::ProfileDumper profile data.  

Conceptually, a profile consists of a series of records, or nodes,
each of each has a set of statistics and set of keys.  Each record
must have a unique set of keys, but there is no requirement that every
record have the same number of keys.

=head1 METHODS

The following methods are supported by DBI::ProfileData objects.

=cut


our $VERSION = sprintf("2.%06d", q$Revision$ =~ /(\d+)/o);

use Carp qw(croak);
use Symbol;
use Fcntl qw(:flock);

use DBI::Profile qw(dbi_profile_merge);

# some constants for use with node data arrays
sub COUNT     () { 0 };
sub TOTAL     () { 1 };
sub FIRST     () { 2 };
sub SHORTEST  () { 3 };
sub LONGEST   () { 4 };
sub FIRST_AT  () { 5 };
sub LAST_AT   () { 6 };
sub PATH      () { 7 };

=head2 $prof = DBI::ProfileData->new(File => "dbi.prof")

=head2 $prof = DBI::ProfileData->new(File => "dbi.prof", Filter => sub { ... })

=head2 $prof = DBI::ProfileData->new(Files => [ "dbi.prof.1", "dbi.prof.2" ])

Creates a a new DBI::ProfileData object.  Takes either a single file
through the File option or a list of Files in an array ref.  If
multiple files are specified then the header data from the first file
is used.

=head3 Files

Reference to an array of file names to read.

=head3 File

Name of file to read. Takes precedence over C<Files>.

=head3 DeleteFiles

If true, the files are deleted after being read. (Actually the files are
renamed first which, together with locking, avoids problems if other
applications are writing to the file.)

=head3 Filter

The C<Filter> parameter can be used to supply a code reference that can
manipulate the profile data as it is being read. This is most useful for
editing SQL statements so that slightly different statements in the raw data
will be merged and aggregated in the loaded data. For example:

  Filter => sub {
      my ($path_ref, $data_ref) = @_;
      s/foo = '.*?'/foo = '...'/ for @$path_ref;
  }

Here's an example that performs some normalization on the SQL. It converts all
numbers to C<N> and all quoted strings to C<S>.  It can also convert digits to
N within names. Finally, it summarizes long "IN (...)" clauses.

It's aggressive and simplistic, but it's often sufficient, and serves as an
example that you can tailor to suit your own needs:

  Filter => sub {
      my ($path_ref, $data_ref) = @_;
      local $_ = $path_ref->[0]; # whichever element contains the SQL Statement
      s/\b\d+\b/N/g;             # 42 -> N
      s/\b0x[0-9A-Fa-f]+\b/N/g;  # 0xFE -> N
      s/'.*?'/'S'/g;             # single quoted strings (doesn't handle escapes)
      s/".*?"/"S"/g;             # double quoted strings (doesn't handle escapes)
      # convert names like log_20001231 into log_NNNNNNNN, controlled by $opt{n}
      s/([a-z_]+)(\d{$opt{n},})/$1.('N' x length($2))/ieg if $opt{n};
      # abbreviate massive "in (...)" statements and similar
      s!(([NS],){100,})!sprintf("$2,{repeated %d times}",length($1)/2)!eg;
  }

It's often better to perform this kinds of normalization in the DBI while the
data is being collected, to avoid too much memory being used by storing profile
data for many different SQL statement. See L<DBI::Profile>.

=cut

sub new {
    my $pkg = shift;
    my $self = {                
                Files        => [ "dbi.prof" ],
		Filter       => undef,
                DeleteFiles  => 0,
                _header      => {},
                _nodes       => [],
                _node_lookup => {},
                _sort        => 'none',
                @_
               };
    bless $self, $pkg;
    
    # File (singular) overrides Files (plural)
    $self->{Files} = [ $self->{File} ] if exists $self->{File};

    $self->_read_files();
    return $self;
}

# read files into _header and _nodes
sub _read_files {
    my $self = shift;
    my $files  = $self->{Files};
    my $read_header = 0;
  
    my $fh = gensym;
    foreach (@$files) {
        my $filename = $_;
        if ($self->{DeleteFiles}) {
            my $newfilename = $filename . ".deleteme";
            rename($filename, $newfilename)
                or croak "Can't rename($filename, $newfilename): $!";
            $filename = $newfilename;
        }
        open($fh, "<", $filename)
          or croak("Unable to read profile file '$filename': $!");

        # lock the file in case it's still being written to
        # (we'll be foced to wait till the write is complete)
        flock($fh, LOCK_SH);

        if (-s $fh) {   # not empty
            $self->_read_header($fh, $filename, $read_header ? 0 : 1);
            $read_header = 1;
            $self->_read_body($fh, $filename);
        }
        close($fh); # and release lock
        unlink $filename or warn "Can't delete '$filename': $!"
            if $self->{DeleteFiles};
    }
    
    # discard node_lookup now that all files are read
    delete $self->{_node_lookup};
}

# read the header from the given $fh named $filename.  Discards the
# data unless $keep.
sub _read_header {
    my ($self, $fh, $filename, $keep) = @_;

    # get profiler module id
    my $first = <$fh>;
    chomp $first;
    $self->{_profiler} = $first if $keep;

    # collect variables from the header
    while (<$fh>) {
        chomp;
        last unless length $_;
        /^(\S+)\s*=\s*(.*)/
          or croak("Syntax error in header in $filename line $.: $_");
        # XXX should compare new with existing (from previous file)
        # and warn if they differ (diferent program or path)
        $self->{_header}{$1} = $2 if $keep;
    }
}

# reads the body of the profile data
sub _read_body {
    my ($self, $fh, $filename) = @_;
    my $nodes = $self->{_nodes};
    my $lookup = $self->{_node_lookup};
    my $filter = $self->{Filter};

    # build up node array
    my @path = ("");
    my (@data, $index, $key, $path_key);
    while (<$fh>) {
        chomp;
        if (/^\+\s+(\d+)\s?(.*)/) {
            # it's a key
            ($key, $index) = ($2, $1 - 1);

            # unmangle key
            $key =~ s/(?<!\\)\\n/\n/g; # expand \n, unless it's a \\n
            $key =~ s/(?<!\\)\\r/\r/g; # expand \r, unless it's a \\r
            $key =~ s/\\\\/\\/g;       # \\ to \

            $#path = $index;      # truncate path to new length
            $path[$index] = $key; # place new key at end

        }
	elsif (s/^=\s+//) {
            # it's data - file in the node array with the path in index 0
	    # (the optional minus is to make it more robust against systems
	    # with unstable high-res clocks - typically due to poor NTP config
	    # of kernel SMP behaviour, i.e. min time may be -0.000008))

            @data = split / /, $_;

            # corrupt data?
            croak("Invalid number of fields in $filename line $.: $_")
                unless @data == 7;
            croak("Invalid leaf node characters $filename line $.: $_")
                unless m/^[-+ 0-9eE\.]+$/;

	    # hook to enable pre-processing of the data - such as mangling SQL
	    # so that slightly different statements get treated as the same
	    # and so merged in the results
	    $filter->(\@path, \@data) if $filter;

            # elements of @path can't have NULLs in them, so this
            # forms a unique string per @path.  If there's some way I
            # can get this without arbitrarily stripping out a
            # character I'd be happy to hear it!
            $path_key = join("\0",@path);

            # look for previous entry
            if (exists $lookup->{$path_key}) {
                # merge in the new data
		dbi_profile_merge($nodes->[$lookup->{$path_key}], \@data);
            } else {
                # insert a new node - nodes are arrays with data in 0-6
                # and path data after that
                push(@$nodes, [ @data, @path ]);

                # record node in %seen
                $lookup->{$path_key} = $#$nodes;
            }
        }
	else {
            croak("Invalid line type syntax error in $filename line $.: $_");
	}
    }
}



=head2 $copy = $prof->clone();

Clone a profile data set creating a new object.

=cut

sub clone {
    my $self = shift;

    # start with a simple copy
    my $clone = bless { %$self }, ref($self);

    # deep copy nodes
    $clone->{_nodes}  = [ map { [ @$_ ] } @{$self->{_nodes}} ];

    # deep copy header
    $clone->{_header} = { %{$self->{_header}} };

    return $clone;
}

=head2 $header = $prof->header();

Returns a reference to a hash of header values.  These are the key
value pairs included in the header section of the DBI::ProfileDumper
data format.  For example:

  $header = {
    Path    => [ '!Statement', '!MethodName' ],
    Program => 't/42profile_data.t',
  };

Note that modifying this hash will modify the header data stored
inside the profile object.

=cut

sub header { shift->{_header} }


=head2 $nodes = $prof->nodes()

Returns a reference the sorted nodes array.  Each element in the array
is a single record in the data set.  The first seven elements are the
same as the elements provided by DBI::Profile.  After that each key is
in a separate element.  For example:

 $nodes = [
            [
              2,                      # 0, count
              0.0312958955764771,     # 1, total duration
              0.000490069389343262,   # 2, first duration
              0.000176072120666504,   # 3, shortest duration
              0.00140702724456787,    # 4, longest duration
              1023115819.83019,       # 5, time of first event
              1023115819.86576,       # 6, time of last event
              'SELECT foo FROM bar'   # 7, key1
              'execute'               # 8, key2
                                      # 6+N, keyN
            ],
                                      # ...
          ];

Note that modifying this array will modify the node data stored inside
the profile object.

=cut

sub nodes { shift->{_nodes} }


=head2 $count = $prof->count()

Returns the number of items in the profile data set.

=cut

sub count { scalar @{shift->{_nodes}} }


=head2 $prof->sort(field => "field")

=head2 $prof->sort(field => "field", reverse => 1)

Sorts data by the given field.  Available fields are:

  longest
  total
  count
  shortest

The default sort is greatest to smallest, which is the opposite of the
normal Perl meaning.  This, however, matches the expected behavior of
the dbiprof frontend.

=cut


# sorts data by one of the available fields
{
    my %FIELDS = (
                  longest  => LONGEST,
                  total    => TOTAL,
                  count    => COUNT,
                  shortest => SHORTEST,
                  key1     => PATH+0,
                  key2     => PATH+1,
                  key3     => PATH+2,
                 );
    sub sort {
        my $self = shift;
        my $nodes = $self->{_nodes};
        my %opt = @_;
        
        croak("Missing required field option.") unless $opt{field};

        my $index = $FIELDS{$opt{field}};
        
        croak("Unrecognized sort field '$opt{field}'.")
          unless defined $index;

        # sort over index
        if ($opt{reverse}) {
            @$nodes = sort { 
                $a->[$index] <=> $b->[$index] 
            } @$nodes;
        } else {
            @$nodes = sort { 
                $b->[$index] <=> $a->[$index] 
            } @$nodes;
        }

        # remember how we're sorted
        $self->{_sort} = $opt{field};

        return $self;
    }
}


=head2 $count = $prof->exclude(key2 => "disconnect")

=head2 $count = $prof->exclude(key2 => "disconnect", case_sensitive => 1)

=head2 $count = $prof->exclude(key1 => qr/^SELECT/i)

Removes records from the data set that match the given string or
regular expression.  This method modifies the data in a permanent
fashion - use clone() first to maintain the original data after
exclude().  Returns the number of nodes left in the profile data set.

=cut

sub exclude {
    my $self = shift;
    my $nodes = $self->{_nodes};
    my %opt = @_;

    # find key index number
    my ($index, $val);
    foreach (keys %opt) {
        if (/^key(\d+)$/) {
            $index   = PATH + $1 - 1;
            $val     = $opt{$_};
            last;
        }
    }
    croak("Missing required keyN option.") unless $index;

    if (UNIVERSAL::isa($val,"Regexp")) {
        # regex match
        @$nodes = grep {
            $#$_ < $index or $_->[$index] !~ /$val/ 
        } @$nodes;
    } else {
        if ($opt{case_sensitive}) {
            @$nodes = grep { 
                $#$_ < $index or $_->[$index] ne $val;
            } @$nodes;
        } else {
            $val = lc $val;
            @$nodes = grep { 
                $#$_ < $index or lc($_->[$index]) ne $val;
            } @$nodes;
        }
    }

    return scalar @$nodes;
}


=head2 $count = $prof->match(key2 => "disconnect")

=head2 $count = $prof->match(key2 => "disconnect", case_sensitive => 1)

=head2 $count = $prof->match(key1 => qr/^SELECT/i)

Removes records from the data set that do not match the given string
or regular expression.  This method modifies the data in a permanent
fashion - use clone() first to maintain the original data after
match().  Returns the number of nodes left in the profile data set.

=cut

sub match {
    my $self = shift;
    my $nodes = $self->{_nodes};
    my %opt = @_;

    # find key index number
    my ($index, $val);
    foreach (keys %opt) {
        if (/^key(\d+)$/) {
            $index   = PATH + $1 - 1;
            $val     = $opt{$_};
            last;
        }
    }
    croak("Missing required keyN option.") unless $index;

    if (UNIVERSAL::isa($val,"Regexp")) {
        # regex match
        @$nodes = grep {
            $#$_ >= $index and $_->[$index] =~ /$val/ 
        } @$nodes;
    } else {
        if ($opt{case_sensitive}) {
            @$nodes = grep { 
                $#$_ >= $index and $_->[$index] eq $val;
            } @$nodes;
        } else {
            $val = lc $val;
            @$nodes = grep { 
                $#$_ >= $index and lc($_->[$index]) eq $val;
            } @$nodes;
        }
    }

    return scalar @$nodes;
}


=head2 $Data = $prof->Data()

Returns the same Data hash structure as seen in DBI::Profile.  This
structure is not sorted.  The nodes() structure probably makes more
sense for most analysis.

=cut

sub Data {
    my $self = shift;
    my (%Data, @data, $ptr);

    foreach my $node (@{$self->{_nodes}}) {
        # traverse to key location
        $ptr = \%Data;
        foreach my $key (@{$node}[PATH .. $#$node - 1]) {
            $ptr->{$key} = {} unless exists $ptr->{$key};
            $ptr = $ptr->{$key};
        }

        # slice out node data
        $ptr->{$node->[-1]} = [ @{$node}[0 .. 6] ];
    }

    return \%Data;
}


=head2 $text = $prof->format($nodes->[0])

Formats a single node into a human-readable block of text.

=cut

sub format {
    my ($self, $node) = @_;
    my $format;
    
    # setup keys
    my $keys = "";
    for (my $i = PATH; $i <= $#$node; $i++) {
        my $key = $node->[$i];
        
        # remove leading and trailing space
        $key =~ s/^\s+//;
        $key =~ s/\s+$//;

        # if key has newlines or is long take special precautions
        if (length($key) > 72 or $key =~ /\n/) {
            $keys .= "  Key " . ($i - PATH + 1) . "         :\n\n$key\n\n";
        } else {
            $keys .= "  Key " . ($i - PATH + 1) . "         : $key\n";
        }
    }

    # nodes with multiple runs get the long entry format, nodes with
    # just one run get a single count.
    if ($node->[COUNT] > 1) {
        $format = <<END;
  Count         : %d
  Total Time    : %3.6f seconds
  Longest Time  : %3.6f seconds
  Shortest Time : %3.6f seconds
  Average Time  : %3.6f seconds
END
        return sprintf($format, @{$node}[COUNT,TOTAL,LONGEST,SHORTEST], 
                       $node->[TOTAL] / $node->[COUNT]) . $keys;
    } else {
        $format = <<END;
  Count         : %d
  Time          : %3.6f seconds
END

        return sprintf($format, @{$node}[COUNT,TOTAL]) . $keys;

    }
}


=head2 $text = $prof->report(number => 10)

Produces a report with the given number of items.

=cut

sub report {
    my $self  = shift;
    my $nodes = $self->{_nodes};
    my %opt   = @_;

    croak("Missing required number option") unless exists $opt{number};

    $opt{number} = @$nodes if @$nodes < $opt{number};

    my $report = $self->_report_header($opt{number});
    for (0 .. $opt{number} - 1) {
        $report .= sprintf("#" x 5  . "[ %d ]". "#" x 59 . "\n", 
                           $_ + 1);
        $report .= $self->format($nodes->[$_]);
        $report .= "\n";
    }
    return $report;
}

# format the header for report()
sub _report_header {
    my ($self, $number) = @_;
    my $nodes = $self->{_nodes};
    my $node_count = @$nodes;

    # find total runtime and method count
    my ($time, $count) = (0,0);
    foreach my $node (@$nodes) {
        $time  += $node->[TOTAL];
        $count += $node->[COUNT];
    }

    my $header = <<END;

DBI Profile Data ($self->{_profiler})

END

    # output header fields
    while (my ($key, $value) = each %{$self->{_header}}) {
        $header .= sprintf("  %-13s : %s\n", $key, $value);
    }

    # output summary data fields
    $header .= sprintf(<<END, $node_count, $number, $self->{_sort}, $count, $time);
  Total Records : %d (showing %d, sorted by %s)
  Total Count   : %d
  Total Runtime : %3.6f seconds  

END

    return $header;
}


1;

__END__

=head1 AUTHOR

Sam Tregar <sam@tregar.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2002 Sam Tregar

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl 5 itself.

=cut
