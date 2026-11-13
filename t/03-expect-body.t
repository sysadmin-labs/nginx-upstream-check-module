# check_http_expect_body, as far as a suite can see it.
#
# Only the configuration is asserted here.  Whether a peer actually goes
# down because its body said the wrong thing is a decision the checker
# makes on a timer, against a backend that has to be started and stopped,
# and that is ci/features.sh.

use Test::Nginx::Socket 'no_plan';

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: it is accepted next to the other http check directives
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=http;
        check_http_send "GET / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;
        check_http_expect_body "status: ok";
    }
--- config
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
--- error_code: 200



=== TEST 2: an empty expectation is refused
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=http;
        check_http_expect_body "";
    }
--- config
    location /t { return 200 "ok\n"; }
--- must_die
--- error_log
takes a non-empty string



=== TEST 3: without it the peer table still renders
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 rise=1 fall=2 timeout=1000 type=http;
    }
--- config
    location /status { check_status; }
--- request
GET /status?format=json
--- response_body_like: "name": "127\.0\.0\.1:1984"
--- error_code: 200
