# P1 null results, PR #1296 round 2

## Fresh surface

- `pgpm._snapshot_wait` holder query (install.sql 7820-7847): read whole. The pg_stat_activity branch carries
  `and a.datid = v_db`, which is the claim (P1-01): the holder is looked for in this database only, so the
  #1263 case (a foreign database's transaction) is never named. tests/333 on the tree: 8, 9 and 32 fail
  (run in `pgpm_prv-15`, fresh database, core install). With the one predicate removed in-database (the tree
  untouched) tests/333 passes 36/36 twice, and P1-01's `repro.sql` passes.
- The ordering of the clause (holder before the pid list) and the message head: against the in-database
  patched copy the head is unchanged (`... (oldest: pid P, open T); a transaction older than the copies is
  still running in database D (pid H, xid X, open T): while it runs ...`); part C (own xid, no holder) passes
  on the tree itself, so `regrain()`'s message is unchanged as the body says.
- `pgpm.maintain`'s bounded keep (13479-13485): `left(sqlerrm, greatest(200, strpos(sqlerrm, '): while it runs
  every snapshot of the cluster')))`. `strpos` returns the position of `)`, so the row ends exactly at the end
  of the holder clause (`open T)`); when the message has no holder clause `strpos` is 0 and the row keeps 200,
  as before. Observed under the patched copy: the skip_regrain row is 249 characters and ends `... (pid 26575,
  xid 19329, open 00:00:00)`. Every other `left(sqlerrm, 200)` site in maintain (skip_write_block,
  skip_archive, skip_retain, skip_restore_fk, skip_validate_fk) logs a refusal whose remedy is in its head or
  is not a holder message; the two "deferred at once" refusals of `_snapshot_wait` (chained waiter, older wait)
  keep 200 as before and name their pids in the first 200. Held.
- `from_hypertable_cutover` (pgpm_hypertable/install.sql 1816): the same function, its refusal raised whole
  (no log row truncation on that path), bounded by `p_lock_timeout`. Nothing in the change touches it beyond the
  message; read, held. `_regrain_snapshot_wait` passes `config.regrain_written_xid` unchanged. `maintain_all`
  has no handler around `maintain` by design; the skip row is written inside maintain's own handler. Held.
- `archive._pq_encode_column_data`: in the ledger as a caller of `pgpm.maintain`, but the only mention is a
  comment about `call pgpm.maintain()` from a differently-zoned psql (#465); no call. Held.
- `test.sh`: the `alone` bucket runs after `wait` in its own clone through `prove_one`, its rc and log are
  printed and counted with the parallel ones (`"${parallel[@]}" ${alone[@]+"${alone[@]}"}`), bash 3.2 safe.
  Perf list gains `bench/snapshot_wait_foreign_floor_holder.sh pgpm_perf371`. Held.
- `bench/snapshot_wait_foreign_floor_holder.sh`: installs the given install.sql into a fresh db, runs
  tests/333 through pg_prove, counts the assertions reached (0 ran is a FAIL, not a pass), drops `${DB}_x`
  before and after. A mutant that does not install is reported as FAIL. Held.
- Docs (`docs/reference.md` 1000-1003, 1973-1974, 1986-2006, 2065-2069; the function comment; CHANGELOG):
  consistent with the code's intended behaviour and with each other; they promise the holder "in any database",
  which the tree's code does not keep (that is P1-01, tiered 3 as the contract not kept, not as docs).

## Concurrency and locks

- The holder query runs in the same transaction, after the budget check and the `v_still` read, in a separate
  statement: a holder that ends between the two leaves `v_holder` null and the old message is raised. Transient
  and harmless (the next tick names it or swaps); the body's parallel-runner note covers it. Not a claim.
- The holder query excludes `pg_backend_pid()` and takes `age(backend_xid) >= age(v_limit)`; under `v_by_xid`
  the swap's own xid is younger than the reference, so it could never be named anyway. Held.
- `pg_prepared_xacts` branch: `max_prepared_transactions = 0` in the harness images (the body says so too), so
  it was read only: `age(p.transaction) >= age(v_limit)`, `%L` on the gid, `p.database` is already a name. Held.
- The exemption (`v_blocked`) and chain refusal paths are unchanged by the diff and were not re-probed.

## Hypotheses (no reproduction)

- tests/333 LIVENESS 6 ("B and I agree on ... backend_xmin ...") failed once in three runs of the test against
  the in-database patched copy (the file otherwise 36/36). Mechanism I suspect: a transaction of THIS database
  (or an autovacuum ANALYZE, which writes pg_statistic and so takes an xid) that took its xid before X and ended
  before B started makes E's exported snapshot's xmin, hence I's `backend_xmin`, that older xid, while B's is
  X's xid; the pair then disagrees and the premise reads as the fixture never ran. The suite runs 333 right after
  270 parallel files, when autovacuum is busiest. A local session W (`begin; insert ...`) opened before X and
  committed after E exports would make it deterministic, but that is an induced state, not pgpm's defect; the
  `ok()` assertion prints no diagnostics, so a flake there is hard to read. Suggest `is()` on the two xmins or
  pinning I's xmin to E's exported snapshot rather than to X's.
- `pg_stat_activity.datname` is spliced with `%s` in the holder clause: a database name with spaces or quotes
  reads unquoted. Cosmetic; no claim.
