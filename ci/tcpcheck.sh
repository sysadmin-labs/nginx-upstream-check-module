#!/bin/sh
#
# A tcp check keeps checking.  It is not one handshake and then silence.
#
# The "tcp" check type connects and peeks; it never sends a request, so
# c->requests stays at zero.  need_keepalive was set on that type, so the
# ceiling in clean_event (c->requests < check_keepalive_requests, default 1)
# was never reached, the connection was never closed, and begin_handler
# returned early on pc.connection at every later tick.  Each worker checked
# once and then stopped for good: rise froze at exactly the number of
# workers, and a backend that died afterwards was never noticed.
# (upstream issues #143 #144 #202 #232 #233 #268 #275 #285)
#
# The oracle is the rise counter, not the status.  A peer that is never
# checked again still reads "up", which is why the old defect went unseen
# for nine years.  So this walks the whole cycle -- climb, die, come back --
# and fails if any step stalls.  The http upstream next to it is the
# control: if both stall, the fault is not in the tcp path.
#
# usage: ci/tcpcheck.sh <nginx binary>
#
# TCPCHECK_PORT moves the listener.  Backends are this same nginx binary in
# their own prefixes, so the gate needs nothing that the build did not
# already need.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/tcpcheck
PORT=${TCPCHECK_PORT:-18841}
B1=$((PORT + 1))
B2=$((PORT + 2))
WORKERS=4

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/main/conf" "$WORK/main/logs" \
         "$WORK/b1/conf" "$WORK/b1/logs" \
         "$WORK/b2/conf" "$WORK/b2/logs"

fail=0
note() { echo "  $1" >&2; fail=1; }

cleanup() {
	for p in main b1 b2; do
		[ -f "$WORK/$p/logs/nginx.pid" ] &&
			kill -QUIT "$(cat "$WORK/$p/logs/nginx.pid")" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

# A backend is a bare nginx that answers 200 and nothing else.
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
	        location / { return 200 "$1\n"; }
	    }
	}
	EOF
}
backend_start() { "$NGINX" -p "$WORK/$1" -c conf/nginx.conf; }
backend_stop()  { kill -QUIT "$(cat "$WORK/$1/logs/nginx.pid")" 2>/dev/null || true; }

backend_conf b1 "$B1"
backend_conf b2 "$B2"

cat > "$WORK/main/conf/nginx.conf" <<-EOF
daemon on;
worker_processes $WORKERS;
error_log  logs/error.log warn;
pid        logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    upstream tcpup {
        server 127.0.0.1:$B1;
        server 127.0.0.1:$B2;
        check interval=1000 rise=2 fall=2 timeout=1000 type=tcp;
    }
    upstream httpup {
        server 127.0.0.1:$B1;
        server 127.0.0.1:$B2;
        check interval=1000 rise=2 fall=2 timeout=1000 type=http;
        check_http_send "HEAD / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx;
    }
    server {
        listen $PORT;
        location /status { check_status; }
    }
}
EOF

# One line per peer: "<upstream> <name> <status> <rise> <fall>".
peers() {
	curl -sf "http://127.0.0.1:$PORT/status?format=json" | tr '{' '\n' |
		sed -n 's/.*"upstream": "\([a-z]*\)", "name": "\([^"]*\)", "status": "\([a-z]*\)", "rise": \([0-9]*\), "fall": \([0-9]*\).*/\1 \2 \3 \4 \5/p'
}
field() { peers | awk -v u="$1" -v n="$2" -v f="$3" '$1 == u && $2 == n { print $f }'; }
status_of() { field "$1" "127.0.0.1:$2" 3; }
rise_of()   { field "$1" "127.0.0.1:$2" 4; }

# Wait up to $1 seconds for "<upstream> <port>" to read $3.
wait_status() {
	i=0
	while [ "$i" -lt "$1" ]; do
		[ "$(status_of "$2" "$3")" = "$4" ] && return 0
		i=$((i + 1)); sleep 1
	done
	return 1
}

backend_start b1
backend_start b2
"$NGINX" -p "$WORK/main" -c conf/nginx.conf
sleep 4

if [ -z "$(peers)" ]; then
	echo "ci/tcpcheck.sh: the status endpoint said nothing; nginx up?" >&2
	exit 2
fi

echo "ci/tcpcheck.sh: a tcp check keeps checking" >&2

# 1. It climbs.  This is the step the old defect failed: rise stopped at
#    the worker count and stayed there.
r1=$(rise_of tcpup "$B1")
h1=$(rise_of httpup "$B1")
sleep 6
r2=$(rise_of tcpup "$B1")
h2=$(rise_of httpup "$B1")

[ "$h2" -gt "$h1" ] ||
	note "control: the http check stalled too ($h1 -> $h2); the fault is not in the tcp path"
[ "$r2" -gt "$r1" ] ||
	note "tcp rise stalled at $r2 over six seconds of a one second interval"
[ "$r2" -gt "$WORKERS" ] ||
	note "tcp rise is $r2 with $WORKERS workers: one check per worker and then silence"

# 2. A backend that dies is noticed.
backend_stop b2
wait_status 12 tcpup "$B2" down ||
	note "tcp peer $B2 still reads $(status_of tcpup "$B2") after the backend was stopped"

# 3. And one that comes back is let back in.
backend_start b2
wait_status 15 tcpup "$B2" up ||
	note "tcp peer $B2 still reads $(status_of tcpup "$B2") after the backend returned"

# 4. Checking must not cost a descriptor per round.  The kept connection
#    leaked one per peer and worker (upstream issues #235 #267).
pid=$(cat "$WORK/main/logs/nginx.pid")
if [ -d "/proc/$pid/fd" ]; then
	w=$(pgrep -P "$pid" -f 'worker process' 2>/dev/null | head -1 || true)
	if [ -n "${w:-}" ] && [ -d "/proc/$w/fd" ]; then
		f1=$(ls "/proc/$w/fd" | wc -l)
		sleep 8
		f2=$(ls "/proc/$w/fd" 2>/dev/null | wc -l)
		[ "$f2" -le "$((f1 + 2))" ] ||
			note "a worker went from $f1 to $f2 descriptors in eight seconds"
	fi
fi

if [ "$fail" -ne 0 ]; then
	echo "ci/tcpcheck.sh: FAILED" >&2
	exit 1
fi

echo "ci/tcpcheck.sh: ok (tcp rise $r1 -> $r2, down and up both seen)" >&2
