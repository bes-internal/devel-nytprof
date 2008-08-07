# vim: ts=8 sw=4 expandtab:
##########################################################
## This script is part of the Devel::NYTProf distribution
##
## Copyright, contact and other information can be found
## at the bottom of this file, or by going to:
## http://search.cpan.org/dist/Devel-NYTProf/
##
###########################################################
## $Id$
###########################################################
package Devel::NYTProf::Reader;

our $VERSION = '2.02';

use warnings;
use strict;
use Carp;
use Config;

use Devel::NYTProf::Data;
use Devel::NYTProf::Util qw(
    strip_prefix_from_paths
    html_safe_filename
    calculate_median_absolute_deviation
);

# These control the limits for what the script will consider ok to severe times
# specified in standard deviations from the mean time
use constant SEVERITY_SEVERE => 2.0;    # above this deviation, a bottleneck
use constant SEVERITY_BAD    => 1.0;
use constant SEVERITY_GOOD   => 0.5;    # within this deviation, okay

# Static class variables
our $FLOAT_FORMAT = $Config{nvfformat};
$FLOAT_FORMAT =~ s/"//g;

# Class methods
sub new {
    my $class = shift;
    my $file  = shift;
    my $opts  = shift;

    my $self = {
        file => $file || 'nytprof.out',
        output_dir => '.',
        suffix     => '.csv',
        header     => "# Profile data generated by Devel::NYTProf::Reader\n"
            . "# Version: v$Devel::NYTProf::Core::VERSION\n"
            . "# More information at http://search.cpan.org/dist/Devel-NYTProf/\n"
            . "# Format: time,calls,time/call,code\n",
        datastart => '',
        line      => [
            {},
            {value => 'time',      end => ',', default => '0'},
            {value => 'calls',     end => ',', default => '0'},
            {value => 'time/call', end => ',', default => '0'},
            {value => 'source',    end => '',  default => ''},
            {end   => "\n"}
        ],
        dataend  => '',
        footer   => '',
        taintmsg => "# WARNING!\n"
            . "# The source file used in generating this report has been modified\n"
            . "# since generating the profiler database.  It might be out of sync\n",

        # -- OTHER STUFF --
        replacements => [
            {   pattern => '!~FILENAME~!',
                replace => "\$FILE"
            },
            {   pattern => '!~LEVEL~!',
                replace => "\$LEVEL"
            },
            {   pattern => '!~DEV_CALLS~!',
                replace => "\$statistics{calls}->[0]"
            },
            {   pattern => '!~DEV_TIME~!',
                replace => "\$statistics{time}->[0]"
            },
            {   pattern => '!~DEV_TIME/CALL~!',
                replace => "\$statistics{'time/calls'}"
            },
            {   pattern => '!~MEAN_CALLS~!',
                replace => "\$statistics{calls}->[1]"
            },
            {   pattern => '!~MEAN_TIME~!',
                replace => "\$statistics{time}->[1]"
            },
            {   pattern => '!~MEAN_TIME/CALLS~!',
                replace => "\$statistics{'time/calls'}->[1]"
            },
            {   pattern => '!~TOTAL_CALLS~!',
                replace => "\$self->{filestats}->{\$filestr}->{'calls'}"
            },
            {   pattern => '!~TOTAL_TIME~!',
                replace => "\$self->{filestats}->{\$filestr}->{'time'}"
            },
        ],
        callsfunc         => undef,
        timefunc          => undef,
        'time/callsfunc'  => undef,
        numeric_precision => {
            time        => 7,
            calls       => 0,
            'time/call' => 7
        },
    };

    bless($self, $class);
    $self->{profile} = Devel::NYTProf::Data->new({filename => $self->{file}});

    $self->{profile}->make_fid_filenames_relative($opts->{relative_paths});

    # a hack for testing/debugging
    exit $ENV{NYTPROF_EXIT_AFTER_LOAD} if defined $ENV{NYTPROF_EXIT_AFTER_LOAD};

    return $self;
}


