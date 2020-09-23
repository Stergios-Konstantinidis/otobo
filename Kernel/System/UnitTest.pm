# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2020 Rother OSS GmbH, https://otobo.de/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::System::UnitTest;

use strict;
use warnings;
use v5.24.0;
use utf8;

# core modules
use File::stat;
use Storable();
use Term::ANSIColor();
use Time::HiRes();
use TAP::Harness;
use List::Util qw(any);

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(IsHashRefWithData IsArrayRefWithData);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Main',
);

=head1 NAME

Kernel::System::UnitTest - functions to run all or some OTOBO unit tests

=head1 PUBLIC INTERFACE

=head2 new()

create an unit test object. Do not use this subroutine directly. Use instead:

    my $UnitTestObject = $Kernel::OM->Get('Kernel::System::UnitTest');

=cut

sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = bless {}, $Type;

    $Self->{Debug} = $Param{Debug} || 0;
    $Self->{ANSI}  = $Param{ANSI}  || 0;

    return $Self;
}

=head2 Run()

run all or some tests located in C<scripts/test/**/*.t> and print the result.

    $UnitTestObject->Run(
        Name                   => ['JSON', 'User'],     # optional, execute certain test files only
        Directory              => 'Selenium',           # optional, execute tests in subdirectory
        Verbose                => 1,                    # optional (default 0), only show result details for all tests, not just failing
        PostTestScripts        => ['...'],              # Script(s) to execute after a test has been run.
                                                        #  You can specify %File%, %TestOk% and %TestNotOk% as dynamic arguments.
    );

Please note that the individual test files are not executed in the main process,
but instead in separate forked child processes which are controlled by L<Kernel::System::UnitTest::Driver>.
Their results will be transmitted to the main process via a local file.

Tests listed in B<UnitTest::Blacklist> are not executed.

Tests in F<Custom/scripts/test> take precedence over the tests in F<scripts/test>.

=cut

