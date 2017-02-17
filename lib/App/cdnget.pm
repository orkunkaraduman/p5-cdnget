package App::cdnget;
=head1 NAME

App::cdnget - CDN Engine

=head1 VERSION

version 0.02

=head1 ABSTRACT

CDN Engine

=head1 DESCRIPTION

App::cdnget is a FastCGI application that flexible pull-mode Content Delivery Network engine.

B<This is ALPHA version>

=cut
BEGIN
{
	require Config;
	if ($Config::Config{'useithreads'})
	{
		require threads;
		threads->import();
		require threads::shared;
		threads::shared->import();
	} else
	{
		require forks;
		forks->import();
		require forks::shared;
		forks::shared->import();
	}
}
use strict;
use warnings;
use v5.14;
use utf8;
use Time::HiRes qw(sleep usleep);
use Lazy::Utils;

use App::cdnget::Exception;
use App::cdnget::Worker;
use App::cdnget::Downloader;


BEGIN
{
	require Exporter;
	our $VERSION     = '0.02';
	our @ISA         = qw(Exporter);
	our @EXPORT      = qw(main);
	our @EXPORT_OK   = qw();
}


our $DTF_RFC822 = "%a, %d %b %Y %T %Z";
our $DTF_RFC822_GMT = "%a, %d %b %Y %T GMT";
our $DTF_YMDHMS = "%F %T";
our $DTF_YMDHMS_Z = "%F %T %z";
our $DTF_SYSLOG = "%b %e %T";
our $VBUF_SIZE = 256*1024;
our $CHUNK_SIZE = 256*1024;

our $terminating :shared = 0;


sub terminate
{
	lock($terminating);
	return 0 if $terminating;
	$terminating = 1;
	say "Terminating...";
	App::cdnget::Worker::terminate();
	App::cdnget::Downloader::terminate();
	return 1;
}

sub _listener
{
	while (1)
	{
		App::cdnget::Worker->new();
		lock($terminating);
		last if $terminating;
	}
	return 0;
}

sub main
{
	say "Started.";
	$main::DEBUG = 1;
	App::cdnget::Worker::init(16, 1024, "127.0.0.1:9000", "/data/0/cdnget");
	App::cdnget::Downloader::init();
	$SIG{INT} = sub
	{
		terminate();
	};
	threads->create(\&_listener)->detach();
	while (1)
	{
		usleep(10*1000);
		last if App::cdnget::Worker::terminated() and App::cdnget::Downloader::terminated();
	}
	usleep(100*1000);
	return 0;
}


1;
__END__
=head1 INSTALLATION

To install this module type the following

	perl Makefile.PL
	make
	make test
	make install

from CPAN

	cpan -i App::cdnget

=head1 DEPENDENCIES

This module requires these other modules and libraries:

=over

=item *

threads

=item *

threads::shared

=item *

forks

=item *

SUPER

=item *

Thread::Semaphore

=item *

Time::HiRes

=item *

DateTime

=item *

FCGI

=item *

Digest::SHA

=item *

Lazy::Utils

=item *

Object::Base

=back

=head1 REPOSITORY

B<GitHub> L<https://github.com/orkunkaraduman/p5-cdnget>

B<CPAN> L<https://metacpan.org/release/App-cdnget>

=head1 AUTHOR

Orkun Karaduman <orkunkaraduman@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2017  Orkun Karaduman <orkunkaraduman@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
