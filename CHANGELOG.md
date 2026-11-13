# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Fixed

- A `type=tcp` check ran once per worker and then stopped for good.  The
  tcp type carried `need_keepalive`, but a tcp check only connects and
  peeks, so it never sends a request and `c->requests` stays at zero.  The
  ceiling in `clean_event` (`c->requests < check_keepalive_requests`,
  default 1) was therefore never reached, the connection was never closed,
  and `begin_handler` returned early on `pc.connection` at every later
  tick.  The visible signature: `rise` froze at exactly the number of
  workers, and because an unchecked peer still reads `up`, a backend that
  died afterwards was never taken out.  The tcp type no longer asks for
  keepalive, which is what it always meant: connect afresh each interval.
  Measured before and after on a four worker server, `rise` 4-4-4-4
  against 5-13-23-33, with failure and recovery both seen again.
  `ci/tcpcheck.sh` is the gate, and it was shown to fail against the old
  behaviour before it was kept.
  (upstream issues #143, #144, #202, #232, #233, #268, #275, #285;
  upstream pull requests #282, #287)

- The same kept connection held one descriptor per peer and per worker for
  the life of the process.  Closing it after each check ends that.
  (upstream issues #235, #267)

- Every per peer pool, and every open check connection, was left behind
  when a process was told to shut down between two ticks.  Releasing them
  is `clear_all_events`, and the only path into it was `need_exit`, which
  only the check handlers call; the module's exit process slot was null.
  So the cleanup ran if a check happened to be in flight at the wrong
  moment, and otherwise did not.  The module answers shutdown now instead
  of hoping for it.  Measured under valgrind: one 4096 byte pool per peer
  whose check type needs one, gone afterwards, with nothing of this
  module left in any trace.
  (upstream issue #235)

- Nothing worked under `master_process off`.  `init_process` returned
  early for anything that was not `NGX_PROCESS_WORKER`, and a server
  running without a master is `NGX_PROCESS_SINGLE`.  No timer was ever
  added, so no check ran; worse, `add_timers` is also where `peer->shm`
  is bound, so every peer kept a null shm and the status page walked into
  it.  Single process mode is now treated as what it is, a worker that
  happens to be alone.  This is also why there was no Test::Nginx suite
  to inherit: Test::Nginx runs the server exactly that way, so every
  block would have failed.
  (upstream issues #147, #225)

### Changed

- The nginx hooks are one patch, `patches/nginx-1.30+.patch`, covering the
  1.30 and 1.31 lines; upstream carried eighteen version specific patches
  that stopped at much older releases.  Verified to apply cleanly to
  nginx 1.30.6 and 1.31.8.
- The module sources moved to `src/`, as in every other repository here.

### Verified

- Builds against nginx 1.30.6 and 1.31.8 on Linux with gcc 11.5, under
  nginx's own `-Werror`, without a warning from this module.
