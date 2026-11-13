# nginx-upstream-check-module

[![Build & Test][build-test-badge]][build-test-link]
[![TCP check][tcpcheck-badge]][tcpcheck-link]
[![Balancers][balancers-badge]][balancers-link]
[![Reload][reload-badge]][reload-link]
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
|`ssl_hello`|Sends a TLS client hello and expects a server hello.|
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

|Syntax |`check_status [html\|csv\|json]`|
|-------|---|
|Default|`html`|
|Context|location|

Serves the peer table. The format can also be chosen per request with
`?format=`.

## License

BSD 2-Clause. See `LICENSE`.
