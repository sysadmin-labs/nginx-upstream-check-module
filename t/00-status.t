# The status endpoint, in each of its three formats.
#
# Deliberately nothing here depends on a check having completed: these
# blocks assert what the peer table says, not what the checker decided.
# The decision over time -- climb, death, return -- is ci/tcpcheck.sh,
# which needs a backend it can stop and start and so cannot live here.

use Test::Nginx::Socket 'no_plan';

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: html lists the peer
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=http;
        check_http_send "HEAD / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx http_4xx;
    }
--- config
    location /status {
        check_status;
    }
--- request
GET /status
--- response_body_like: 127\.0\.0\.1:1984
--- error_code: 200



=== TEST 2: json carries the fields a reader parses
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
GET /status?format=json
--- response_body_like eval
qr/"upstream": "backend".*"name": "127\.0\.0\.1:1984".*"status": "\w+".*"rise": \d+.*"fall": \d+/s
--- error_code: 200



=== TEST 3: csv is one line per peer
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
GET /status?format=csv
--- response_body_like: ^0,backend,127\.0\.0\.1:1984,
--- error_code: 200



=== TEST 4: the format can be fixed in the configuration
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /status {
        check_status json;
    }
--- request
GET /status
--- response_body_like: "total":
--- error_code: 200



=== TEST 5: two upstreams are both in the table
--- http_config
    upstream one {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
    upstream two {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=tcp;
    }
--- config
    location /status {
        check_status json;
    }
--- request
GET /status?format=json
--- response_body_like eval
qr/"upstream": "one".*"upstream": "two"/s
--- error_code: 200
