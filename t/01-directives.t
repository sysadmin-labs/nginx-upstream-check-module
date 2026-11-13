# The directives parse, and the ones that are wrong are refused.
#
# A configuration that is quietly accepted when it is nonsense is worse
# than one that is refused, because the operator believes the check is
# running.  So the refusals are asserted here too, not only the successes.

use Test::Nginx::Socket 'no_plan';

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: every parameter of check at once
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=3000 rise=2 fall=3 timeout=1000 default_down=false type=http port=1984;
        check_http_send "HEAD / HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx;
        check_keepalive_requests 10;
    }
--- config
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
--- error_code: 200



=== TEST 2: each check type is accepted
--- http_config
    upstream a { server 127.0.0.1:1984; check interval=1000 type=tcp; }
    upstream b { server 127.0.0.1:1984; check interval=1000 type=http; }
    upstream c { server 127.0.0.1:1984; check interval=1000 type=ssl_hello; }
    upstream d { server 127.0.0.1:1984; check interval=1000 type=mysql; }
    upstream e { server 127.0.0.1:1984; check interval=1000 type=ajp; }
    upstream f { server 127.0.0.1:1984; check interval=1000 type=https; }
    upstream g { server 127.0.0.1:1984; check interval=1000 type=udp; }
--- config
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
--- error_code: 200



=== TEST 3: an unknown check type is refused
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 type=carrier_pigeon;
    }
--- config
    location /t { return 200 "ok\n"; }
--- must_die
--- error_log
invalid parameter "type=carrier_pigeon"



=== TEST 4: check_keepalive_requests rejects zero
--- http_config
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 type=http;
        check_keepalive_requests 0;
    }
--- config
    location /t { return 200 "ok\n"; }
--- must_die



=== TEST 5: check_shm_size belongs to http and is taken there
--- http_config
    check_shm_size 2M;
    upstream backend {
        server 127.0.0.1:1984;
        check interval=1000 type=tcp;
    }
--- config
    location /status { check_status; }
--- request
GET /status?format=json
--- response_body_like: "total": 1
--- error_code: 200