sub _map_new_to_old {    # convert into old-style data structure
    my ($profile, $level) = @_;
    my $fid_line_data = $profile->get_fid_line_data($level ||= 'line');

    my $dump = 0;
    require Data::Dumper if $dump;
    $profile->dump_profile_data({filehandle => \*STDERR, separator => "\t"}) if $dump;
    warn Data::Dumper::Dumper($profile) if $dump;

    my $fid_fileinfo = $profile->{fid_fileinfo};
    my $oldstyle     = {};
    for my $fid (1 .. @$fid_fileinfo - 1) {

        # skip synthetic fids for evals
        next if $fid_fileinfo->[$fid][1];

        my $filename = $fid_fileinfo->[$fid][0]
            or warn "No filename for fid $fid";

        # if it's a .pmc then assume that's the file we want to look at
        # (because the main use for .pmc's are related to perl6)
        $filename .= "c" if $fid_fileinfo->[$fid]->is_pmc;

        my $lines_array = $fid_line_data->[$fid]
            or next;    # ignore fid's with no lines executed

        # convert any embedded eval line time arrays to hashes
        for (@$lines_array) {
            $_->[2] = _line_array_to_line_hash($_->[2]) if $_ && $_->[2];
        }

        my $lines_hash = _line_array_to_line_hash($lines_array);
        $oldstyle->{$filename} = $lines_hash;
    }
    warn Data::Dumper::Dumper($oldstyle) if $dump;
    return $oldstyle;
}

sub _line_array_to_line_hash {
    my ($array) = @_;
    my $hash = {};
    for my $line (0 .. @$array) {
        $hash->{$line} = $array->[$line]
            if defined $array->[$line];
    }
    return $hash;
}


##
sub set_param {
    my ($self, $param, $value) = @_;

    if ($param eq 'linestart') {
        $self->{line}->[0] = $value;
    }
    elsif ($param eq 'column1') {
        $self->{line}->[1] = $value;
    }
    elsif ($param eq 'column2') {
        $self->{line}->[2] = $value;
    }
    elsif ($param eq 'column3') {
        $self->{line}->[3] = $value;
    }
    elsif ($param eq 'column4') {
        $self->{line}->[4] = $value;
    }
    elsif ($param eq 'lineend') {
        $self->{line}->[5] = $value;
    }
    elsif (!exists $self->{$param}) {
        confess "Attempt to set $param to $value failed: $param is not a valid " . "parameter\n";
    }
    else {
        return $self->{$param} unless defined($value);
        $self->{$param} = $value;
    }
    undef;
}


sub get_param {
    my ($self, $param, $code_args) = @_;
    my $value = $self->{$param};
    if (ref $value eq 'CODE') {
        $code_args ||= [];
        $value = $value->(@$code_args);
    }
    return $value;
}

##
sub add_regexp {
    my ($self, $pattern, $replace) = @_;
    push(@{$self->{user_regexp}}, {pattern => $pattern, replace => $replace});
}

##
sub file_has_been_modified {
    my $self = shift;
    my $file = shift;
    return undef unless -f $file;
    my $mtime = (stat $file)[9];
    return ($mtime > $self->{profile}{attribute}{basetime});
}

##
sub _output_additional {
    my ($self, $fname, $content) = @_;
    open(OUT, '>', "$self->{output_dir}/$fname")
        or confess "Unable to open $self->{output_dir}/$fname for writing; $!\n";
    print OUT @$content;
    close OUT;
}

##
sub get_file_stats {
    my $self = shift;
    return $self->{filestats};
}

##
sub output_dir {
    my ($self, $dir) = @_;
    return $self->{output_dir} unless defined($dir);
    if (!mkdir $dir) {
        confess "Unable to create directory $dir: $!\n" if !$! =~ /exists/;
    }
    $self->{output_dir} = $dir;
}

##
sub report {
    my $self = shift;
    my ($opts) = @_;

    my $level_additional_sub = $opts->{level_additional};
    my $profile              = $self->{profile};
    my $modes                = $profile->get_profile_levels;
    for my $level (values %$modes) {
        $self->_generate_report($profile, $level);
        $level_additional_sub->($profile, $level)
            if $level_additional_sub;
    }
}

