#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for stream proxy module with IPv6 haproxy protocol.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use Socket qw/ $CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream ipv6/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    server {
        listen          127.0.0.1:8080;
        proxy_pass      [::1]:8080;
    }

    server {
        listen          127.0.0.1:8081;
        proxy_pass      [::1]:8081;
    }

    server {
        listen          [::1]:8080;
        proxy_pass      127.0.0.1:8082;
        proxy_protocol  on;
    }

    server {
        listen          [::1]:8081;
        proxy_pass      127.0.0.1:8082;
    }
}

EOF

$t->run_daemon(\&stream_daemon);
$t->try_run('no inet6 support or stream proxy_protocol')->plan(2);
$t->waitforsocket('127.0.0.1:8082');

###############################################################################

like(stream_get('close'), qr/PROXY TCP6 ::1 ::1 \d+ 8080$CRLF/, 'protocol on');
unlike(stream_get('close', '127.0.0.1:8081'), qr/PROXY/, 'protocol off');

###############################################################################

sub stream_get {
	my ($data, $peer) = @_;

	my $s = stream_connect($peer);
	stream_write($s, $data);

	$data = '';
	while (my $buf = stream_read($s)) {
		$data .= $buf;
	}

	return $data;
}

sub stream_connect {
	my $peer = shift;
	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => $peer || '127.0.0.1:8080'
	)
		or die "Can't connect to nginx: $!\n";

	return $s;
}

sub stream_write {
	my ($s, $message) = @_;

	local $SIG{PIPE} = 'IGNORE';

	$s->blocking(0);
	while (IO::Select->new($s)->can_write(1.5)) {
		my $n = $s->syswrite($message);
		last unless $n;
		$message = substr($message, $n);
		last unless length $message;
	}

	if (length $message) {
		$s->close();
	}
}

sub stream_read {
	my ($s) = @_;
	my ($buf);

	$s->blocking(0);
	if (IO::Select->new($s)->can_read(3)) {
		$s->sysread($buf, 1024);
	};

	log_in($buf);
	return $buf;
}

###############################################################################

sub stream_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:8082',
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($server);

	local $SIG{PIPE} = 'IGNORE';

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($server == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif (stream_handle_client($fh)) {
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

sub stream_handle_client {
	my ($client) = @_;

	log2c("(new connection $client)");

	$client->sysread(my $buffer, 65536) or return 1;

	log2i("$client $buffer");

	log2o("$client $buffer");

	$client->syswrite($buffer);

	return $buffer =~ /close/;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
