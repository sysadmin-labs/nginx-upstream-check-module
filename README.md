# nginx-upstream-check-module

[![Build & Test][build-test-badge]][build-test-link]
[![TCP check][tcpcheck-badge]][tcpcheck-link]
[![Balancers][balancers-badge]][balancers-link]
[![Reload][reload-badge]][reload-link]
[![Features][features-badge]][features-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/build-test.yml
[tcpcheck-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/tcpcheck.yml/badge.svg
[tcpcheck-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/tcpcheck.yml
[balancers-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/balancers.yml/badge.svg
[balancers-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/balancers.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/reload.yml
[features-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/features.yml/badge.svg
[features-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/features.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/freebsd.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/valgrind.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-upstream-check-module/actions/workflows/lint.yml

Active health checks for nginx upstreams: nginx probes each backend on a
timer and takes a failing one out of the balancer before a request lands
on it, instead of discovering the failure with somebody's request.

## How this differs from every other module here

This module **patches nginx itself**. Stock nginx has no way for a module
to feed per-peer health into peer selection, so the check state is wired
into the balancers by patch:

- `src/http/ngx_http_upstream_round_robin.c` and its header
- `src/http/modules/ngx_http_upstream_hash_module.c`
- `src/http/modules/ngx_http_upstream_ip_hash_module.c`
- `src/http/modules/ngx_http_upstream_least_conn_module.c`

The patch in `patches/` is guarded with `#if (NGX_HTTP_UPSTREAM_CHECK)`, so
a patched nginx built without this module behaves exactly as before. The
module is therefore **built into nginx statically**; it is not a loadable
module, and it cannot be one without those hooks.

## Requirements

nginx 1.30.x or 1.31.x. One patch covers both lines.

## Building

```sh
tar xzf nginx-1.30.6.tar.gz
cd nginx-1.30.6
patch -p0 < /path/to/nginx-upstream-check-module/patches/nginx-1.30+.patch
./configure --add-module=/path/to/nginx-upstream-check-module
make && make install
```

## Quick start

```nginx
http {
    upstream backend {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;

        check interval=3000 rise=2 fall=3 timeout=1000 type=http;
        check_http_send "HEAD / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx;
    }

    server {
        listen 80;

        location / {
            proxy_pass http://backend;
        }

        location /status {
            check_status;
            access_log off;
        }
    }
}
```

`/status` serves the peer table as HTML, and as JSON with `?format=json`:

```json
{"servers": {
  "total": 2,
  "generation": 1,
  "server": [
    {"index": 0, "upstream": "backend", "name": "127.0.0.1:8081",
     "status": "up", "rise": 23, "fall": 0, "type": "http", "port": 0}
  ]
}}
```

## Directives

### check

|Syntax |`check interval=milliseconds [fall=count] [rise=count] [timeout=milliseconds] [default_down=true\|false] [type=tcp\|http\|ssl_hello\|mysql\|ajp] [port=check_port]`|
|-------|---|
|Default|`interval=30000 fall=5 rise=2 timeout=1000 default_down=true type=tcp`|
|Context|upstream|

Adds the health check. `fall` consecutive failures take a peer out,
`rise` consecutive successes put it back. `port` checks a different port
than the one traffic goes to.

The check types:

|Type|What it does|
|----|---|
|`tcp`|Opens a connection each interval and closes it again. Cheap, and it only proves the port accepts connections.|
|`http`|Sends `check_http_send` and matches the status against `check_http_expect_alive`.|
|`https`|A full TLS handshake, then exactly the `http` check through it. Needs an nginx built `--with-http_ssl_module`.|
|`ssl_hello`|Writes a TLS client hello onto a plain connection and looks for a server hello in the reply. Cheaper than `https`, and it proves only that something at the other end speaks TLS, not that it serves.|
|`udp`|Sends `check_http_send` as a datagram and counts any reply as alive. A port with nothing on it answers with ICMP unreachable, which the connected socket reports as an error.|
|`mysql`|Expects a MySQL greeting.|
|`ajp`|Sends an AJP CPing and expects a CPong.|

### check_http_send

|Syntax |`check_http_send request`|
|-------|---|
|Default|`"GET / HTTP/1.0\r\n\r\n"`|
|Context|upstream|

### check_http_expect_alive

|Syntax |`check_http_expect_alive [http_2xx \| http_3xx \| http_4xx \| http_5xx]`|
|-------|---|
|Default|`http_2xx http_3xx`|
|Context|upstream|

Which response statuses count as alive.

There is no protocol for `udp` to agree on: you choose what goes out
with `check_http_send`, and a datagram coming back is the whole test. It
says the far side is listening and willing to answer; what the answer
means is not something this check can judge, so it does not pretend to.

The `https` type does not verify the certificate. This is a liveness
probe against a server already named in the configuration, and a probe
that called a backend dead because its certificate had expired would take
the upstream out for a reason that has nothing to do with whether it
serves. Whether to trust what the backend sends belongs to
`proxy_ssl_verify`, where the traffic is. It also never keeps the
connection: every check is its own handshake.

### check_http_expect_body

|Syntax |`check_http_expect_body string`|
|-------|---|
|Default|-|
|Context|upstream|

The response body has to contain `string`, or the peer is taken out even
though its status code was fine. A status code says the server answered,
not that what it answers with is any good: an application that has lost
its database usually still returns 200 from the front of the stack.

The match is a plain substring, case sensitive, and it is looked for after
the end of the headers, so a match in a header does not count. Send a
request that has a body to match: the default `check_http_send` is a
`GET`, but if you changed it to a `HEAD` there will be nothing to look at
and the peer will go down.

```nginx
check_http_send "GET /health HTTP/1.0\r\n\r\n";
check_http_expect_alive http_2xx;
check_http_expect_body "\"database\": \"ok\"";
```

### check_keepalive_requests

|Syntax |`check_keepalive_requests number`|
|-------|---|
|Default|`1`|
|Context|upstream|

How many checks share one connection before it is closed. The default of
`1` gives every check its own connection. It has no effect on `tcp`
checks, which always connect afresh.

### check_shm_size

|Syntax |`check_shm_size size`|
|-------|---|
|Default|`1M`|
|Context|http|

The shared memory holding the peer states. Raise it for very large
upstreams.

### check_status

|Syntax |`check_status [html\|csv\|json\|prometheus]`|
|-------|---|
|Default|`html`|
|Context|location|

Serves the peer table. The format can also be chosen per request with
`?format=`.

`prometheus` serves the exposition format, with the content type a
scraper expects, as three gauges plus the shared memory generation:

```
# HELP nginx_upstream_check_status Whether the checker holds the peer up (1) or down (0).
# TYPE nginx_upstream_check_status gauge
nginx_upstream_check_status{upstream="backend",server="127.0.0.1:8081",type="http"} 1
nginx_upstream_check_rise_count{upstream="backend",server="127.0.0.1:8081",type="http"} 23
nginx_upstream_check_fall_count{upstream="backend",server="127.0.0.1:8081",type="http"} 0
```

```nginx
location /metrics {
    check_status prometheus;
    access_log off;
}
```

## License

BSD 2-Clause. See `LICENSE`.