##
sub _generate_report {
    my $self = shift;
    my ($profile, $LEVEL) = @_;

    my $data = _map_new_to_old($profile, $LEVEL);

    carp "Profile report data contains no files"
        unless keys %$data;

    #$profile->dump_profile_data({ filehandle => \*STDERR, separator=>"\t", });

    # pre-calculate some data so it can be cross-referenced
    foreach my $filestr (keys %$data) {

        # discover file path
        my $fileinfo = $profile->fileinfo_of($filestr);
        if (not $fileinfo) {
            warn "Oops. I got confused about '$filestr' so I'll skip it\n";
            delete $data->{$filestr};
            next;
        }
        my $fname = html_safe_filename($fileinfo->filename_without_inc);
        $fname .= "-$LEVEL" if $LEVEL;

        $self->{filestats}->{$filestr}->{html_safe} = $fname;

        # save per-level html_safe name
        $self->{filestats}->{$filestr}->{$LEVEL}->{html_safe} = $fname;

        # store original filename in value as well as key
        $self->{filestats}->{$filestr}->{filename} = $filestr;
    }

    foreach my $filestr (keys %$data) {

        # test file modification date. Files that have been touched after the
        # profiling was done may very well produce useless output since the source
        # file might differ from what it looked like before.
        my $tainted = $self->file_has_been_modified($filestr);

        my %totalsAccum;         # holds all line times. used to find median
        my %totalsByLine;        # holds individual line stats
        my $runningTotalTime;    # holds the running total

        # (should equal sum of $totalsAccum)
        my $runningTotalCalls;    # holds the running total number of calls.

        foreach my $key (keys %{$data->{$filestr}}) {
            my $a = $data->{$filestr}->{$key};

            if (0 == $a->[1]) {

                # The debugger cannot stop on BEGIN{...} lines.  A line in a begin
                # may set a scalar reference to something that needs to be eval'd later.
                # as a result, if the variable is expanded outside of the BEGIN, we'll
                # see the original BEGIN line, but it won't have any calls or times
                # associated. This will cause a divide by zero error.
                $a->[1] = 1;
            }

            my $time = $a->[0];
            if (my $eval_lines = $a->[2]) {
                # line contains a string eval
                # $eval_lines is a hash of profile data for the lines in the eval
                # sum up the times and add to $time
                # but we don't increment the statement count of the eval
                # as that would be inappropriate and misleading
                $time += $_->[0] for values %$eval_lines;
            }
            push(@{$totalsAccum{'time'}},      $time);
            push(@{$totalsAccum{'calls'}},     $a->[1]);
            push(@{$totalsAccum{'time/call'}}, $time / $a->[1]);

            $totalsByLine{$key}->{'time'}  += $time;
            $totalsByLine{$key}->{'calls'} += $a->[1];
            $totalsByLine{$key}->{'time/call'} =
                $totalsByLine{$key}->{'time'} / $totalsByLine{$key}->{'calls'};

            $runningTotalTime  += $time;
            $runningTotalCalls += $a->[1];
        }

        $self->{filestats}->{$filestr}->{'time'}      = $runningTotalTime;
        $self->{filestats}->{$filestr}->{'calls'}     = $runningTotalCalls;
        $self->{filestats}->{$filestr}->{'time/call'} = $runningTotalTime / $runningTotalCalls;

        # Use Median Absolute Deviation Formula to get file deviations for each of
        # calls, time and time/call values
        my %statistics = (
            'calls'     => calculate_median_absolute_deviation($totalsAccum{'calls'}),
            'time'      => calculate_median_absolute_deviation($totalsAccum{'time'}),
            'time/call' => calculate_median_absolute_deviation($totalsAccum{'time/call'}),
        );

        my $line_calls_hash = $profile->line_calls_for_file($filestr);
        my $subs_defined_hash = $profile->subs_defined_in_file($filestr, 1);

        # the output file name that will be open later.  Not including directory at this time.
        # keep here so that the variable replacement subs can get at it.
        my $fname = $self->{filestats}->{$filestr}->{html_safe} . $self->{suffix};

        # localize header and footer for variable replacement
        my $header    = $self->get_param('header',    [$profile, $filestr, $fname, $LEVEL]);
        my $footer    = $self->get_param('footer',    [$profile, $filestr]);
        my $taintmsg  = $self->get_param('taintmsg',  [$profile, $filestr]);
        my $datastart = $self->get_param('datastart', [$profile, $filestr]);
        my $dataend   = $self->get_param('dataend',   [$profile, $filestr]);
        my $FILE      = $filestr;

        foreach my $transform (@{$self->{replacements}}) {
            my $pattern = $transform->{pattern};
            my $replace = $transform->{replace};

            if ($pattern =~ m/^!~\w+~!$/) {

                # replace variable content
                $replace = eval $replace;
                $header    =~ s/$pattern/$replace/g;
                $footer    =~ s/$pattern/$replace/g;
                $taintmsg  =~ s/$pattern/$replace/g;
                $datastart =~ s/$pattern/$replace/g;
                $dataend   =~ s/$pattern/$replace/g;
            }
        }

        # open output file
        #warn "$self->{output_dir}/$fname";
        open(OUT, "> $self->{output_dir}/$fname")
            or confess "Unable to open $self->{output_dir}/$fname " . "for writing: $!\n";

        # begin output
        print OUT $header;
        print OUT $taintmsg if $tainted;
        print OUT $datastart;

        if (!open(IN, $filestr)) {

            # the report will not be complete, but this doesn't need to be fatal
            my $hint = '';
            $hint =
                  " Try running $0 in the same directory as you ran Devel::NYTProf, "
                . "or ensure \@INC is correct."
                unless $filestr eq '-e'
                or our $_generate_report_inc_hint++;
            warn "Unable to open '$filestr' for reading: $!.$hint\n"
                unless our $_generate_report_filestr_warn->{$filestr}++;    # only once
            next;
        }

        my $LINE = 1;    # actual line number. PATTERN variable, DO NOT CHANGE
        foreach my $line (<IN>) {
            chomp $line;
            foreach my $regexp (@{$self->{user_regexp}}) {
                $line =~ s/$regexp->{pattern}/$regexp->{replace}/g;
            }
            if ($line =~ m/^\# \s* line \b/x) {
                # XXX we should be smarter about this - patches welcome!
                warn "Ignoring '$line' directive at line $LINE - profile data for $filestr will be out of sync with source!\n"
                    unless our $line_directive_warn->{$filestr}++; # once per file
            }
            my $makes_calls_to = $line_calls_hash->{$LINE}   || {};
            my $subs_defined   = $subs_defined_hash->{$LINE} || [];

            # begin output

            foreach my $hash (@{$self->{line}}) {

                # If a func reference is provided, it will control output for this column.
                if (defined(my $func = $hash->{func})) {
                    my $value = $hash->{value};
                    if ($value) {
                        print OUT $func->(
                            $value, $totalsByLine{$LINE}->{$value},
                            $statistics{$value}, $LINE, $line, $profile, $subs_defined,
                            $makes_calls_to
                        );
                    }
                    else {
                        print OUT $func->(
                            $value, $LINE, $line, $profile, $subs_defined, $makes_calls_to
                        );
                    }
                    next;
                }

                print OUT $hash->{start} if defined $hash->{start};
                if (defined $hash->{value}) {
                    if ($hash->{value} eq 'source') {
                        print OUT $line;    # from source rather than profile db
                    }
                    elsif ($hash->{value} eq 'line') {
                        print OUT $LINE;
                    }
                    elsif (exists $data->{$filestr}->{$LINE}) {
                        printf(OUT "%0."
                                . $self->{numeric_precision}->{$hash->{value}}
                                . $FLOAT_FORMAT,
                            $totalsByLine{$LINE}->{$hash->{value}}
                        );
                    }
                    else {
                        print OUT $hash->{default};
                    }
                }
                print OUT $hash->{end} if defined $hash->{end};
            }

        }
        continue {

            # Increment line number counters
            $LINE++;
        }
        print OUT $dataend;
        print OUT $footer;
        close OUT;
    }
}


