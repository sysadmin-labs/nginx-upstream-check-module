# The prometheus exposition format.
#
# What is asserted is the shape a scraper relies on: a HELP and a TYPE
# line per metric, every series of that metric underneath it, and the
# content type prometheus looks for.  A format that merely contains the
# numbers somewhere is not a format a scraper can read.

use Test::Nginx::Socket 'no_plan';

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: the content type is the one a scraper expects
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /metrics {
        check_status prometheus;
    }
--- request
GET /metrics
--- response_headers
Content-Type: text/plain; version=0.0.4; charset=utf-8
--- error_code: 200



=== TEST 2: each metric carries its HELP and TYPE
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /metrics {
        check_status prometheus;
    }
--- request
GET /metrics
--- response_body_like eval
qr/# HELP nginx_upstream_check_status .*\n# TYPE nginx_upstream_check_status gauge\n/
--- error_code: 200



=== TEST 3: the series carry upstream, server and type as labels
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /metrics {
        check_status prometheus;
    }
--- request
GET /metrics
--- response_body_like eval
qr/nginx_upstream_check_status\{upstream="backend",server="127\.0\.0\.1:1984",type="tcp"\} [01]\n/
--- error_code: 200



=== TEST 4: all three gauges and the generation are there
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /metrics {
        check_status prometheus;
    }
--- request
GET /metrics
--- response_body_like eval
qr/nginx_upstream_check_generation \d+.*nginx_upstream_check_status\{.*nginx_upstream_check_rise_count\{.*nginx_upstream_check_fall_count\{/s
--- error_code: 200



=== TEST 5: the format can also be asked for per request
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /status {
        check_status;
    }
--- request
GET /status?format=prometheus
--- response_body_like: ^# HELP nginx_upstream_check_generation
--- error_code: 200



=== TEST 6: two upstreams keep their own series
--- http_config
    upstream one {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
    upstream two {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=http;
    }
--- config
    location /metrics {
        check_status prometheus;
    }
--- request
GET /metrics
--- response_body_like eval
qr/upstream="one",server="127\.0\.0\.1:1984",type="tcp".*upstream="two",server="127\.0\.0\.1:1984",type="http"/s
--- error_code: 200
