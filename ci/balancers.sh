#!/bin/sh
#
# Every balancer honours the check, not just round robin.
#
# The module reaches into peer selection by patching nginx, and each
# balancer has its own selection function: round robin, hash, hash
# consistent (a second function in the same module, easy to miss), ip_hash
# and least_conn.  A hook that went into one and not another would leave
# that balancer sending requests to a backend the checker has already
# written off, which is what upstream issues #210 (consistent hash) and
# #221 (ip_hash) describe.
#
# The oracle is the response, and it only means something with
# proxy_next_upstream off.  With retries on, nginx quietly tries the other
# backend and the request succeeds whether or not the balancer ever looked
# at the check state -- the test would pass while proving nothing.  Off, a
# request handed to a dead backend is a 502, and that is the signal.
#
# Per balancer: see which backends it really uses, stop one of those, wait
# for the checker to mark it down, and then require that every request
# still succeeds and that none is answered by the one that is gone.
#
# usage: ci/balancers.sh <nginx binary>
#
# BALANCERS_PORT moves the listener.  Backends are this same nginx binary
# in their own prefixes.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/balancers
PORT=${BALANCERS_PORT:-18881}
PA=$((PORT + 1))
PB=$((PORT + 2))
ROUNDS=20

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/main/conf" "$WORK/main/logs" \
         "$WORK/a/conf" "$WORK/a/logs" "$WORK/b/conf" "$WORK/b/logs"

fail=0
note() { echo "  $1" >&2; fail=1; }

cleanup() {
	for p in main a b; do
		[ -f "$WORK/$p/logs/nginx.pid" ] &&
			kill -QUIT "$(cat "$WORK/$p/logs/nginx.pid")" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

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
	        location / { return 200 "$1"; }
	    }
	}
	EOF
}
backend_start() { "$NGINX" -p "$WORK/$1" -c conf/nginx.conf; }
backend_stop()  { kill -QUIT "$(cat "$WORK/$1/logs/nginx.pid")" 2>/dev/null || true; }

backend_conf a "$PA"
backend_conf b "$PB"

# One upstream per balancer, all over the same two backends.  check_status
# names the upstream, so the peer state can be read per balancer.
cat > "$WORK/main/conf/nginx.conf" <<-EOF
daemon on;
worker_processes 2;
error_log  logs/error.log warn;
pid        logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;

    upstream rr   { server 127.0.0.1:$PA; server 127.0.0.1:$PB;
                    check interval=500 rise=1 fall=1 timeout=500 type=http;
                    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
                    check_http_expect_alive http_2xx http_3xx; }
    upstream hsh  { hash \$arg_k;
                    server 127.0.0.1:$PA; server 127.0.0.1:$PB;
                    check interval=500 rise=1 fall=1 timeout=500 type=http;
                    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
                    check_http_expect_alive http_2xx http_3xx; }
    upstream chsh { hash \$arg_k consistent;
                    server 127.0.0.1:$PA; server 127.0.0.1:$PB;
                    check interval=500 rise=1 fall=1 timeout=500 type=http;
                    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
                    check_http_expect_alive http_2xx http_3xx; }
    upstream iph  { ip_hash;
                    server 127.0.0.1:$PA; server 127.0.0.1:$PB;
                    check interval=500 rise=1 fall=1 timeout=500 type=http;
                    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
                    check_http_expect_alive http_2xx http_3xx; }
    upstream lc   { least_conn;
                    server 127.0.0.1:$PA; server 127.0.0.1:$PB;
                    check interval=500 rise=1 fall=1 timeout=500 type=http;
                    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
                    check_http_expect_alive http_2xx http_3xx; }

    server {
        listen $PORT;

        # No retry.  With one, nginx covers for a balancer that ignored
        # the check and the gate would prove nothing.
        proxy_next_upstream off;
        proxy_connect_timeout 1s;
        proxy_read_timeout 1s;

        location /rr   { proxy_pass http://rr; }
        location /hsh  { proxy_pass http://hsh; }
        location /chsh { proxy_pass http://chsh; }
        location /iph  { proxy_pass http://iph; }
        location /lc   { proxy_pass http://lc; }
        location /status { check_status; }
    }
}
EOF

# "<upstream> <name> <status>" per peer.
peer_status() {
	curl -sf "http://127.0.0.1:$PORT/status?format=json" | tr '{' '\n' |
		sed -n "s/.*\"upstream\": \"$1\", \"name\": \"127.0.0.1:$2\", \"status\": \"\([a-z]*\)\".*/\1/p"
}

wait_peer() {
	i=0
	while [ "$i" -lt 20 ]; do
		[ "$(peer_status "$2" "$3")" = "$4" ] && return 0
		i=$((i + 1)); sleep 1
	done
	return 1
}

# Which backends does this location actually use, over $ROUNDS keys?
used() {
	i=0; seen=
	while [ "$i" -lt "$ROUNDS" ]; do
		body=$(curl -sf "http://127.0.0.1:$PORT/$1?k=$i" 2>/dev/null || echo "-")
		case " $seen " in *" $body "*) ;; *) seen="$seen $body" ;; esac
		i=$((i + 1))
	done
	echo "$seen" | tr -s ' '
}

backend_start a
backend_start b
"$NGINX" -p "$WORK/main" -c conf/nginx.conf
sleep 3

if [ -z "$(peer_status rr "$PA")" ]; then
	echo "ci/balancers.sh: the status endpoint said nothing; nginx up?" >&2
	exit 2
fi

echo "ci/balancers.sh: every balancer honours the check" >&2

for spec in "rr round-robin" "hsh hash" "chsh hash-consistent" "iph ip_hash" "lc least_conn"; do
	loc=${spec%% *}
	label=${spec#* }

	# Both backends have to be up before each round, so a previous round
	# cannot be what makes this one look good.
	wait_peer 1 "$loc" "$PA" up || note "$label: peer a never came up"
	wait_peer 1 "$loc" "$PB" up || note "$label: peer b never came up"

	before=$(used "$loc")
	case "$before" in
	*-*)
		note "$label: a request failed while both backends were up ($before)"
		continue
		;;
	esac

	# Stop one the balancer really uses.  ip_hash pins a client to one
	# peer, so stopping the other would prove nothing at all.
	case "$before" in
	*b*) victim=b; vport=$PB; survivor=a ;;
	*a*) victim=a; vport=$PA; survivor=b ;;
	*)   note "$label: no backend answered ($before)"; continue ;;
	esac

	backend_stop "$victim"
	if ! wait_peer 1 "$loc" "$vport" down; then
		note "$label: the checker never marked $victim down"
		backend_start "$victim"
		continue
	fi

	after=$(used "$loc")
	backend_start "$victim"

	case "$after" in
	*"$victim"*)
		note "$label: still answered by $victim after it was marked down ($after)"
		;;
	*-*)
		note "$label: a request failed although $survivor was up ($after)"
		;;
	*"$survivor"*)
		echo "  $label: ok, all $ROUNDS went to $survivor" >&2
		;;
	*)
		note "$label: nothing answered ($after)"
		;;
	esac
done

if [ "$fail" -ne 0 ]; then
	echo "ci/balancers.sh: FAILED" >&2
	echo "ci/balancers.sh: the servers and their logs are under $WORK" >&2
	exit 1
fi

cleanup
sleep 1
rm -rf "$WORK"

echo "ci/balancers.sh: ok" >&2