sub href_for_sub {
    my ($self, $sub) = @_;

    my ($file, $fid, $first, $last) = $self->{profile}->file_line_range_of_sub($sub);
    if (!$first) {
        return undef if defined $first;    # is xs (first and least are 0)
        warn("No file line range data for sub '$sub'\n")
            unless our $href_for_sub_no_data_warn->{$sub}++;    # warn just once
        return undef;
    }

    my $stats      = $self->get_file_stats();
    my $file_stats = $stats->{$file};
    if (!$file_stats) {
        warn("Sub '$sub' file '$file' (fid $fid) not in stats!\n");
        return "#sub unknown";
    }
    my $html_safe = $file_stats->{html_safe} ||= do {

        # warn, just once, and use a default value
        warn "Sub '$sub' file '$file' (fid $fid) has no html_safe value\n";
        "unknown";
    };
    return "$html_safe.html#$first";
}


1;
__END__

=head1 NAME

Devel::NYTProf::Reader - Tranforms L<Devel::NYTProf> output into comprehensive, easy to read reports in (nearly) arbitrary format.

=head1 SYNOPSIS

 # This module comes with two scripts that implement it:
 #
 # nytprofhtml - create an html report with statistics highlighting
 # nytprofcsv - create a basic comma delimited report
 #
 # They are in the bin directory of your perl path, so add that to your PATH.
 #
 # The csv script is simple, and really only provided as a starting point
 # for creating other custom reports. You should refer to the html script
 # for advanced usage and statistics.

 # First run some code through the profiler to generate the nytprof database.
 perl -d:NYTProf some_perl.pl

 # To create an HTML report in ./nytprof 
 nytprofhtml

 # To create a csv report in ./nytprof 
 nytprofcsv

 # Or to generate a simple comma delimited report manually
 use Devel::NYTProf::Reader;
 my $reporter = new Devel::NYTProf::Reader('nytprof.out');

 # place to store the output
 $reporter->output_dir($file);

 # set other options and parameters
 $reporter->add_regexp('^\s*', ''); # trim leading spaces

 # generate the report
 $reporter->report();

 # many configuration options exist.  See nytprofhtml, advanced example.

