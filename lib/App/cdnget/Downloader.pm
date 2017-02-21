package App::cdnget::Downloader;
use Object::Base;
use v5.14;
use feature qw(switch);
no if ($] >= 5.018), 'warnings' => 'experimental';
use bytes;
use IO::Handle;
use FileHandle;
use Time::HiRes qw(sleep usleep);
use Thread::Semaphore;
use HTTP::Headers;
use LWP::UserAgent;
use GD;

use App::cdnget;
use App::cdnget::Exception;


BEGIN
{
	our $VERSION     = '0.02';
}


my $maxCount;

my $terminating :shared = 0;
my $terminated :shared = 0;
my $downloaderSemaphore :shared;

our %uids :shared;


attributes qw(:shared uid path url hook tid);


sub init
{
	my ($_maxCount) = @_;
	$maxCount = $_maxCount;
	$downloaderSemaphore = Thread::Semaphore->new($maxCount);
	return 1;
}

sub final
{
	return 1;
}

sub terminate
{
	do
	{
		lock($terminating);
		return 0 if $terminating;
		$terminating = 1;
	};
	$downloaderSemaphore->down($maxCount);
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
	my ($uid, $path, $url, $hook) = @_;
	while (not $downloaderSemaphore->down_timed(1))
	{
		if (terminating())
		{
			return;
		}
	}
	if (terminating())
	{
		$downloaderSemaphore->up();
		return;
	}
	lock(%uids);
	return if exists($uids{$uid});
	my $self = $class->SUPER();
	$self->uid = $uid;
	$self->path = $path;
	$self->url = $url;
	$self->hook = $hook;
	$self->tid = undef;
	{
		lock($self);
		my $thr = threads->create(\&run, $self) or $self->throw($!);
		cond_wait($self);
		unless (defined($self->tid))
		{
			App::cdnget::Exception->throw($thr->join());
		}
		$thr->detach();
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

sub processHook_img
{
	my $self = shift;
	my ($hook, $response, @params) = @_;
	my $headers = $response->{_headers};
	my $img;
	given ($headers->content_type)
	{
		when ("image/png")
		{
			$img = GD::Image->newFromPngData($response->decoded_content) or $self->throw($!);
		}
		when ("image/jpeg")
		{
			$img = GD::Image->newFromJpegData($response->decoded_content) or $self->throw($!);
		}
		default
		{
			$self->throw("Unsupported content type for image");
		}
	}
	$params[0] = $img->width unless defined($params[0]) and $params[0] > 0;
	$params[1] = $img->height unless defined($params[1]) and $params[1] > 0;
	$params[2] = undef unless defined($params[2]) and $params[2] >= 0 and $params[2] <= 100;
	given ($hook)
	{
		when (/^imgresize$/i)
		{
			my $newimg = new GD::Image($params[0], $params[1]) or $self->throw($!);
			$newimg->copyResampled($img, 0, 0, 0, 0, $params[0], $params[1], $img->width, $img->height);
			my $data;
			given ($headers->content_type)
			{
				when ("image/png")
				{
					$data = $newimg->png($params[2]) or $self->throw($!);
				}
				when ("image/jpeg")
				{
					$data = $newimg->jpeg($params[2]) or $self->throw($!);
				}
			}
			return "Status: 200\r\nContent-Type: ".$headers->content_type."\r\nContent-Length: ".length($data)."\r\n\r\n".$data;
		}
		#when (/^imgcrop$/i)
		#{
		#}
		default
		{
			$self->throw("Unsupported img hook");
		}
	}
	return;
}

sub processHook
{
	my $self = shift;
	my ($response) = @_;
	my @params = split /\s+/, $self->hook;
	my $hook = shift @params;
	return unless defined($hook);
	given ($hook)
	{
		when (/^img/i)
		{
			return $self->processHook_img($hook, $response, @params);
		}
		default
		{
			$self->throw("Unsupported hook");
		}
	}
	return;
}

sub run
{
	my $self = shift;
	my $tid = threads->tid();

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
	do
	{
		lock($self);
		cond_signal($self);
	};

	eval
	{
		my $max_size = undef;
		if ($self->hook)
		{
			$max_size = 20*1024*1024;
		}
		$fh->binmode(":bytes") or $self->throw($!);
		my $ua = LWP::UserAgent->new(agent => "p5-App::cdnget/${App::cdnget::VERSION}",
			max_redirect => 1,
			max_size => $max_size,
			requests_redirectable => [],
			timeout => 15);
		my $response_header = sub
			{
				my ($response, $ua) = @_;
				local ($/, $\) = ("\r\n")x2;
				my $status = $response->{_rc};
				my $headers = $response->{_headers};
				$fh->print("Status: ", $status) or $self->throw($!);
				$fh->print("Client-URL: ", $self->url) or $self->throw($!);
				$fh->print("Client-Date: ", POSIX::strftime($App::cdnget::DTF_RFC822_GMT, gmtime)) or $self->throw($!);
				for my $header (sort grep /^(Content\-|Location\:)/i, $headers->header_field_names())
				{
					$fh->print("$header: ", $headers->header($header)) or $self->throw($!);
				}
				$fh->print("") or $self->throw($!);
				return 1;
			};
		my $content_cb = sub
			{
				my ($data, $response) = @_;
				$fh->write($data, length($data)) or $self->throw($!);
				$self->throw("Terminating") if $self->terminating;
				return 1;
			};
		my %matchspec = (':read_size_hint' => $App::cdnget::CHUNK_SIZE);
		unless ($self->hook)
		{
			$ua->add_handler(
				response_header => $response_header,
			);
			$matchspec{':content_cb'} = $content_cb;
		}
		my $response = $ua->get($self->url, %matchspec);
		die $response->header("X-Died")."\n" if $response->header("X-Died");
		$self->throw("Download failed") if $response->header("Client-Aborted");
		if ($self->hook)
		{
			if ($response->is_success)
			{
				my $data = $self->processHook($response);
				$fh->print($data) or $self->throw($!);
			} else
			{
				$response_header->($response, $ua);
				$content_cb->($response->decoded_content, $response);
			}
		}
	};
	do
	{
		local $@;
		$fh->close();
		{
			lock(%uids);
			delete($uids{$self->uid});
		}
		$downloaderSemaphore->up();
		usleep(10*1000); #cond_wait bug
		lock($self);
		$self->tid = undef;
	};
	if ($@)
	{
		unlink($self->path);
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
