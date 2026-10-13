## Per-PR adversarial verification of `356f52e` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: pre_existing with no verdict yet (unverified is not clear)
- closing claim: partial (All checks were run live in pgpm_prv-15 against both trees. (1) Entry points: only two archive paths reach a strategy, _archive_step (install.sql 5447) and scripts/archive_partition_whole.sql (161), and both go through the same changed hold. Neither pgpm_archive nor pgpm_hypertable calls _run_archiv); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1259 acceptance (F14-01): A partition whose retire() stamped retiring_at but whose detach dispatch failed (no pg_cron) and that the operator then DETACHed by hand is handed to the archive strategy and recorded as covered by the next maintain() tick, because _part_built/_part_detached_by_hand (and _archive_hold_partition) still vouch for any retiring_at mark while retire() in the same tick disowns that mark as unvouched (retain_disown, #705 dispatch record); the archive step should skip a table detached by hand and record nothing for it | yes | yes | `archive_hold_vouches_detached_retirement`: NO; `retirement_mark_readers_whole`: yes; `retirement_mark_vouches_alone`: NO |  |
| `ACC-02` #1259 acceptance (V-01-1299): Sibling of #1259, not its mechanism: a retirement pgpm dispatched (mark WITH detach_dispatched_oid) whose concurrent detach has landed is still an archive candidate (_part_built and _archive_hold_partition vouch for it) when archiving is turned on after the retirement began. A strategy reading through the parent (pgpm_archive's transports) reads none of its rows, the step records the range covered with rows_archived 0, and retire() drops it: rows 1, 2, 15 are in neither table nor archive, nothing logged as a failure. Had set_archive_fn come before pg_cron ran the detach, the rows would have been archived. The dispatch record is written by hand (fixture:) because the harness has no pg_cron. Tier 1 by consequence (silently wrong archive ledger, rows dropped after archiving was configured), narrow: needs archiving enabled during an in-flight referenced retirement. Fails on base and head alike (pre_existing). | yes | yes | `archive_hold_vouches_detached_retirement`: yes; `retirement_mark_readers_whole`: yes; `retirement_mark_vouches_alone`: NO |  |

### Closing claim

**partial**: All checks were run live in pgpm_prv-15 against both trees. (1) Entry points: only two archive paths reach a strategy, _archive_step (install.sql 5447) and scripts/archive_partition_whole.sql (161), and both go through the same changed hold. Neither pgpm_archive nor pgpm_hypertable calls _run_archive_strategy. Round 1's V-01 (a mark WITH its record, detach landed, archiving configured afterwards) is closed on the scheduled tick: the hold answers by pg_partition_ancestors alone, so no strategy is handed the detached table (not one reading through the parent, not _archive_noop, not a custom fn reading by oid), nothing is recorded, and retire() keeps the table. Older-install states: a mark with no record behaves as #1259's main case and is covered. A mark with a record whose job never ran leaves the partition attached, so it is read normally; if it is then detached by hand it is skipped with the remedy and nothing is recorded. An unanchored MARKED row is asked through its name (the coalesce). (2) A detach landing between the hold and the strategy: built as a two-session probe in which pgpm's dispatched DETACH ... CONCURRENTLY first transaction commits while the strategy waits (the pending flag was observed committed). On PG15 in this path the read through the parent still returned all 3 rows and the ledger recorded rows_archived 3, so nothing was lost on either tree. Not filed; the probe is kept in the verifier's scratch. (3) The surviving path, V-01: an UNANCHORED, UNMARKED row (child_oid null, the state an upgrade from before #421 leaves; set by hand as the fixture) whose write-blocked table was detached by hand. The head passes the hold a null oid (coalesce(r.child_oid, case when r.retiring_at is not null then v_now::oid end)) and the hold answers true. The table is handed to the strategy, [0,20) is recorded covered with rows_archived 0, and after the documented remedy (attach it back) retention drops it: rows 1, 2 and 15 are lost. Same result on the base and the head (pre_existing). The archive script has the same line (162). This contradicts the body's 'Neither archive path ... hands a strategy a table that is not a partition of its parent as of the hold's lock, whatever its mark', although the hold's comment carves unanchored rows out. Its mechanism is #705's open archive bullet (the archive step reaching an operator-detached table), so the coordinator may instead rule it known_open #705 and have the body's sentence narrowed. It is not #1259's mark mechanism. (4) Mutations: ACC-01 fails only on the combined retirement_mark_readers_whole; each single mutation alone passes it, which the body explains. The rebuilt ACC-02 fails on archive_hold_vouches_detached_retirement, so that mutation puts back round 1's defect. (5) ACC-02 is premise_removed: on the head it fails only at LIVENESS 5 (the drop no longer happens) and at check 7 (rows looked for only in the parent and the sink, while they survive in the kept detached table). Rebuilt as claims/ACC/ACC-02/repro.verified.sql, which pins no coverage for the detached monolith, rows 1, 2 and 15 present in the detached table (by oid) or the archive, skip_archive over [0,20) with the ATTACH remedy, and the remedy as typed archiving the rows before the drop; LIVENESS is kept. Results: BASE fails (5, 6, 7, 9 and LIVENESS 8; LIVENESS 1-4 ok); HEAD passes 9/9; MUTANT archive_hold_vouches_detached_retirement fails (5, 6, 7, 9; LIVENESS 1-4 ok).

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | pgpm._retirement_vouched is `select p_retiring_at is not null`: it never asks _detach_dispatched, so a table the operator detached under a mark whose dispatch failed (no record) still reads as built at _part_built and not detached by hand, and the write-block step puts pgpm's block on the operator's table (and status/progress/obtain/auto-regrain still count it pgpm's); the PR body, the reference and tests/330 part B say the mark vouches only with the record |
| `V-01` | 1 | pre_existing | unverified | An unanchored pgpm.part row (child_oid null: the state an upgrade from before #421 leaves for a partition not attached when its backfill ran) with NO retirement mark, whose write-blocked table the operator DETACHed by hand, is still handed to the archive strategy: the candidate query cannot call it detached by hand (_part_detached_by_hand is false for a null oid) and the head's hold is asked about the name's relation only when the row carries a mark (coalesce(r.child_oid, case when r.retiring_at is not null then v_now::oid end)), so _archive_hold_partition gets a null oid and answers true. A strategy reading through the parent reads none of its rows and [0, 20) is recorded covered with rows_archived 0. retire() refuses to drop it (fail_retain_drop) until the operator takes the reference's remedy (attach it back so retention retires it); retention then drops it on the false coverage and rows 1, 2 and 15 are in neither table nor archive. #1259's consequence through a path PR #1299's body claims ('Neither archive path ... hands a strategy a table that is not a partition of its parent as of the hold's lock, whatever its mark') but the code carves out (the hold's comment: an unanchored row with no relation passed is left as before). The mechanism (the archive step reaching an operator-detached table) is #705's open archive bullet, residue for unanchored rows. scripts/archive_partition_whole.sql carries the same coalesce at line 162. Fixture: child_oid set null by hand to stand for the older install's state. Fails on base and head alike (pre_existing). |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 # Failed test 7: "every one of rows 1, 2 and 15 is still in a table or in the archive"+
 #         have: {1,2,15}                                                              +
 #         want: NULL
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 7
(1 row)
```
head:
```
 # Failed test 7: "every one of rows 1, 2 and 15 is still in a table or in the archive"+
 #         have: {1,2,15}                                                              +
 #         want: NULL
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 7
(1 row)
```

</details>

### Seed witness

- S1 in `pgpm_core/install.sql` (retirement_mark_vouches_alone): **found**

### Coverage and budget

- P1: 31 of 31 units read (1.00)
- surface: 9 file(s), 31 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~145k tokens (31/31 units), claims verifier ~119k (every path run live: the tick, the script, _archive_noop, a by-oid strategy, three older-install states, a two-session detach race); acceptance: F14-01 and round 1's V-01 rebuilt to the hold (fail base, pass head, fail mutant archive_hold_vouches_detached_retirement); seed caught; round 1's Tier 1 is closed; BLOCKED only by V-01 (round 2): an unanchored pre-#421 row (child_oid null) is still passed to the hold through a coalesce and handed to the strategy, open issue #705's _archive_step mechanism, sent to the fixer for a last in-place round rather than carried

🤖 Generated with [Claude Code](https://claude.com/claude-code)
