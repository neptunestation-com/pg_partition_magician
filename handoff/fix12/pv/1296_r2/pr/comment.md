## Per-PR adversarial verification of `15110fd` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1263 acceptance (ACC-01-1296): #1263 acceptance (F13-01): regrain_step's swap (_snapshot_wait) is refused while any transaction older than the copies' last write is open in ANOTHER database of the cluster, because backend_xmin is cluster-wide and every statement of this database then looks older than the copies though its snapshot sees them; the swap should go through (the comment says other databases' sessions are not consulted) instead of deferring every tick for the foreign transaction's lifetime | yes | yes | `snapshot_wait_foreign_floor_exempt`: yes; `snapshot_wait_holder_log_truncated`: NO; `snapshot_wait_holder_this_database_only`: yes |  |
| `ACC-02` #1263 acceptance (P1-02-1296): Under maintain, the swap's refusal with the new holder clause is logged as skip_regrain through left(sqlerrm, 200), and the head up to 'still running in database ' is already 206 characters with one pid listed, so the holder's database, pid and xid never reach the log row: the operator whose only view is maintain's log (the issue's scenario, skip_regrain every tick) cannot learn which transaction to end, against docs/reference.md ('the tick logs skip_regrain with method beginning ...; the holder clause above follows'). The row should carry the holder (or the clause should come before the pid list). | yes | yes | `snapshot_wait_foreign_floor_exempt`: NO; `snapshot_wait_holder_log_truncated`: yes; `snapshot_wait_holder_this_database_only`: NO |  |

### Closing claim

**holds**: holds. (1) Sites: _snapshot_wait has two callers, _regrain_snapshot_wait (regrain_step: hand calls, regrain()'s loop, maintain's tick) and pgpm_hypertable's cutover; the only bounded logging of its refusal is maintain's skip_regrain insert (install.sql:13483), the one the PR widens; the hypertable module logs no sqlerrm, the cutover refuses whole. regrain() runs against its own xid and names no holder, as documented. (2) Bound attacks, live on pgpm_prv-15 against the head: a 63-char foreign database name plus 12 listed local sessions kept the row at 296 chars with the clause whole (database, pid, xid, close paren), since greatest(200, strpos(...)) extends and the clause now precedes the unbounded pid list. p_what is the constant 'regrain swap', so the only caller-controlled text before the anchor is the holder's database name (or a prepared gid). A database literally named 'h): while it runs every snapshot of the cluster' does make strpos hit early and cut the row at 200 (verified), but that requires naming a database after pgpm's own message text: no described caller, not filed. An absent anchor (any other skip_regrain cause) gives strpos 0, so 200 as before; the other skip_* inserts are untouched left(sqlerrm, 200). (3) Race: if the holder ends between the listing and its lookup, the message falls back to the old wording; the next tick then swaps, so no lasting mislabel. Hot-standby feedback and replication-slot xmins do not lower a snapshot's xmin, and prepared transactions are covered. (4) Mutations: ACC-01 fails on foreign_floor_exempt and this_database_only. ACC-02 was the premise_removed shape: its GUARD 5 pinned round 1's message order ('; pids W); a transaction ...'), which the round-2 head changed on purpose, and its defect assertion 9 passes on the head. Rebuilt as claims/ACC/ACC-02/repro.verified.sql, which checks the contract in any order: the hand refusal carries the holder clause whole (throws_matching on 'still running in database <db> (pid W, xid X, open ...)'), and the skip_regrain row carries the same clause through its close paren. The old LIVENESS 8 became a defect assertion because the base has no clause at all. Results: BASE fails (5, 8, 9; LIVENESS 1-4 and 7 pass), HEAD passes 9/9, MUTANT snapshot_wait_holder_log_truncated fails 9 only (LIVENESS all pass). So each of the three mutations restores its defect. (5) Contract changes: the reference.md and CHANGELOG change is a wording and documentation change. The wait itself is unchanged, and it is documented as an over-wait the catalog cannot avoid (tests/333's import pair), so it does not refuse any workflow it used to allow.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | _snapshot_wait's floor-holder query is filtered to this database (a.datid = v_db), so a transaction open in ANOTHER database (the #1263 case, which the PR body says the clause names: 'a session of any database') is never found: at the budget the refusal falls back to the old message calling the held-back local pid a reader that 'would find the regrained range empty', and maintain's skip_regrain row carries no holder; the refusal should name that transaction's database, pid and xid (tests/333 parts A and D fail on this tree: 8, 9, 32) |

### Seed witness

- S1 in `pgpm_core/install.sql` (snapshot_wait_holder_this_database_only): **found**

### Coverage and budget

- P1: 13 of 13 units read (1.00)
- surface: 6 file(s), 13 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~127k tokens (13/13 units), claims verifier ~76k (live: a 63-character database name and twelve sessions, the anchor absent or earlier, every other skip_* row still at 200); acceptance: round 1's rebuilt F13-01 and round 1's P1-02 rebuilt to pin the holder clause in any order (fail base, pass head, fail mutant snapshot_wait_holder_log_truncated); seed caught; round 1 was clear on the closing claim with P1-02 sent back for an in-place fix, now verified

🤖 Generated with [Claude Code](https://claude.com/claude-code)
