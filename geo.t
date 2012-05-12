#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx geo module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http geo/)->plan(6);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon         off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    geo $geo {
        127.0.0.0/8  loopback;
        192.0.2.0/24 test;
        0.0.0.0/0    world;
    }

    geo $arg_ip $geo_from_arg {
        default      default;

        127.0.0.0/8  loopback;
        192.0.2.0/24 test;
    }

    geo $geo_proxy {
        default      default;
        proxy        127.0.0.1/32;
        127.0.0.0/8  loopback;
        192.0.2.0/24 test;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            add_header X-Geo $geo;
            add_header X-Arg $geo_from_arg;
            add_header X-XFF $geo_proxy;
        }
    }
}

EOF

$t->write_file('1', '');
$t->run();

###############################################################################

like(http_get('/1'), qr/^X-Geo: loopback/m, 'geo');

like(http_get('/1?ip=192.0.2.1'), qr/^X-Arg: test/m, 'geo from variable');
like(http_get('/1?ip=10.0.0.1'), qr/^X-Arg: default/m, 'geo default');

like(http_xff('192.0.2.1'), qr/^X-XFF: test/m, 'geo proxy');
like(http_xff('10.0.0.1'), qr/^X-XFF: default/m, 'geo proxy default');
like(http_xff('10.0.0.1, 192.0.2.1'), qr/^X-XFF: test/m, 'geo proxy long');

###############################################################################

sub http_xff {
	my ($xff) = @_;
	return http(<<EOF);
GET /1 HTTP/1.0
Host: localhost
X-Forwarded-For: $xff

EOF
}

###############################################################################
