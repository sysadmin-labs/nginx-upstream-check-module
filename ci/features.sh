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

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/main/conf" "$WORK/main/logs" \
         "$WORK/good/conf" "$WORK/good/logs" \
         "$WORK/bad/conf" "$WORK/bad/logs"

fail=0
note() { echo "  $1" >&2; fail=1; }

cleanup() {
	for p in main good bad; do
		[ -f "$WORK/$p/logs/nginx.pid" ] &&
			kill -QUIT "$(cat "$WORK/$p/logs/nginx.pid")" 2>/dev/null || true
	done
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

if [ "$fail" -ne 0 ]; then
	echo "ci/features.sh: FAILED" >&2
	echo "ci/features.sh: the servers and their logs are under $WORK" >&2
	exit 1
fi

cleanup
sleep 1
rm -rf "$WORK"

echo "ci/features.sh: ok (body expectation decides, and only where it is asked for)" >&2
