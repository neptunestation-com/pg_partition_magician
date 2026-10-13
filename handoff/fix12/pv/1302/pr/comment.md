## Per-PR adversarial verification of `cf00e72` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- P1-02: pre_existing with no verdict yet (unverified is not clear)

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1268 acceptance (F16r-01): from_hypertable / from_hypertable_cutover with a mixed month + duration p_interval ('1 mon 1 day') copy, commit the swap (hypertable dropped, incoming FK dropped) and only then hit transmute's 'mixed month + duration interval unsupported', leaving a plain unmanaged table; _from_hypertable_check_arguments should ask that transmute rule before the copy/swap as it does the sign rules (#1085), and '1 mon -40 days' is refused by the frontier check with a delete-the-newest-rows remedy, which tests/timescale/db/58 lines 78-81 pin as correct | yes | yes | `hypertable_mixed_step_unchecked`: yes; `hypertable_unit_rules_transmute_remedy`: NO |  |
| `ACC-02` #1268 acceptance (F16-01): from_hypertable (and from_hypertable_cutover) refuse an off-midnight anchor on a date dimension, or a step/anchor finer than a timestamp(p) dimension, up front via the shared pgpm._time_unit_contract (#1118/#1138), but the refusal's remedy says 'then re-run transmute; ... call pgpm.transmute_abort(<table>) first': transmute refuses a hypertable outright ('has inheritance children'), and nothing from_hypertable did needs a transmute_abort; the message should name from_hypertable / from_hypertable_cutover as the call to re-run (tests/timescale/db/66 pins only the message's first half, so the wrong remedy is unwatched) | yes | yes | `hypertable_mixed_step_unchecked`: NO; `hypertable_unit_rules_transmute_remedy`: yes |  |

### Closing claim

**holds**: (1) Entry points: _from_hypertable_check_arguments is the only pre-swap caller path and is called by both module procedures that reach transmute with a p_interval (from_hypertable before check_handoff/check_frontier/copy, line 2460; from_hypertable_cutover before the pre-drain, names, frontier and swap, line 1692); from_hypertable_copy, preflight and the estimates take no interval; the handoff passes the same p_interval to transmute; no cron/maintain path runs a cutover; pgpm_archive has no copy of the mechanism; regrain_step's mixed-step refusal (core 7332) is a separate, already-guarded site. (2) The new call asks pgpm._grid_floor itself, so the predicate cannot drift; the mixed rule depends only on the step (months > 0 and a non-zero remainder), not on the anchor or zone, so asking it at (anchor, anchor, 'UTC') is sufficient; negative month counts are refused earlier by _refuse_bad_transmute_arguments, so the v_months > 0 gate leaves no hole. (3) Live on the head (pgpm_prv-timescale, db prv_v_1302_a, dropped): '1 mon 1 day' under IntervalStyle iso_8601 and sql_standard, '1 mon -40 days' under sql_standard, '1 mon 0.000001 sec', '1 year -11 mon -30 days 1 sec', and '1 mon 1 day' with a +05 anchor were all refused by the new pre-swap message with the hypertable intact; '-1 mon 40 days' is refused by the sign rule. (4) Mutation hypertable_mixed_step_unchecked alone restores #1268's defect (the acceptance repro fails on it); hypertable_unit_rules_transmute_remedy does not and is not meant to: it guards the #1232 remedy text the PR only Addresses. (5) Contract changes: '1 mon -40 days' now meets a mixed-step refusal instead of the frontier's delete-rows remedy (documented in reference.md, test 58 prefix-only); _time_unit_contract gains a defaulted fifth argument and drops the 4-arg overload, so an older pgpm_hypertable over the new core binds to the default (transmute's wording), and transmute's own messages are unchanged. No path to the issue's consequence (copy/swap committed before a mixed-step refusal) found.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | The tree's pgpm._from_hypertable_check_arguments holds `begin null; exception when others ...` where the PR body, CHANGELOG and docs/reference.md say it calls pgpm._grid_floor, so the mixed-step rule is never asked: from_hypertable and from_hypertable_cutover with p_interval '1 mon 1 day' copy and commit the swap (hypertable and incoming FK dropped) before transmute's handoff refuses, leaving a plain unmanaged table, and '1 mon -40 days' is still refused by the frontier check with a delete-the-newest-rows remedy; the PR's own tests/timescale/db/69 fails its 6 defect checks on this tree. Both calls should refuse before anything is changed. |
| `P1-02` | 4 | pre_existing | unverified | On the two-phase path, from_hypertable_cutover's timestamp(p) refusal (the #1232 remedy this PR wrote) tells the operator to widen the column (ALTER TABLE ... TYPE timestamp with time zone) then re-run pgpm.from_hypertable_cutover, and docs/reference.md says widening first 'also works'; typed as given, the cutover is refused again (the copy from_hypertable_copy made still has the old type, so _from_hypertable_check_shape refuses the swap) and the operator must re-run from_hypertable_copy first, which neither the message nor the reference says. The remedy should name the re-copy on this path (or the reference should say the copy must be redone). |

