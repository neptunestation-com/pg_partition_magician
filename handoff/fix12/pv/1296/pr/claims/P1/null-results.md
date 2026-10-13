# P1 null results: PR #1296 (regrain swap deferred by another database's transaction names it)

Review tree only; harness `pgpm_prv-15` (PostgreSQL 15, pgTAP, dblink). The timescale container named in the
brief (`pgpm_prv-timescale`) was not running, so the cutover path was read, not run.

## Lens: fresh surface

- `pgpm._snapshot_wait` (7721-7855), read whole with its comment. The wait predicate, the pass/refuse-at-once
  rules, the round-9 marker and the budget are unchanged by the diff; the change is the holder lookup and the
  second RAISE. Ran tests/333 against the tree: 26/27, assertion 8 fails (the holder is never named). Root
  cause is the `a.datid = v_db` filter in the holder lookup (line 7827): claim P1-01. The second RAISE's
  argument list (p_what, v_n, v_pid, v_open, pids, v_holder, p_range, p_where) matches its eight `%`.
- The refusal of the issue's ask (pass a session whose xmin another database's transaction explains): sound as
  far as the catalog goes. I checked that a snapshot's xmin is pulled down only by transactions holding an
  xid (so a read-only old snapshot in another database is not a holder, and the holder lookup's
  `backend_xid is not null` is the right filter), and tests/333's B/I pair shows the activity view cannot
  separate the issue's reader from an importer. No safe rule found; the over-wait stands, as the PR says.
- `backend_xid` and `datname` visibility: a non-superuser without `pg_read_all_stats` sees another role's
  `backend_xid` and `backend_xmin` in another database (probed with a throwaway role; `backend_type`, `state`
  and `xact_start` are masked, as the docs say), so the holder lookup works for the table's plain owner.
- `pgpm._regrain_snapshot_wait` (7858-7864): unchanged pass-through of `config.regrain_written_xid`; nothing to
  probe beyond its caller, which P1-01 and P1-02 drive.
- maintain's `skip_regrain` row (13476) logs `left(sqlerrm, 200)`; the head to "in database " is 206
  characters with one pid listed, so the holder clause never reaches the log: claim P1-02 (reproduced with a
  same-database REPEATABLE READ writer as the holder, so it is independent of P1-01's datid filter).
- A READ COMMITTED writer with an old xid and NO snapshot held (between statements) is not listed and the swap
  goes through: correct (its next snapshot sees the copies); noted here because my first P1-02 draft tripped
  on it.
- tests/328 pins: every by-xid pin is head-only (`... (oldest: pid P,%` or a regex ending at the pid list), so
  the holder clause cannot break them, parallel runner or not.
- docs/reference.md 1000-1003, 1973-1974, 1986-2004, 2063-2064 and CHANGELOG 5-16 read against the code: the
  wording of the wait (other databases' sessions never listed, their transactions count through the xmin,
  CIC comparison, the own-xid case names no holder) matches `_snapshot_wait`. The two claims above are where
  the docs and the code part.
- test.sh 310-345, 1280: the `alone` list runs after `wait`, in its own clone, its log printed with the rest
  and counted in `failed`; `${alone[@]+...}` guards bash 3.2's empty-array expansion; the guard is appended to
  the perf list. Held on reading.
- bench/snapshot_wait_foreign_floor_holder.sh: installs the given install.sql, runs tests/333 by pg_prove, counts
  TAP lines so a run that never reached the database is not a pass, drops `${DB}_x` after terminating its
  backends. Held on reading; its mutations cannot be run here (bench/mutations removed).

## Lens: concurrency and locks

- The holder lookup runs once, at the budget, after `v_still` was read in the same poll with
  `pg_stat_clear_snapshot()` before it: a holder that ends between the two reads yields no clause and the old
  message, which is right (it is no longer the floor). No lock is taken by the lookup; the advisory marker and
  the pass/refuse-at-once rules are untouched.
- Prepared transactions: `max_prepared_transactions = 0` in the harness, so the `pg_prepared_xacts` branch
  could not be run; read only (`age(p.transaction) >= age(v_limit)`, `%L` on the gid).
- `from_hypertable_cutover` (pgpm_hypertable 1618-2399): the one other caller, at 1816, after the copy's lock
  and before the source's, under `p_lock_timeout`; it reaches the same lookup, so P1-01's datid filter leaves
  its refusal without the holder too. Not run (no timescale harness).

## Hypotheses (no reproduction)

- Under the parallel runner WITHOUT the datid filter (the PR as described), another file's REPEATABLE READ
  writer could become the named holder of a by-xid refusal; the pins are head-only so nothing breaks, but
  the `(oldest: pid P, open T; pids ...)` list is unchanged either way. Not a defect.
- The cutover's refusal under a foreign holder (P1-01's site in pgpm_hypertable) is the same lookup; a
  timescale harness would show the same missing clause.
- The reference says a prepared holder "reads `prepared transaction 'G'` for the pid" but the clause also
  replaces "open T" with "prepared T"; cosmetic, not claimed.
