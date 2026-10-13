## The defect (#1263)

`pgpm._snapshot_wait` lists every session of this database whose `pg_stat_activity.backend_xmin` is at or before the copies' last write. `backend_xmin` is cluster-wide: a snapshot's xmin is the oldest xid running anywhere when it was taken. So while a transaction older than that write stays open in ANOTHER database (or as a prepared transaction), every snapshot in the cluster has an xmin at or before the reference. A `READ COMMITTED` statement of this database that began after the copies, and sees them, is listed, and the swap defers for that transaction's whole life. The refusal then called each such session a reader that "would find the regrained range empty", and `docs/reference.md` said other databases were "not consulted".

## Why the swap still waits (the reproduction's last line is not met, on purpose)

The issue's reproduction expects the swap to go through. It does not on this head, by design. The catalog cannot tell the issue's reader from one that cannot see the copies, so passing it would bring back #1241's empty read. `tests/333` part A builds both sessions while the foreign transaction X is open:

- **B** (the issue's reader) runs a statement that began after the copies.
- **I** began its transaction after the copies, then imported (`SET TRANSACTION SNAPSHOT`) a snapshot that E exported before them. E has since committed.

The two `pg_stat_activity` rows agree on database, `backend_xmin` (both X's xid), `backend_xid`, `backend_type`, `state` and wait event. Both transactions and both statements began after the last copy (LIVENESS 4 to 7). Yet the same statement counts 5 copy log rows in B and 0 in I (assertions 12 and 14).

So any rule that passes B also passes I, and I then reads the regrained range empty. The mutation `snapshot_wait_foreign_floor_exempt` is exactly the exemption the issue asks for: a session whose xmin is explained by another database's running transaction is not listed. Under it:

- the issue's `repro.sh` passes (`swapped:10`);
- tests/333 fails assertion 16 ("I reads exactly its rows"): I's read comes back empty.

The `xact_start` and state exemptions were already refuted in #1253's rounds (masked to other roles; defeated by import), and tests/328 part I pins the import case. PostgreSQL's own `CREATE INDEX CONCURRENTLY` waits the same way, because its reference xmin is cluster-wide too. As the brief anticipated ("where the catalog cannot tell the two apart, say so and make the message name the holding transaction's database"), this PR changes the refusal and the contract, not the wait.

## The fix

- **The refusal names the floor holder.** In `_snapshot_wait`, at the budget, the message now names the oldest transaction still running at or before the reference. This applies only against an earlier transaction's reference: `maintain`'s ticks, a hand `regrain_step`, and `from_hypertable_cutover` (the one other caller, through the same function). The holder can be a session of any database (`pg_stat_activity.backend_xid`) or a prepared transaction (`pg_prepared_xacts`). The message names its database, pid (or gid) and xid, says the listed sessions "cannot be told from snapshots that miss the copies", and gives the remedy: end that transaction.
- **regrain() is unchanged.** Against the call's own xid (`regrain()`, or a run with no recorded write) every snapshot open during the call is listed whatever else runs, so no holder is named and the message is unchanged (tests/333 part C).
- **The holder reaches maintain's log row (round 2, P1-02).** The holder clause follows `(oldest: pid P, open T)` and comes before the pid list, which has no bound. `maintain`'s `skip_regrain` row keeps 200 characters, as every skip row does, or as many as reach the end of the holder clause, whichever is more: `left(sqlerrm, greatest(200, strpos(sqlerrm, '): while it runs every snapshot of the cluster')))`. What is kept stays bounded: a head of about 150 characters and a clause of at most about 600 with the longest prepared gid. Widening every `skip_regrain` row was tried first and rejected, because it changed unrelated rows that tests/252, 267 and 277 pin at 200.
- **The message head is unchanged** (`<what> deferred: N snapshot(s) older than the copies still open (oldest: pid P, open T; pids ...)`). Every existing pin in tests/328 and timescale/67 holds, including under the parallel runner, where another file's transaction can briefly be the holder.
- **Docs.** The function comment gains "WHAT IT CANNOT TELL APART". `docs/reference.md` (`regrain_step`'s snapshot wait and `from_hypertable_cutover`) now says other databases' sessions are never listed but their transactions count through the xmin, documents the over-wait and the holder clause, and gives the remedy. CHANGELOG bullet.
- **Test runner.** `test.sh` runs tests/333 ALONE, in its own clone, after the parallel files. It holds a transaction open in another database for seconds, which would hold back every other file's snapshots (and their regrain swaps).

## Acceptance

- `tests/333_snapshot_wait_foreign_floor_holder_test.sql` (36 assertions). Part A: the holder clause names `<db>_x`, X's pid and xid, and lists both B and I. Nothing swapped, and I reads exactly its rows. Part B: the remedy typed. X ends, B runs a new statement whose xmin is past the copies, and the same swap returns `swapped:5` with B's statement running. Part C: the own-xid control. Part D (round 2): `maintain` drives the run. Its `skip_regrain` row carries the oldest listed session and the holder's database, pid and xid whole, and once X ends the next tick swaps.
- Guard `bench/snapshot_wait_foreign_floor_holder.sh` (perf track, `pgpm_perf371`). It fails, on non-LIVENESS lines, against:
  - `snapshot_wait_holder_this_database_only` (the holder looked for in this database only, the floor the issue suggested): fails 8;
  - `snapshot_wait_foreign_floor_exempt` (the issue's requested exemption): fails 8, 9, 10, 11 and 16;
  - `snapshot_wait_holder_log_truncated` (the row's bound back to a flat 200): fails 32 (part D).
- P1-02's `repro.sql` (round 2): its defect assertion 9 now passes. Its `GUARD:` line 5 pins the round-1 order (`; pids W); a transaction ...`), which the reorder above changed, so it reads as a premise failure.
- The issue's `repro.sh`: fails on the base and on this head at its last line, by design (above). It passes only under `snapshot_wait_foreign_floor_exempt`, the unsound mutant. On this head the refusal reads `... a transaction older than the copies is still running in database <db>_h1o (pid ..., xid ..., open ...)`.

## Proof run locally

- `scripts/review/gate.sh ... ./test.sh 15 --channel=psql`: PASS. 333 ran alone (36/36) and 328 passed (165/165).
- `python3 scripts/check_quoted_splices.py` PASS (and `--selftest`); `scripts/check_track_filters.py` PASS; `scripts/check_living_docs.sh` PASS.
- Every mutation builds; `mutate.py --list` is OK.
- `bash -n test.sh`; `shellcheck` is clean on the new guard (test.sh's two findings are pre-existing infos, at lines 111 and 163).
- markdownlint-cli2@0.13.0 is clean on CHANGELOG.md and docs/reference.md.
- The prepared-transaction branch was checked by hand in a container with `max_prepared_transactions=5`. The harness images run with 0, so the suite cannot reach it. The refusal named `in database fix_g6_prep_x (prepared transaction 'g6 holder', xid 1031, ...)`, and after `ROLLBACK PREPARED` the swap returned `swapped:5`.

## Caveats

- The over-wait the issue reports remains, now documented and legible: a transaction older than the copies, in any database, defers every swap of this database for as long as it runs. The cutover is covered by the same code; its timescale test is not part of this PR's local proof.

Closes #1263

🤖 Generated with [Claude Code](https://claude.com/claude-code)

