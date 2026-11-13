#!/bin/sh
#
# The checks that look past the status code.
#
# A status code says the server answered, not that what it answers with is
# any good: an application that has lost its database usually still returns
# 200 from the front of the stack.  check_http_expect_body is for that, and
# the only honest way to show it works is to put the same backend through
# both: with the expectation it has to go down, without it the very same
# backend has to stay up.  A test that only shows the first half would
# equally well pass on a module that marks everything down.
#
# The second one is the https check type, and it has the same shape of
# control: a TLS backend has to come up, and a plain HTTP backend on the
# next port has to go down.  Without that second half an "https" check
# that quietly spoke plain HTTP would pass.  It is skipped, not failed,
# where nginx was built without ssl or openssl(1) is missing.
#
# The third is the udp check type, with the same shape again: a port that
# answers has to come up and a port with nothing on it has to go down.
# It needs something that will answer a datagram, which is python3 here,
# and is skipped where that is missing.
#
# usage: ci/features.sh <nginx binary>
#
# FEATURES_PORT moves the listener.  Backends are this same nginx binary in
# their own prefixes, so the gate needs nothing the build did not need.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/features
PORT=${FEATURES_PORT:-18921}
PGOOD=$((PORT + 1))
PBAD=$((PORT + 2))
PTLS=$((PORT + 3))
PPLAIN=$((PORT + 4))
PUDP=$((PORT + 5))
PNOUDP=$((PORT + 6))

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/main/conf" "$WORK/main/logs" \
         "$WORK/good/conf" "$WORK/good/logs" \
         "$WORK/bad/conf" "$WORK/bad/logs" \
         "$WORK/tls/conf" "$WORK/tls/logs" \
         "$WORK/plain/conf" "$WORK/plain/logs"

fail=0
note() { echo "  $1" >&2; fail=1; }

cleanup() {
	for p in main good bad tls plain; do
		[ -f "$WORK/$p/logs/nginx.pid" ] &&
			kill -QUIT "$(cat "$WORK/$p/logs/nginx.pid")" 2>/dev/null || true
	done
	[ -f "$WORK/echo.pid" ] &&
		kill "$(cat "$WORK/echo.pid")" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Both backends answer 200.  They differ only in what they say.
backend_conf() {
	cat > "$WORK/$1/conf/nginx.conf" <<-EOF
	daemon on;
	worker_processes 1;
	error_log  logs/error.log crit;
	pid        logs/nginx.pid;
	events { worker_connections 64; }
	http {
	    access_log off;
	    server {
	        listen $2;
	        location / { return 200 "$3"; }
	    }
	}
	EOF
}
backend_conf good "$PGOOD" 'service status: ok'
backend_conf bad  "$PBAD"  'service status: broken'

# https is only gated where the server can speak it and we can make a
# certificate.  A gate that silently tests nothing is worse than one that
# says it stepped aside.
https_up=
if ! "$NGINX" -V 2>&1 | grep -q -- --with-http_ssl_module; then
	echo "ci/features.sh: nginx has no ssl; skipping the https check" >&2
elif ! command -v openssl > /dev/null; then
	echo "ci/features.sh: no openssl(1); skipping the https check" >&2
else
	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
		-days 2 -subj /CN=localhost > /dev/null 2>&1 || {
		echo "ci/features.sh: could not make a certificate; skipping https" >&2
		false
	} && https_up=yes
fi

if [ -n "$https_up" ]; then
	cat > "$WORK/tls/conf/nginx.conf" <<-EOF
	daemon on;
	worker_processes 1;
	error_log  logs/error.log crit;
	pid        logs/nginx.pid;
	events { worker_connections 64; }
	http {
	    access_log off;
	    server {
	        listen $PTLS ssl;
	        ssl_certificate     $WORK/cert.pem;
	        ssl_certificate_key $WORK/key.pem;
	        location / { return 200 "tls"; }
	    }
	}
	EOF
	backend_conf plain "$PPLAIN" 'plain'

	HTTPS_BLOCK="
    upstream tls {
        server 127.0.0.1:$PTLS;
        server 127.0.0.1:$PPLAIN;
        check interval=500 rise=1 fall=1 timeout=2000 type=https;
        check_http_send \"GET / HTTP/1.0\\r\\n\\r\\n\";
        check_http_expect_alive http_2xx;
    }"
else
	HTTPS_BLOCK=
fi

udp_up=
if ! command -v python3 > /dev/null; then
	echo "ci/features.sh: no python3 to answer a datagram; skipping udp" >&2
else
	cat > "$WORK/echo.py" <<-'PYEOF'
	import socket, sys
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.bind(("127.0.0.1", int(sys.argv[1])))
	while True:
	    d, a = s.recvfrom(1024)
	    s.sendto(b"pong\n", a)
	PYEOF
	udp_up=yes
	UDP_BLOCK="
    upstream dgram {
        server 127.0.0.1:$PUDP;
        server 127.0.0.1:$PNOUDP;
        check interval=500 rise=1 fall=1 timeout=1000 type=udp;
        check_http_send \"ping\\n\";
    }"
fi
[ -n "$udp_up" ] || UDP_BLOCK=

cat > "$WORK/main/conf/nginx.conf" <<-EOF
daemon on;
worker_processes 2;
error_log  logs/error.log warn;
pid        logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;

    # The same two backends, once judged on the body and once not.
    upstream body {
        server 127.0.0.1:$PGOOD;
        server 127.0.0.1:$PBAD;
        check interval=500 rise=1 fall=1 timeout=1000 type=http;
        check_http_send "GET / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;
        check_http_expect_body "status: ok";
    }
    upstream code {
        server 127.0.0.1:$PGOOD;
        server 127.0.0.1:$PBAD;
        check interval=500 rise=1 fall=1 timeout=1000 type=http;
        check_http_send "GET / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;
    }

$HTTPS_BLOCK
$UDP_BLOCK

    server {
        listen $PORT;
        location /status { check_status; }
    }
}
EOF