=head1 DESCRIPTION

L<Devel::NYTProf> is a speedy line-by-line code profiler for Perl, written in C.
This module is a complex framework that processes the output file generated by 
L<Devel::NYTProf>

It is capable of producing reports of arbitrary format and varying complexity.

B<Note:> This module may be deprecated in future as the L<Devel::NYTProf::Data>
and L<Devel::NYTProf::Util> modules evolve and offer higher levels of
abstraction. It should then be easy to write reports directly without needing
to fit into the model assumed by this module.

Basically, for each line of code that was executed and reported, this module 
will provide the following statistics:

=over

=item *
 Total calls

=item *
 Total time

=item *
 Average time per call

=item *
 Deviation of all of the above

=item *
 Line number

=item *
 Source code

=back

C<Devel::NYTProf::Reader> will process each source file that it can find in 
your C<@INC> one-by-one.  For each line it processes, it will preform 
transformation and output based instructions that you can optionally provide.  
The configuration is very robust, supporting variations in field ordering, 
pattern substitutions (like converting ascii spaces to html spaces), and user 
callback functions to give you total control.

=head1 CONSTRUCTOR

=over 4

=item $reporter = Devel::NYTProf::Reader->new( );

=item $reporter = Devel::NYTProf::Reader->new( $FILE );

This method constructs a new C<Devel::NYTProf::Reader> object, parses $FILE
and return the new object.  By default $FILE will evaluate to './nytprof.out'.

See: L<Devel::NYTProf> for how the profiler works.

=back

=head1 PARAMETERS

Numerous parameters can be set to modify the behavior of 
C<Devel::NYTProf::Reader>.  The following methods are provided:

=over 4

=item $reporter->output_dir( $output_directory );

Set the directory that generated files should be placed in. [Default: .]

=item $reporter->add_regexp( $pattern, $replace );

Add a regular expression to the top of the pattern stack.  Ever line of output 
will be run through each entry in the pattern stack.  

For example, to replace spaces, < and > with html entities, you might do:

	$reporter->add_regexp(' ', '&nbsp;');
	$reporter->add_regexp('<', '&lt;');
	$reporter->add_regexp('>', '&gt;');

=item $reporter->set_param( $parameter, $value );

Changes the internal value of $parameter to $value.  If $value is omitted, 
returns the current value of parameter.

