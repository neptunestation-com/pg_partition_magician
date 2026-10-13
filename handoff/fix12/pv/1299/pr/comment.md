## Per-PR adversarial verification of `527182f` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: verified Tier 1 defect in the PR's own surface

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1259 acceptance (F14-01): A partition whose retire() stamped retiring_at but whose detach dispatch failed (no pg_cron) and that the operator then DETACHed by hand is handed to the archive strategy and recorded as covered by the next maintain() tick, because _part_built/_part_detached_by_hand (and _archive_hold_partition) still vouch for any retiring_at mark while retire() in the same tick disowns that mark as unvouched (retain_disown, #705 dispatch record); the archive step should skip a table detached by hand and record nothing for it | yes | yes | `retirement_mark_vouches_alone`: yes |  |

### Closing claim

**holds**: 1. Call sites: every reader of pgpm.part.retiring_at in head pgpm_core/install.sql, scripts/archive_partition_whole.sql, pgpm_archive, pgpm_hypertable and uninstall.sql was grepped. Every path that hands a partition to an archive strategy or writes archive_ledger (_archive_step at 5362/5416/5460 and archive_partition_whole.sql at 117/158/222, the only two callers of _run_archive_strategy) asks _part_detached_by_hand and _archive_hold_partition. Both now go through _retirement_vouched (mark AND _detach_dispatched naming the anchored oid). So do _enforce_write_blocks (4463), the auto-regrain scan (13423), the regrain-source reclaim (6495), progress (14571/14592), status (14393-14398) and the obtain walk (2285/2291/2350). pgpm_archive and pgpm_hypertable do not read the mark. The readers left unchanged (retire's tiebreak at 3887, which needs pg_inherits so a detached table never counts; _retain_recall's prefilter; the status count; forget_missing's command match; adopt's refusal) cannot hand a table to a strategy or record coverage. 2. Resume, upgrade and scheduled paths: maintain() runs the archive step before retain(), and that step now judges an unvouched mark the way retire()'s retain_disown does in the same tick. The install's _disown_unvouched_retirements pass is unchanged: it records an older install's armed attached dispatch and disowns the rest, as on the base (#1250's surface). An operator's interrupted DETACH CONCURRENTLY under an unvouched mark stays in pg_inherits, so _part_built counts it built, but _archive_hold_partition's pg_partition_ancestors stops at a pending link and nothing is handed. After _detach_reap finalizes it, it is the hand-detached case the fix covers. An unanchored row (null child_oid) never reaches the mark test, as the body says. 3. Body promises: each site in its list was traced to the changed predicate, and none is missing. _retirement_vouched keys on child_oid and asks _detach_dispatched with that row's child_name and the same oid, so a record for another relation does not vouch (tests/330 part B pins this). 4. Mutation: retirement_mark_vouches_alone drops only the record clause of _retirement_vouched. That restores the mark-alone rule at every reader while retire()'s own rule stays, which is this defect, and the acceptance reproduction fails on it at 6, 7 and 9 with every LIVENESS green. tests/330 asserts identity (which ranges are handed, which ledger rows exist, which ids survive). 5. Contract change: reference.md now says an unvouched mark reads as hand-detached at every reader. That only narrows what pgpm acts on and refuses no documented workflow. tests/280 and tests/307 now stamp the record as retire() does. LIVE RUNS (pgpm_prv-15, monolith [0,20) holds rows 1, 2, 15, a strategy that reads through the parent). State 1, the pre-#1250 shape (mark stamped, no record), with the head installed over the base. (1a) Base ticks archived [0,20) (rows 1, 2, 15 in the sink) and stamped the mark. pgpm's own concurrent detach then landed, and the head was installed. The install's _disown_unvouched_retirements pass (#1250's code, unchanged by this PR) logged retain_disown, and each tick then logged fail_retain_drop. The table stays standing with 1, 2 and 15 (also in the sink), so no rows are lost and retention refuses it loudly. (1b) The mark was stamped by hand as tests/280 and tests/307 did before this PR, on an unarchived monolith, which was then detached by hand. set_archive_fn was called and the head installed over the base. The install pass disowned the mark, the archive step recorded no ledger row for [0,20), and retire logged fail_retain_drop. The table kept 1, 2 and 15. Taking the documented remedy (attach it back) archived 1, 2 and 15 before the drop. Nothing was lost. (1c) As 1b, but the mark was stamped while the partition was attached and the hand detach came after the head install. This exercises the PR's own rule. The archive step skipped the table (no ledger row), retire logged retain_disown then fail_retain_drop, and the table kept 1, 2 and 15. In all three, pgpm's own old retirement is read as the operator's. This is documented in the head's reference (retire: 'a mark without the record ... vouches for nothing: retire clears it, logged retain_disown ... refuses the table as one detached by hand', plus the install pass's message: 'drop the table by hand, or attach it back to the parent on its bounds so retention retires it'). The outcome is held and logged, never silent loss. State 2, a mark WITH its record whose detach never landed, then a plain detach by hand (the record is written as retire() writes it on a successful dispatch). (2a) Archiving was configured before the mark, so [0,20) was fully covered when retire marked it, which retire's coverage gate requires. The table is no longer a candidate (fully covered) and is not handed to the strategy. retire logged retain_drop, and 1, 2 and 15 are in the sink. Nothing was lost, matching reference.md ('a partition whose detach pgpm dispatched, and which an operator then detached by hand, is pgpm's retirement still: it is dropped'). (2b) Archiving was configured only AFTER the mark (retire marked with archive_fn null, so its coverage gate passed trivially). The head handed the detached table to the strategy, which read nothing through the parent. The step recorded [0,20) as covered with rows_archived 0, and retire dropped the table. Rows 1, 2 and 15 are in neither the table nor the sink, and nothing was logged as a failure. It is not caused by the hand detach: V-01 reproduces it with pgpm's own concurrent detach landing. It is identical on the base and the head, because the mark WITH its record is a path this PR deliberately leaves as pgpm's. So it is a sibling mechanism outside #1259's (a vouched retirement read through the parent after archiving is enabled mid-retirement), filed as claim V-01 (pre_existing, fails on both with every LIVENESS green), not a partial. No path to #1259's consequence (a mark WITHOUT its record) survives the change.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 1 | seed_hit |  | pgpm._retirement_vouched's body is `select p_retiring_at is not null` with no call to _detach_dispatched, so _part_built, _part_detached_by_hand and _archive_hold_partition still vouch for a retiring_at mark whose dispatch failed; a table the operator detached by hand under such a mark is handed to the archive strategy and recorded as covered in the tick retire() disowns the mark, and once attached back (the documented remedy) retention drops it with rows 1, 2 and 15 in neither the table nor the archive; the PR body says the rule is the mark AND the dispatch record, which would leave the table alone and record nothing |
| `V-01` | 1 | pre_existing | finding T1 | Sibling of #1259, not its mechanism: a retirement pgpm dispatched (mark WITH detach_dispatched_oid) whose concurrent detach has landed is still an archive candidate (_part_built and _archive_hold_partition vouch for it) when archiving is turned on after the retirement began. A strategy reading through the parent (pgpm_archive's transports) reads none of its rows, the step records the range covered with rows_archived 0, and retire() drops it: rows 1, 2, 15 are in neither table nor archive, nothing logged as a failure. Had set_archive_fn come before pg_cron ran the detach, the rows would have been archived. The dispatch record is written by hand (fixture:) because the harness has no pg_cron. Tier 1 by consequence (silently wrong archive ledger, rows dropped after archiving was configured), narrow: needs archiving enabled during an in-flight referenced retirement. Fails on base and head alike (pre_existing). |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 # Failed test 7: "every one of rows 1, 2 and 15 is still in the table or in the archive once archiving was configured before the drop"+
 #         have: {1,2,15}                                                                                                              +
 #         want: NULL
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 7
(1 row)
```
head:
```
 # Failed test 7: "every one of rows 1, 2 and 15 is still in the table or in the archive once archiving was configured before the drop"+
 #         have: {1,2,15}                                                                                                              +
 #         want: NULL
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 7
(1 row)
```
Verifier: _archive_hold_partition (via _retirement_vouched) and the candidate query keep a vouched retirement mark archivable after pgpm's own concurrent detach has landed, so a strategy reading through the parent (as pgpm_archive's transports do, docs/reference.md 2717) reads none of the partition's rows, the step records the range covered with rows_archived 0, and retire()'s drop gate (_archive_fully_covered, documented as 'their objects are now the only copy of its rows') opens on that false coverage: rows 1, 2, 15 dropped unarchived after archiving was configured. Re-run reproduces on base and head (tests 6 and 7 fail, all five LIVENESS pass); the fixture's detach_dispatched_oid stamp matches what retire() writes after a successful _dispatch_detach (install.sql 3963) and passes _detach_dispatched. Distinct from #1259 (unvouched mark, dispatch failed, hand detach) and #705 (trusting pgpm.part.attached): here the mark is backed by its record and the detach is pgpm's own.

</details>

### Seed witness

- S1 in `pgpm_core/install.sql` (retirement_mark_vouches_alone): **found**

### Coverage and budget

- P1: 26 of 26 units read (1.00)
- surface: 8 file(s), 26 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~160k tokens (26/26 units), claims verifier ~175k over two passes (the first, read-only, said holds; the live re-run of the older-install states found V-01), V-01 verifier ~60k; acceptance F14-01 (the verifier's rebuilt reproduction); seed caught; BLOCKED on V-01, a verified Tier 1 pre-existing defect inside the surface (the archive step hands a table whose recorded detach landed to a strategy that reads through the parent, records coverage with 0 rows, and retention drops it), fixer round 2 in progress

🤖 Generated with [Claude Code](https://claude.com/claude-code)