sub Run {
    my $Self = shift;
    my %Param = @_;

    # handle parameters
    my $Verbosity           = $Param{Verbose} // 0;
    my @ExecuteTestPatterns = @{ $Param{Tests} // [] };
    my $DirectoryParam      = $Param{Directory};

    # some config stuff
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Product      = join ' ', $ConfigObject->Get('Product'), $ConfigObject->Get('Version');
    my $Home         = $ConfigObject->Get('Home');

    # run tests in a subdir when requested
    my $Directory = "$Home/scripts/test";
    if ( $DirectoryParam ) {
        $Directory .= "/$DirectoryParam";
        $Directory =~ s/\.//g;
    }

    my $StartTime      = CORE::time();                      # Use non-overridden time().
    my $StartTimeHiRes = [ Time::HiRes::gettimeofday() ];

    # Determine which tests should be skipped because of UnitTest::Blacklist
    my (@SkippedTests, @ActualTests);
    {
        # Get patterns for blacklisted tests
        my @BlacklistPatterns;
        my $UnitTestBlacklist = $ConfigObject->Get('UnitTest::Blacklist');
        if ( IsHashRefWithData($UnitTestBlacklist) ) {

            CONFIGKEY:
            for my $ConfigKey ( sort keys $UnitTestBlacklist->%* ) {

                # check sanity of configuration, skip in case of problems
                next CONFIGKEY unless $ConfigKey;
                next CONFIGKEY unless $UnitTestBlacklist->{$ConfigKey};
                next CONFIGKEY unless IsArrayRefWithData( $UnitTestBlacklist->{$ConfigKey} );

                # filter empty values
                push @BlacklistPatterns, grep { $_ } $UnitTestBlacklist->{$ConfigKey}->@*;
            }
        }

        my @Files = $Kernel::OM->Get('Kernel::System::Main')->DirectoryRead(
            Directory => $Directory,
            Filter    => '*.t',
            Recursive => 1,
        );

        FILE:
        for my $File (@Files) {

            # check if only some tests are requested
            if ( @ExecuteTestPatterns ) {
                next FILE unless any { $File =~ /\/\Q$_\E\.t$/smx } @ExecuteTestPatterns;
            }

            # Check blacklisted files.
            if ( any { $File =~ m{\Q$Directory/$_\E$}smx } @BlacklistPatterns ) {
                push @SkippedTests, $File;

                next FILE;
            }

            # Check if a file with the same path and name exists in the Custom folder.
            my $CustomFile = $File =~ s{ \A $Home }{$Home/Custom}xmsr;
            push @ActualTests, -e $CustomFile ? $CustomFile : $File;
        }
    }

    my %HarnessArgs = (
        timer     => 1,
        verbosity => $Verbosity,
        # try to color the output when we are in an ANSI terminal
        color     => $Self->{ANSI},
        # these libs are additional, $ENV{PERL5LIB} is still honored
        lib       => [ $Home, "$Home/Kernel/cpan-lib", "$Home/Custom" ],
    );
    my $Harness = TAP::Harness->new( \%HarnessArgs );
    my $Aggregate = $Harness->runtests( @ActualTests );

    ## TODO: resurrect useful features from _HandleFile()
    #for my $File ( @ActualTests ) {
    #        $Self->_HandleFile(
    #            Verbose         => $Param{Verbose},
    #            PostTestScripts => $Param{PostTestScripts},
    #            File            => $File,
    #        );
    #}

    ## TODO: get result data from TAP::Harness::runtests
    #my $Duration = sprintf( '%.3f', Time::HiRes::tv_interval($StartTimeHiRes) );

    #my $Host           = $ConfigObject->Get('FQDN');
    #my $TestCountTotal = ( $Self->{TestCountOk} // 0 ) + ( $Self->{TestCountNotOk} // 0 );

    if (@SkippedTests) {
        print "# Following blacklisted tests were skipped:\n";
        for my $SkippedTest (@SkippedTests) {
            print '#  ' . $Self->_Color( 'yellow', $SkippedTest ) . "\n";
        }
    }

    #printf(
    #    "%s ran %s test(s) in %s for %s.\n",
    #    $Self->_Color( 'yellow', $Host ),
    #    $Self->_Color( 'yellow', $TestCountTotal ),
    #    $Self->_Color( 'yellow', "${Duration}s" ),
    #    $Self->_Color( 'yellow', $Product )
    #);

    #if ( $Self->{TestCountNotOk} ) {
    #    print $Self->_Color( 'red', "$Self->{TestCountNotOk} tests failed.\n" );
    #    print " FailedTests:\n";
    #    FAILEDFILE:
    #    for my $FailedFile ( @{ $Self->{NotOkInfo} || [] } ) {
    #        my ( $File, @Tests ) = @{ $FailedFile || [] };
    #        next FAILEDFILE if !@Tests;
    #        print sprintf "  %s %s\n", $File, join ", ", @Tests;
    #    }
    #}
    #elsif ( $Self->{TestCountOk} ) {
    #    print $Self->_Color( 'green', "All $Self->{TestCountOk} tests passed.\n" );
    #}
    #else {
    #    print $Self->_Color( 'yellow', "No tests executed.\n" );
    #}

    return $Aggregate->all_passed;
}

=begin Internal:

=cut

sub _HandleFile {
    my ( $Self, %Param ) = @_;

    my $ResultDataFile = $Kernel::OM->Get('Kernel::Config')->Get('Home') . '/var/tmp/UnitTest.dump';
    unlink $ResultDataFile;

    # Create a child process.
    my $PID = fork;

    # Could not create child.
    if ( $PID < 0 ) {

        $Self->{ResultData}->{ $Param{File} } = { TestNotOk => 1 };
        $Self->{TestCountNotOk} += 1;

        print $Self->_Color( 'red', "Could not create child process for $Param{File}.\n" );

        return;
    }

    # We're in the child process.
    if ( !$PID ) {

        my $Driver = $Kernel::OM->Create(
            'Kernel::System::UnitTest::Driver',
            ObjectParams => {
                Verbose      => $Param{Verbose},
            },
        );

        $Driver->Run( File => $Param{File} );

        exit 0;
    }

    # Wait for child process to finish.
    waitpid( $PID, 0 );

    my $ResultData = eval { Storable::retrieve($ResultDataFile) };

    if ( !$ResultData ) {
        print $Self->_Color( 'red', "Could not read result data for $Param{File}.\n" );
        $ResultData->{TestNotOk}++;
    }

    $Self->{ResultData}->{ $Param{File} } = $ResultData;
    $Self->{TestCountOk}    += $ResultData->{TestOk}    // 0;
    $Self->{TestCountNotOk} += $ResultData->{TestNotOk} // 0;

    $Self->{SeleniumData} //= $ResultData->{SeleniumData};

    $Self->{NotOkInfo} //= [];
    if ( $ResultData->{NotOkInfo} ) {

        # Cut out from result data hash, as we don't need to send this to the server.
        push @{ $Self->{NotOkInfo} }, [ $Param{File}, @{ delete $ResultData->{NotOkInfo} } ];
    }

    # TODO: reactivate the callbacks
    for my $PostTestScript ( @{ $Param{PostTestScripts} // [] } ) {
        my $Commandline = $PostTestScript;
        $Commandline =~ s{%File%}{$Param{File}}ismxg;
        $Commandline =~ s{%TestOk%}{$ResultData->{TestOk} // 0}iesmxg;
        $Commandline =~ s{%TestNotOk%}{$ResultData->{TestNotOk} // 0}iesmxg;
        system $Commandline;
    }

    return 1;
}

=head2 _Color()

this will color the given text (see L<Term::ANSIColor::color()>) if
ANSI output is available and active, otherwise the text stays unchanged.

    my $PossiblyColoredText = $CommandObject->_Color('green', $Text);

=cut

sub _Color {
    my ( $Self, $Color, $Text ) = @_;

    # no coloring unless we are in an ANSI terminal
    return $Text unless $Self->{ANSI};

    # we are in an ANSI terminal
    return Term::ANSIColor::color($Color) . $Text . Term::ANSIColor::color('reset');
}

=end Internal:

=cut

1;
