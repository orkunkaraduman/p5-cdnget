package App::cdnget::Downloader;
use Object::Base;
use v5.14;
use bytes;
use IO::Handle;
use FileHandle;
use Time::HiRes qw(sleep usleep);
use HTTP::Headers;
use LWP::UserAgent;

use App::cdnget;
use App::cdnget::Exception;


BEGIN
{
	our $VERSION     = $App::cdnget::VERSION;
}


our $terminating :shared = 0;
our %downloaders :shared;
our %uids :shared;


attributes qw(:shared uid path url tid);


sub init
{
	return 1;
}

sub final
{
	return 1;
}

sub terminate
{
	lock($terminating);
	return 0 if $terminating;
	$terminating = 1;
	return 1;
}

sub terminating
{
	if (@_ > 0)
	{
		lock($terminating);
		return $terminating;
	}
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
	lock($terminating);
	lock(%downloaders);
	return ($terminating and not keys(%downloaders))? 1: 0;
}

sub new
{
	my $class = shift;
	my ($uid, $path, $url) = @_;
	if (terminating())
	{
		return;
	}
	lock(%uids);
	return if exists($uids{$uid});
	my $self = $class->SUPER();
	$self->uid = $uid;
	$self->path = $path;
	$self->url = $url;
	$self->tid = undef;
	{
		lock($self);
		my $thr = threads->create(\&work, $self) or $self->throw($!);
		cond_wait($self);
		unless (defined($self->tid))
		{
			App::cdnget::Exception->throw($thr->join());
			return;
		}
	}
	$uids{$uid} = $self;
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
		$msg = "Downloader ".$self->uid." $msg";
	}
	App::cdnget::Exception->throw($msg, 1);
}

sub work
{
	my $self = shift;
	my $tid = threads->tid();
	my $thr = threads->self();

	my $fh;
	eval
	{
		$fh = FileHandle->new($self->path, ">") or $self->throw($!);
	};
	if ($@)
	{
		lock($self);
		cond_signal($self);
		return $@;
	}

	$self->tid = $tid;
	{
		lock(%downloaders);
		$downloaders{$tid} = $self;
	}
	{
		lock($self);
		cond_signal($self);
	}

	eval
	{
		my $vbuf;
		#my $vbuf = "\0"x$App::cdnget::VBUF_SIZE;
		eval { $fh->setvbuf($vbuf, FileHandle::_IOLBF, $App::cdnget::VBUF_SIZE) };
		$fh->binmode(":bytes");
		my $ua = LWP::UserAgent->new(agent => "p5-App::cdnget/${App::cdnget::VERSION}",
			max_redirect => 1,
			requests_redirectable => [],
			timeout => 15);
		$ua->add_handler(
			response_header => sub
			{
				my ($response, $ua, $h) = @_;
				local ($/, $\) = ("\r\n")x2;
				my $status = $response->{_rc};
				#$self->throw("Status code: $status") unless $status =~ /^[23]\d\d/;
				my $headers = $response->{_headers};
				$fh->print("Status: ", $status) or $self->throw($!);
				$fh->print("Client-URL: ", $self->url) or $self->throw($!);
				$fh->print("Client-Date: ", POSIX::strftime($App::cdnget::DTF_RFC822_GMT, gmtime)) or $self->throw($!);
				for my $header (sort grep $_ !~ /^Client\-/s, $headers->header_field_names())
				{
					$fh->print("$header: ", $headers->header($header)) or $self->throw($!);
				}
				$fh->print("") or $self->throw($!);
				return 1;
			},
		);
		my $response = $ua->get($self->url,
			':read_size_hint' => $App::cdnget::CHUNK_SIZE,
			':content_cb' => sub
			{
				my ($data, $response) = @_;
				$fh->write($data, length($data)) or $self->throw($!);
				return 1;
			},
		);
		die $response->header("X-Died")."\n" if $response->header("X-Died");
		$self->throw("Download failed") if $response->header("Client-Aborted");
	};
	{
		local $@;
		$fh->close();
		{
			lock(%uids);
			delete($uids{$self->uid});
		}
		{
			lock(%downloaders);
			delete $downloaders{$tid};
		}
		lock($self);
		$self->tid = undef;
		$thr->detach();
	}
	if ($@ and (ref($@) or $@ ne "\n"))
	{
		unlink($self->path);
		warn $@;
		return 0;
	}
	return 1;
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