Basic Parameters:

  Paramter       Description
  ------------   --------------
  suffix         The file suffix for the output file
  header         Text printed at the start of the output file
  taintmsg       Text printed ONLY IF source file modification date is 
                   later than the profile database modification date.
                   Printed just after header
  datastart      Text printed just before report output and after
                   taintmsg
  dataend        Text printed just after report output
  footer         Text printed at the very end of report output
  callsfunc      Reference to a function which must accept a scalar
                   representing the total calls for a line and returns the
                   output string for that field
  timesfunc      Reference to a function which must accept a scalar
                   representing the total time for a line and returns the
                   output string for that field
  time/callsfunc Reference to a function which must accept a scalar
                   representing the average time per call for a line and 
                   returns the output string for that field

Advanced Parameters:

  Paramter         Description
  --------------   --------------
  linestart        Printed at the start of each report line
  lineend          Printed at the end of each report line
  column1          |
  column2          | The four parameters define what to print in each of
  column3          | the four output fields. See below
  column4          |

 Each of these parameters must be set to a hash reference with any of the
 following key/value pairs:

  Key              Value
  -------------    -------------
  start            string printed at the start of the field
  end              string printed at the end of the field
  value            identifier for the value that this field will hold
                     (can be: time, calls, time/calls, source)
  default          string to be used when there is no value for the field
                     specified in the 'value' key

Basic Parameters Defaults:

  Parameter         Default
  --------------   --------------
  suffix           '.csv'
  header           "# Profile data generated by Devel::NYTProf::Reader
                    # Version: v$Devel::NYTProf::Core::VERSION
                    # More information at http://search.cpan.org/dist/Devel-NYTProf/
                    # Format: time,calls,time/call,code"
  taintmsg         "# WARNING!\n# The source file used in generating this 
                   report has been modified\n# since generating the profiler 
                   database.  It might be out of sync\n"
  datastart        ''
  dataend          ''
  footer           ''
  callsfunc        undef
  timefunc         undef
  time/callsfunc   undef

Advanced Parameters Defaults:

  Parameter         Default
  --------------   --------------
  linestart        {}
  lineend          { end => "\n" }
  column1          { value => 'time',      end => ',', default => '0'}
  column2          { value => 'calls',      end => ',', default => '0'}
  column3          { value => 'time/call',  end => ',', default => '0'}
  column4          { value => 'source',    end => '',  default => '' }

=back

=head1 METHODS

=over

=item $reporter->report( );

Trigger data processing and report generation. This method will die with 
a message if it fails.  The return value is not defined.  This is where all of
the work is done.

=item $reporter->get_file_stats( );

When called after calling C<$reporter-E<gt>report()>, will return a hash containing the cumulative totals for each file.

 my $stats = $reporter->getStats();
 $stats->{FILENAME}->{time}; # might hold 0.25, the total runtime of this file>>

Fields are time, calls, time/call, html-safe.

=item Devel::NYTProf::Reader::calculate_standard_deviation( @stats );

Calculates the standard deviation and mean of the values in @stats, returns 
them as a list.

=item Devel::NYTProf::Reader::calculate_median_absolute_deviation( @stats );

Calculates the absolute median deviation and mean of the values in @stats, 
returns them as a list.

=item $reporter->_output_additional( $file, @data );

If you need to create a static file in the output directory, you can use this
subroutine.  It is currently used to dump the CSS file into the html output.

=back

=head1 EXPORT

None by default. Object Oriented.

=head1 SEE ALSO

See also L<Devel::NYTProf>.

Mailing list and discussion at L<http://groups.google.com/group/develnytprof-dev>

Public SVN Repository and hacking instructions at L<http://code.google.com/p/perl-devel-nytprof/>

Take a look at the scripts which use this module, L<nytprofhtml> and
L<nytprofcsv>.  They are probably all that you will need and provide an
excellent jumping point into writing your own custom reports.

=head1 AUTHOR

B<Adam Kaplan>, C<< <akaplan at nytimes.com> >>
B<Tim Bunce>, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>
B<Steve Peters>, C<< <steve at fisharerojo.org> >>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2008 by Adam Kaplan and The New York Times Company.
  Copyright (C) 2008 by Tim Bunce, Ireland.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