status_of() {
	curl -sf "http://127.0.0.1:$PORT/status?format=json" | tr '{' '\n' |
		sed -n "s/.*\"upstream\": \"$1\", \"name\": \"127.0.0.1:$2\", \"status\": \"\([a-z]*\)\".*/\1/p"
}

wait_status() {
	i=0
	while [ "$i" -lt 20 ]; do
		[ "$(status_of "$1" "$2")" = "$3" ] && return 0
		i=$((i + 1)); sleep 1
	done
	return 1
}

"$NGINX" -p "$WORK/good" -c conf/nginx.conf
"$NGINX" -p "$WORK/bad"  -c conf/nginx.conf
if [ -n "$https_up" ]; then
	"$NGINX" -p "$WORK/tls"   -c conf/nginx.conf
	"$NGINX" -p "$WORK/plain" -c conf/nginx.conf
fi
if [ -n "$udp_up" ]; then
	python3 "$WORK/echo.py" "$PUDP" > /dev/null 2>&1 &
	echo $! > "$WORK/echo.pid"
	sleep 1
fi
"$NGINX" -p "$WORK/main" -c conf/nginx.conf
sleep 3

if [ -z "$(status_of body "$PGOOD")" ]; then
	echo "ci/features.sh: the status endpoint said nothing; nginx up?" >&2
	exit 2
fi

echo "ci/features.sh: a check can look past the status code" >&2

# The expectation is met: up.
wait_status body "$PGOOD" up ||
	note "expect_body: the backend that says the right thing reads $(status_of body "$PGOOD")"

# The expectation is not met, although the code is 2xx: down.
wait_status body "$PBAD" down ||
	note "expect_body: the backend that says the wrong thing reads $(status_of body "$PBAD")"

# The control.  Same backend, same 200, no expectation: up.  Without this
# the gate above would pass on a module that simply marks everything down.
wait_status code "$PBAD" up ||
	note "control: the same backend reads $(status_of code "$PBAD") with no body expected, so the body is not what decided it"

if [ -n "$https_up" ]; then
	echo "ci/features.sh: an https check really speaks tls" >&2

	wait_status tls "$PTLS" up ||
		note "https: the tls backend reads $(status_of tls "$PTLS")"

	# The control.  A plain HTTP server on the next port must fail the
	# handshake; if it came up, the check never spoke tls at all.
	wait_status tls "$PPLAIN" down ||
		note "https: the plain backend reads $(status_of tls "$PPLAIN"), so no handshake was required"
fi

if [ -n "$udp_up" ]; then
	echo "ci/features.sh: a udp check hears an answer, or does not" >&2

	wait_status dgram "$PUDP" up ||
		note "udp: the port that answers reads $(status_of dgram "$PUDP")"

	# The control.  Nothing is listening there, so the kernel answers
	# with ICMP unreachable and the check has to notice.
	wait_status dgram "$PNOUDP" down ||
		note "udp: the port with nothing on it reads $(status_of dgram "$PNOUDP")"
fi

if [ "$fail" -ne 0 ]; then
	echo "ci/features.sh: FAILED" >&2
	echo "ci/features.sh: the servers and their logs are under $WORK" >&2
	exit 1
fi

cleanup
sleep 1
rm -rf "$WORK"

echo "ci/features.sh: ok (body expectation decides, and only where it is asked for)" >&2
