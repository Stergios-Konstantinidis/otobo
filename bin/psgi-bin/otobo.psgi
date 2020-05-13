#!/usr/bin/perl
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# --
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

=head1 NAME

otobo.psgi - OTOBO PSGI application

=head1 SYNOPSIS

    # the default webserver
    plackup bin/psgi-bin/otobo.psgi

    # Starman
    plackup --server Starman bin/psgi-bin/otobo.psgi

=head1 DESCRIPTION

A PSGI application.

=head1 Profiling

To profile single requests, install Devel::NYTProf and start this script as
PERL5OPT=-d:NYTProf NYTPROF='trace=1:start=no' plackup bin/psgi-bin/otobo.psgi
then append &NYTProf=mymarker to a request.
This creates a file called nytprof-mymarker.out, which you can process with
nytprofhtml -f nytprof-mymarker.out
Then point your browser at nytprof/index.html

=cut

use strict;
use warnings;
use 5.24.0;

use lib '/opt/otobo/';
use lib '/opt/otobo/Kernel/cpan-lib';
use lib '/opt/otobo/Custom';

## nofilter(TidyAll::Plugin::OTOBO::Perl::SyntaxCheck)

use Data::Dumper;

use Plack::Builder;
use Plack::Middleware::ErrorDocument;
use Plack::Middleware::Header;
use Plack::App::File;
use Plack::App::CGIBin;
use Module::Refresh;

# load agent web interface
use Kernel::System::Web::InterfaceAgent ();
use Kernel::System::ObjectManager;

# for future use:
#use Plack::Middleware::CamelcadeDB;
#use Plack::Middleware::Expires;
#use Plack::Middleware::Debug;

# Preload frequently used modules to speed up client spawning.
use CGI::PSGI ();
use CGI::Carp ();

# enable this if you use mysql
#use DBD::mysql ();
#use Kernel::System::DB::mysql;

# enable this if you use postgresql
#use DBD::Pg ();
#use Kernel::System::DB::postgresql;

# enable this if you use oracle
#use DBD::Oracle ();
#use Kernel::System::DB::oracle;

# Preload Net::DNS if it is installed. It is important to preload Net::DNS because otherwise loading
#   could take more than 30 seconds.
eval { require Net::DNS };

# Preload DateTime, an expensive external dependency.
use DateTime ();

# Preload dependencies that are always used.
use Template ();
use Encode qw(:all);

# this might improve performance
CGI::PSGI->compile(':cgi');

print STDERR "PLEASE NOTE THAT PLACK SUPPORT IS AS OF MAY 2020 EXPERIMENTAL AND NOT SUPPORTED!\n";

# some pre- and postprocessing for the dynamic content
my $MiddleWare = sub {
    my $app = shift;

    return sub {
        my $env = shift;

        # Reload files in @INC that have changed since the last request.
        # This is a replacement for:
        #    PerlModule Apache2::Reload
        #    PerlInitHandler Apache2::Reload
        eval {
            Module::Refresh->refresh();
        };
        warn $@ if $@;

        # check whether this request runs under Devel::NYTProf
        my $ProfilingIsOn = 0;
        if ( $ENV{NYTPROF} && $ENV{QUERY_STRING} =~ m/NYTProf=([\w-]+)/ ) {
            $ProfilingIsOn = 1;
            DB::enable_profile("nytprof-$1.out");
        }

        # Populate SCRIPT_NAME as OTOBO needs it in some places.
        # TODO: This is almost certainly a misuse of SCRIPT_NAME
        ( $env->{SCRIPT_NAME} ) = $env->{PATH_INFO} =~ m{/([A-Za-z\-_]+\.pl)};

        # Fallback to agent login if we could not determine handle...
        if ( !defined $env->{SCRIPT_NAME} || ! -e "/opt/otobo/bin/cgi-bin/$env->{SCRIPT_NAME}" ) {
            $env->{SCRIPT_NAME} = 'index.pl';
        }

        # do the work
        my $res = $app->($env);

        # clean up profiling, write the output file
        DB::finish_profile() if $ProfilingIsOn;

        return $res;
    };
};

# a port of index.pl to PSGI
my $IndexApp = sub {
    my $env = shift;

    # set up the CGI-Object from the PSGI environemnt
    my $WebRequest = CGI::PSGI->new($env);

    # 0=off;1=on;
    my $Debug = 0;

    local $Kernel::OM = Kernel::System::ObjectManager->new();

    my $Interface = Kernel::System::Web::InterfaceAgent->new(
        Debug      => $Debug,
        WebRequest => $WebRequest,
    );

    # Wrap the Run method in CGI::Emulate::PSGI in order to catch headers, status code, and content.
    my $app = CGI::Emulate::PSGI->handler(
        sub {
            warn "XXX: calling the Run method\n";
            $Interface->Run;
        }
    );

    my $res = $app->($env);

    warn Dumper( 'YYY', $res->@[0,1] );

    return $res;
};

builder {
    # Server the static files in var/httpd/httpd.
    # Same as: Alias /otobo-web/ "/opt/otobo/var/httpd/htdocs/"
    # Access is granted for all.
    # Set the Cache-Control headers as in apache2-httpd.include.conf
    mount '/otobo-web' => builder {

            # Cache css-cache for 30 days
            enable_if { $_[0]->{PATH_INFO} =~ m{skins/.*/.*/css-cache/.*\.(?:css|CSS)$} } 'Header', set => [ 'Cache-Control' => 'max-age=2592000 must-revalidate' ];

            # Cache css thirdparty for 4 hours, including icon fonts
            enable_if { $_[0]->{PATH_INFO} =~ m{skins/.*/.*/css/thirdparty/.*\.(?:css|CSS|woff|svn)$} } 'Header', set => [ 'Cache-Control' => 'max-age=14400 must-revalidate' ];

            # Cache js-cache for 30 days
            enable_if { $_[0]->{PATH_INFO} =~ m{js/js-cache/.*\.(?:js|JS)$} } 'Header', set => [ 'Cache-Control' => 'max-age=2592000 must-revalidate' ];

            # Cache js thirdparty for 4 hours
            enable_if { $_[0]->{PATH_INFO} =~ m{js/thirdparty/.*\.(?:js|JS)$} } 'Header', set => [ 'Cache-Control' => 'max-age=14400 must-revalidate' ];

            Plack::App::File->new(root => '/opt/otobo/var/httpd/htdocs')->to_app;
        };

    # Port of bin/cgi-bin/index.pl, or bin/fcgi-bin/index.pl, to Plack
    mount '/otobo/index.pl'     => builder {

        # do some pre- and postprocessing in an inline middleware
        enable $MiddleWare;

        enable "Plack::Middleware::ErrorDocument",
            403 => '/otobo/index.pl';  # forbidden files

        $IndexApp;
    };

    # Serve the CGI-scripts in bin/cgi-bin.
    # Same as: ScriptAlias /otobo/ "/opt/otobo/bin/cgi-bin/"
    # Access checking is done by the application.
    mount '/otobo'     => builder {

        # do some pre- and postprocessing in an inline middleware
        enable $MiddleWare;

        enable "Plack::Middleware::ErrorDocument",
            403 => '/otobo/index.pl';  # forbidden files

        # Execute the scripts in the appropriate environment.
        # The scripts are actually compiled by CGI::Compile,
        # CGI::initialize_globals() is called implicitly.
        Plack::App::CGIBin->new(root => '/opt/otobo/bin/cgi-bin')->to_app;
    };
};
