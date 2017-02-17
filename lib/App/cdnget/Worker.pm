package App::cdnget::Worker;
use Object::Base;
use v5.14;
use bytes;
use IO::Handle;
use FileHandle;
use Time::HiRes qw(sleep usleep);
use Thread::Semaphore;
use FCGI;
use Digest::SHA;

use App::cdnget;
use App::cdnget::Exception;
use App::cdnget::Downloader;


BEGIN
{
	our $VERSION     = $App::cdnget::VERSION;
}


our $maxCount;
our $spareCount;
our $addr = 0;
our $cachePath;

our $terminating :shared = 0;
our $terminated :shared = 0;
our $spareSemaphore :shared;
our $workerSemaphore :shared;
our $socket;


attributes qw(:shared tid);


sub init
{
	my ($_maxCount, $_spareCount, $_addr, $_cachePath) = @_;
	$maxCount = $_maxCount;
	$spareCount = $_spareCount;
	$addr = $_addr;
	$cachePath = $_cachePath;
	$spareSemaphore = Thread::Semaphore->new($spareCount);
	$workerSemaphore = Thread::Semaphore->new($maxCount);
	$socket = FCGI::OpenSocket($addr, 5) or App::cdnget::Exception->throw($!);
	return 1;
}

sub final
{
	FCGI::CloseSocket($socket);
	return 1;
}

sub terminate
{
	{
		lock($terminating);
		return 0 if $terminating;
		$terminating = 1;
	}
	$workerSemaphore->down($maxCount);
	lock($terminated);
	$terminated = 1;
	return 1;
}

sub terminating
{
	lock($terminating);
	return $terminating;
}

sub terminated
{
	if (@_ > 0)
	{
		my $self = shift;
		lock($self);
		return defined($self->tid)? 0: 1;
	}
	lock($terminated);
	return $terminated;
}

sub new
{
	my $class = shift;
	while (not $spareSemaphore->down_timed(1))
	{
		usleep(1*1000);
		return if terminating();
	}
	usleep(1*1000) while not $workerSemaphore->down_timed(1);
	if (terminating())
	{
		$spareSemaphore->up();
		$workerSemaphore->up();
		return;
	}
	my $self = $class->SUPER();
	$self->tid = undef;
	{
		lock($self);
		my $thr = threads->create(\&work, $self) or $self->throw($!);
		cond_wait($self);
		unless (defined($self->tid))
		{
			App::cdnget::Exception->throw($thr->join());
		}
		$thr->detach();
	}
	return $self;
}

sub DESTROY
{
	my $self = shift;
	$self->SUPER::DESTROY;
}

sub throw
{
	my $self = shift;
	my ($msg) = @_;
	unless (ref($msg))
	{
		$msg = "Unknown" unless $msg;
		$msg = "Worker $msg";
	}
	App::cdnget::Exception->throw($msg, 1);
}