<details><summary><code>P1-02</code> pre_existing: tails</summary>

base:
```
e cutover refused '500 milliseconds' on the timestamptz(0) key, naming the ALTER TABLE and pgpm.from_hypertable_cutover as the re-run (got '0', want '1')
ok - LIVENESS: u1 is still a hypertable, its copy still recorded, holding 1,2,3
ok - GUARD: the ALTER TABLE the message gives ran on the hypertable
# re-run: ERROR:  pg_partition_magician: from_hypertable_cutover(u1) refusing to swap: the copy u1_pgpm_dest no longer has the source's shape: column ts has type timestamp with time zone on the source but timestamp(0) with time zone on the copy. from_hypertable_copy fix
not ok - the re-run the remedy names (from_hypertable_cutover after the ALTER) is not refused (got '1', want '0')
not ok - u1 is migrated by the remedy as typed: partitioned, registered, holding 1,2,3 (got 'r/0/1,2,3', want 'p/1/1,2,3')
NOTICE:  pg_partition_magician: from_hypertable will copy u1 into a second table before cutover (about 72 kB); ensure that much free disk until the old hypertable is dropped at cutover and the space is reclaimed.
NOTICE:  pg_partition_magician: estimated online copy time ~ 00:00:00.001758 (72 kB at ~40 MiB/s, cache-resident: estimated size fits effective_cache_size). This covers the copy only -- the cutover then rebuilds the primary key and secondary indexes (extra, scales with row count) and a later regrain (if used) is a similar second pass. Rough (measured on a 2XL gp3): more RAM/IOPS/throughput is faster. Override the rate with pgpm.from_hypertable_time_estimate(table, mibps).
```
head:
```
ok - LIVENESS: the cutover refused '500 milliseconds' on the timestamptz(0) key, naming the ALTER TABLE and pgpm.from_hypertable_cutover as the re-run
ok - LIVENESS: u1 is still a hypertable, its copy still recorded, holding 1,2,3
ok - GUARD: the ALTER TABLE the message gives ran on the hypertable
# re-run: ERROR:  pg_partition_magician: from_hypertable_cutover(u1) refusing to swap: the copy u1_pgpm_dest no longer has the source's shape: column ts has type timestamp with time zone on the source but timestamp(0) with time zone on the copy. from_hypertable_copy fix
not ok - the re-run the remedy names (from_hypertable_cutover after the ALTER) is not refused (got '1', want '0')
not ok - u1 is migrated by the remedy as typed: partitioned, registered, holding 1,2,3 (got 'r/0/1,2,3', want 'p/1/1,2,3')
NOTICE:  pg_partition_magician: from_hypertable will copy u1 into a second table before cutover (about 72 kB); ensure that much free disk until the old hypertable is dropped at cutover and the space is reclaimed.
NOTICE:  pg_partition_magician: estimated online copy time ~ 00:00:00.001758 (72 kB at ~40 MiB/s, cache-resident: estimated size fits effective_cache_size). This covers the copy only -- the cutover then rebuilds the primary key and secondary indexes (extra, scales with row count) and a later regrain (if used) is a similar second pass. Rough (measured on a 2XL gp3): more RAM/IOPS/throughput is faster. Override the rate with pgpm.from_hypertable_time_estimate(table, mibps).
```

</details>

### Seed witness

- S1 in `pgpm_hypertable/install.sql` (hypertable_mixed_step_unchecked): **found**

### Coverage and budget

- P1: 11 of 11 units read (1.00)
- surface: 7 file(s), 11 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~141k tokens (11/11 units), claims verifier ~61k (mixed steps under three IntervalStyles and a +05 anchor, live on the timescale harness); acceptance F16r-01 and F16-01, each restored by its own mutation; seed caught; P1-02 (the new #1232 remedy names only from_hypertable_cutover, which the shape check refuses on the two-phase path until from_hypertable_copy is re-run) goes back to the fixer for an in-place round 2 rather than to a candidate verifier

🤖 Generated with [Claude Code](https://claude.com/claude-code)
