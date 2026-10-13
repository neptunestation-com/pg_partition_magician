## Per-PR adversarial verification of `d3180a2` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1263 acceptance (F13-01): regrain_step's swap (_snapshot_wait) is refused while any transaction older than the copies' last write is open in ANOTHER database of the cluster, because backend_xmin is cluster-wide and every statement of this database then looks older than the copies though its snapshot sees them; the swap should go through (the comment says other databases' sessions are not consulted) instead of deferring every tick for the foreign transaction's lifetime | yes | yes | `snapshot_wait_foreign_floor_exempt`: yes; `snapshot_wait_holder_this_database_only`: yes |  |

### Closing claim

**holds**: HOLDS. Resolution of #1263 is sound: the issue's requested exemption is unsafe and no rule the catalog supports separates its reader from one that cannot see the copies. (a) Soundness, checked in pgpm_prv-15: tests/333 under mutant snapshot_wait_foreign_floor_exempt (a session exempt when another database runs a xid at least as old as its xmin and the reference) passes LIVENESS 1-7 (B and I agree on datid, backend_xmin = X's xid, backend_xid null, type, state, wait event; both began after the last copy) and fails 16: I's read of t333a misses all 19 rows (26..494), keeping only 2600, i.e. #1241's empty read; also fails 8-11 (swapped). Exact-equality to the foreign xid would pass I too (its xmin is exactly X); snapshot import is recorded nowhere a caller reads, and the exporter E has committed by swap time, so any history rule would need new state recorded at the copy's commit, which the copying transaction cannot observe. Waiting matches CREATE INDEX CONCURRENTLY. (b) Entry points: _snapshot_wait has two callers, _regrain_snapshot_wait (regrain_step by hand and maintain ticks) and pgpm_hypertable from_hypertable_cutover (install.sql:1816), both through the changed function; pgpm_archive and uninstall.sql have no copy of the mechanism. regrain() and an unrecorded regrain_written_xid (upgrade path) use the own-xid reference, where every open snapshot is waited for and no holder is named, as documented and pinned by tests/333 part C. (c) Body promises: holder found across databases (pg_stat_activity.backend_xid, visible to every role) and pg_prepared_xacts; a snapshot's xmin is set by running xids only, so no xid-less session, slot or standby feedback can hold the floor unnamed. Residue tried and not claimed: once X ends while B's READ COMMITTED statement keeps running, B stays listed (xmin still X) and the refusal falls back to the generic message with no holder to name; head docs/reference.md documents that drop-out ('the sessions it held back drop out as they release theirs (a READ COMMITTED one when its statement finishes)'), it is bounded by the local statement, and B is again indistinguishable from I-type snapshots whose holder has also ended. (d) Mutations: snapshot_wait_holder_this_database_only alone restores THIS defect (the holder looked for in this database only, so the refusal names innocent local pid B with no holder); snapshot_wait_foreign_floor_exempt restores the issue's requested (unsound) behaviour, not the defect, and serves as the guard that the wait is kept. (e) Contract change: the refusal is the same one the base gave, now documented and legible; no documented workflow newly refused. ACCEPTANCE REBUILT as claims/ACC/ACC-01/repro.verified.sh (pins the new contract: swap still deferred, nothing swapped by oid and log, the refusal lists the local reader and names 'a transaction older than the copies is still running in database <db>_h1o (pid <foreign pid>, xid <foreign xid>, open ' and says the listed sessions 'cannot be told from snapshots that miss the copies'; all original LIVENESS kept, plus the foreign pid). Run in pgpm_prv-15 against each tree's pgpm_core/install.sql: BASE FAILS (exit 1, every LIVENESS ok, holder clause missing, local pid named alone); HEAD PASSES (exit 0, 13/13); MUTANT snapshot_wait_holder_this_database_only FAILS (exit 1, every LIVENESS ok, holder clause missing); mutant snapshot_wait_foreign_floor_exempt also FAILS (exit 1, swapped:10, every LIVENESS ok). The original repro.sh's last line pinned the unsound exemption, which is why it failed on the head.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | With a transaction older than the copies open in ANOTHER database (the #1263 case), the swap's refusal at the budget still reads 'a reader in one would find the regrained range empty' naming only the local READ COMMITTED pid: the holder lookup filters pg_stat_activity by a.datid = v_db, so the foreign transaction is never found, against docs/reference.md and the function comment ('still running in database D (pid H, xid X, open T)'); tests/333 assertion 8 fails on this tree. The cutover shares the same lookup. |
| `P1-02` | 3 | pre_existing | finding T3 | Under maintain, the swap's refusal with the new holder clause is logged as skip_regrain through left(sqlerrm, 200), and the head up to 'still running in database ' is already 206 characters with one pid listed, so the holder's database, pid and xid never reach the log row: the operator whose only view is maintain's log (the issue's scenario, skip_regrain every tick) cannot learn which transaction to end, against docs/reference.md ('the tick logs skip_regrain with method beginning ...; the holder clause above follows'). The row should carry the holder (or the clause should come before the pid list). |

<details><summary><code>P1-02</code> pre_existing: tails</summary>

base:
```
 dblink_disconnect 
-------------------
 OK
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 9
(1 row)
```
head:
```
 dblink_disconnect 
-------------------
 OK
(1 row)
               finish                
-------------------------------------
 # Looks like you failed 1 test of 9
(1 row)
```
Verifier: maintain logs the swap refusal as skip_regrain through left(sqlerrm, 200), and the refusal's head with one pid listed already runs past 200 characters before the holder clause this PR adds, so the holder's database, pid and xid never reach the log row, against docs/reference.md (head) 'the tick logs skip_regrain with method beginning ... the holder clause above follows when a transaction older than the copies is still running'. Reproduced unchanged: on the head every LIVENESS and GUARD passes (the hand regrain_step shows the clause whole, the logged row says 'a transaction older than the copies is still running' but is cut before the holder) and only assertion 9 fails. The truncation predates the PR (same left(sqlerrm, 200) on the base), but the base has no holder clause and fails at LIVENESS 8, so the consequence is on the PR's own surface: the 'pre_existing' class comes from a base failure that never reaches the defect. Contract not kept, the operator's remedy (which transaction to end) withheld while the swap defers every tick, no loss and no wedge beyond the documented wait: Tier 3. Not named by any open issue (#1263 is the cross-database backend_xmin judgement, not the log truncation).

</details>

To file as issues (verified; below Tier 2, or outside the surface the PR touched; not held against this PR): `P1-02` (outside the PR's surface)

### Seed witness

- S1 in `pgpm_core/install.sql` (snapshot_wait_holder_this_database_only): **found**

### Coverage and budget

- P1: 10 of 10 units read (1.00)
- surface: 6 file(s), 10 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~132k tokens (10/10 units), claims verifier ~80k, P1-02 verifier ~41k; acceptance F13-01 rebuilt by the claims verifier to the new contract (fails base, passes head, fails mutant; the issue's requested exemption judged unsafe by both agents); seed caught; P1-02 (the skip_regrain row cuts the holder clause at 200 characters) is verified Tier 3 and goes back to the fixer for an in-place round 2 before this PR is queued

🤖 Generated with [Claude Code](https://claude.com/claude-code)