sub work
{
	my $self = shift;
	my $tid = threads->tid();

	$self->tid = $tid;
	{
		lock($self);
		cond_signal($self);
	}

	my $isSpare = 1;
	eval
	{
		my ($in, $out, $err) = (IO::Handle->new(), IO::Handle->new(), IO::Handle->new());
		my $env = {};
		my $req = FCGI::Request($in, $out, $err, $env, $socket, FCGI::FAIL_ACCEPT_ON_INTR) or $self->throw($!);
		eval
		{
			$isSpare = 0;
			$workerSemaphore->up();
			my $accept = $req->Accept();
			$workerSemaphore->down();
			$spareSemaphore->up();
			die "\n" unless $accept >= 0;
			die "\n" if $self->terminating;

			my $id = $env->{CDNGET_ID};
			$self->throw("Invalid id: $id") unless $id =~ /^\w+$/i;
			my $origin = URI->new($env->{CDNGET_ORIGIN});
			$self->throw("Invalid scheme") unless $origin->scheme =~ /^http|https$/i;
			my $url = $origin->scheme."://".$origin->host_port.($origin->path."/".$env->{DOCUMENT_URI})=~s/\/\//\//gr;
			my $uid = "#$id=$url";
			my $path = $cachePath."/".$id;
			$path =~ s/\/\//\//g;

=pod
			mkdir($path) or $self->throw($!) unless -e $path;
			my @dirs = Digest::SHA::sha256_hex($url) =~ /..../g;
			my $file = pop @dirs;
			for (@dirs)
			{
				$path .= "/$_";
				mkdir($path) or $self->throw($!) unless -e $path;
			}
			$path .= "/$file";
=cut

			mkdir($path) or $self->throw($!) unless -e $path;
			for (split("/", $env->{DOCUMENT_URI}))
			{
				next if not $_;
				$path .= "/$_";
				mkdir($path) or $self->throw($!) unless -e $path;
			}
			$path .= "/data";

			my ($in_vbuf, $out_vbuf, $err_vbuf);
			#my ($in_vbuf, $out_vbuf, $err_vbuf) = ("\0"x$App::cdnget::VBUF_SIZE, "\0"x$App::cdnget::VBUF_SIZE, "\0"x$App::cdnget::VBUF_SIZE);
			eval { $in->setvbuf($in_vbuf, IO::Handle::_IOLBF, $App::cdnget::VBUF_SIZE) };
			eval { $out->setvbuf($out_vbuf, IO::Handle::_IOLBF, $App::cdnget::VBUF_SIZE) };
			eval { $err->setvbuf($err_vbuf, IO::Handle::_IOLBF, $App::cdnget::VBUF_SIZE) };

			my $fh;
			my $downloader;
			{
				lock(%App::cdnget::Downloader::uids);
				$fh = FileHandle->new($path, "<");
				unless ($fh)
				{
					App::cdnget::Downloader->new($uid, $path, $url);
					$fh = FileHandle->new($path, "<") or $self->throw($!);
				}
				$downloader = $App::cdnget::Downloader::uids{$uid};
			}

			my $vbuf;
			#my $vbuf = "\0"x$App::cdnget::VBUF_SIZE;
			eval { $fh->setvbuf($vbuf, FileHandle::_IOLBF, $App::cdnget::VBUF_SIZE) };
			$fh->binmode(":bytes") or $self->throw($!);
			#$fh->blocking(0);

			{
				local ($/, $\) = ("\r\n")x2;
				my $line;
				my $buf;
				#my $buf = "\0"x$App::cdnget::CHUNK_SIZE;
				while (1)
				{
					die "\n" if $self->terminating;
					my $downloaderTerminated = ! $downloader || $downloader->terminated;
					$fh->seek($fh->tell, 0) or $self->throw($!);
					$line = $fh->getline;
					unless (defined($line))
					{
						$self->throw($!) if $fh->error;
						die "\n" if $downloaderTerminated;
						usleep(1*1000);
						next;
					}
					chomp $line;
					if (not $line or $line =~ /^(Status\:|Content\-|Location\:)/i)
					{
						$out->print("$line\r\n") or $!{EPIPE} or $self->throw($!);
					}
					threads->yield();
					last unless $line;
				}
				while (1)
				{
					die "\n" if $self->terminating;
					my $downloaderTerminated = ! $downloader || $downloader->terminated;
					$fh->seek($fh->tell, 0) or $self->throw($!);
					my $len = $fh->read($buf, $App::cdnget::CHUNK_SIZE);
					$self->throw($!) unless defined($len);
					if ($len == 0)
					{
						die "\n" if $downloaderTerminated;
						usleep(1*1000);
						next;
					}
					$out->write($buf, $len) or not $! or $!{EPIPE} or $!{EPROTOTYPE} or $self->throw($!);
					threads->yield();
				}
			}
		};
		{
			local $@;
			$req->Finish();
		}
		if ($@ and (ref($@) or $@ ne "\n"))
		{
			die $@;
		}
	};
	{
		local $@;
		$workerSemaphore->up();
		$spareSemaphore->up() if $isSpare;
		lock($self);
		$self->tid = undef;
	}
	if ($@ and (ref($@) or $@ ne "\n"))
	{
		warn $@;
		return $@;
	}
	return;
}


1;
__END__
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
