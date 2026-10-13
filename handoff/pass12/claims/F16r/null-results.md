# F16r null results (pass 12, slice S12 re-run, tests/timescale/db/33..63, 24 files)

All 24 units read in full against their headers before anything was built. Runs were done in throwaway
`f16_*` databases on pgpm_test-timescale (core + hypertable install + tests/timescale/fixtures.sql), all
dropped afterwards.

## Pre-pass (grep for count(*), sum(, length(, throws_ok(, is(..., 0, and `|| null`)

- 33:116,118,213,215 `count(*)` as owner under FORCE RLS: sound, a premise ("0 of 3") then a postcondition ("0 of 4") against a total read by the bypassing role.
- 33:145,149 `count(*)` of pgpm.config inside a relkind/rows identity string: sound (registration is 0 or 1).
- 33:152 is(count hypertables, 0): sound, LIVENESS paired with the relkind/rows identity just above.
- 33:193 `count(*) as ro_sees_hk`: sound, the role's read of a two-row table, the rows identified by 177's grant check and 148's identity.
- 33:210 ok(count(pg_inherits) >= 2): sound, LIVENESS for the `where n <> '1/1'` null-on-pass at 205.
- 34:78,79,91,132,133,142,148,162 counts of hypertables/config inside identity strings: sound (0/1 flags beside the rows by value).
- 36:109 is(count delta, 0) LIVENESS: sound, the drained rows are identified at 110.
- 44:52, 45:63 throws_ok(sql, '23505', NULL, desc): four-argument form, SQLSTATE pinned, around a plain INSERT (no commit): sound.
- 45:61 is(count unique indexes, 1): sound, the adopted index is identified by oid at 57.
- 46:93,125 delta count equality "no tracked change was consumed": sound enough, the refused step has no path that adds entries; the copy's rows are by identity at 127.
- 48:107 throws_ok(..., '23503', null, desc): four-argument form, pinned SQLSTATE, plain DELETE: sound.
- 48:120 is(count pg_class, 0) LIVENESS: sound (the hypertable dropped on purpose).
- 49:66 count(*) in w49_reads: an instrument (null when refused), asserted against 30 and null: sound.
- 49:127,170,288,344,373,401 is(count, 0): each paired with a liveness that the object existed (104-109, 131, 279/337, 367, 388-392): sound.
- 49:251 count of hypertables inside w49_e_state identity string: sound.
- 50:77 array_length: the sweep's own argument count, not an assertion: sound.
- 50:130 dropped_fk count inside t50_state identity: sound (0 expected after refusals; regex scoped to the table's prefix).
- 50:233 orphan count = 1 in a LIVENESS identity string: sound.
- 50:259 is(count dest, 40) LIVENESS: cardinality, but only a premise that the copy ran; the post-cutover check is by id (1,5,40): sound.
- 54:86,90 cmp_ok/is counts of capture triggers: LIVENESS premises; 103-107 the absences by oid: sound.
- 55:118,120 is(count triggers on the 0.6.0 function, 0): paired with the LIVENESS at 79-92: sound. 55:122 cmp_ok > 0 LIVENESS: sound.
- 56:62,80 is(count operator's a56_pgpm_delta, 0): 62 has the liveness at 54 (the table accepts a row of the capture's shape) and 59 (the write was captured elsewhere); 80 "untouched" is asserted as "still empty", so a TRUNCATE by name would pass it, but any by-name read or delete the module could plausibly regress to errors on that table (it has no pgpm_seq column) and a by-name DROP fails the count with 42P01: noted, not claimed.
- 56:82 count capture triggers = 0: paired with LIVENESS 32-36: sound.
- 57:173,175: as 56; liveness at 155 and 32-36 analogues: sound.
- 58:83-85,119-120,140,142 counts in invariant/LIVENESS strings: sound (flags beside rows by value).
- 59:86-87,114,117-118,138 counts: 86 LIVENESS (0/0), 114 record spent (paired with 89's identity), 117-118 LIVENESS, 138 record spent: sound. 59:126 throws_ok 4-arg 23503 on a plain INSERT, paired with the LIVENESS lives_ok at 128: sound.
- 60:140 is(count scratch, 0): paired with 101-110's identity of what the re-runs recorded: sound.
- 61:99,154 throws_ok(sql, '42501', '<message>', desc): pinned SQLSTATE and message, both LIVENESS premises: sound.
- 62:57 is(count of updated rows reached, 2): cardinality, "which two" not said; the header's mutant (watermark read off the key's own pgpm_seq) reconciles one key and fails 55 and 57 alike, and no plausible defect picks keys {2,3} instead of {1,2} from captures ordered 1,1,2,...: noted, not claimed.
- 62:61 is(count delta, 0) after the drain: paired with the set_eq at 62: sound. 62:77,102 counts of "the rest intact" (182, 96): cardinality over untouched rows, values not compared; the changed rows are by identity in the set_eq: noted.
- 63:52,79 counts of hypertables (1): flags beside identity checks: sound.
- No `|| null` concatenation found beyond 33's own fixed case (issue #1091), which now asserts each absence separately.

## By lens

### fresh surface
- 44/45 (#768/#872, key temp name by destination): read `_from_hypertable_key_tmp` and confirmed both the tracking copy (install line 1290) and every cutover, keyed or not (line 1870), ask it; 44's append-only migration therefore reaches the site. Held.
- 52/53/61 (#979/#986/#1073): the scratch follow and definer capture; 52 says the cutover's grant re-sync is pinned by 53, which pins the owner half only. Since #1073 the capture writes as the owner, so a role's own grant on the delta no longer gates writes; no consequence found.
- 56 (#1037): typed the c56 refusal's remedy (`call pgpm.from_hypertable_copy('c56', 'ts', p_track_changes => true)`) on the harness after dropping the recorded delta: the re-run minted a fresh delta and capture, the next write was captured, and the cutover kept every write (300001 and 300002). Held.
- 57 (#1057): the race's witness is server-side (`pg_locks` polled inside the operator's DO block for the writer's ungranted lock), the writer is sent only after AccessExclusive is seen held; held.
- 58 (#1085): the fix asks transmute's sign rules and `_time_unit_contract` but not transmute's mixed month + duration rule: F16r-01.

### time and zones
- 35: verified the defect's condition is reached. The cutover's pre-drain is `from_hypertable_drain_appends(p_drain_batch, threshold = p_drain_batch)` with the default 5000, so 3 appends leave the whole tail to the cutover's own catch-up (the subject). The keyed fixture's copy watermark is 02:00 (rows every 20 minutes from 00:00), and the explicit pre-drain leaves 02:50, both inside the NY gap. Only a spring-forward gap in one zone is varied; a fall-back hour is not, but a naive value round-tripped through an ambiguous hour returns its own wall clock, so no defect follows.
- 36: the under-lock reconcile site (D) is reached for the same reason (the residual of 1 is within the threshold). Only DateStyle SQL under Asia/Shanghai is varied (the CST abbreviation is the defect's condition). `_from_hypertable_ctl_text` is `set datestyle = 'ISO, MDY'`; its output reads back exactly for an LMT offset with seconds, BC or a five-digit year by construction (ISO).
- Probe beyond the files: a `date` dimension (none in this slice) copied under TimeZone Asia/Tokyo and America/Los_Angeles. `timescaledb_information.chunks.range_start` is UTC midnight (`2023-12-31 09:00+09`), the copy's `(%L::timestamptz at time zone 'UTC')::date` bound recovers the date, and the copy held all ten rows in both zones. Held.
- The frontier check reads a naive column as UTC wall time, the zone transmute's naive grid uses (#504): consistent.

### boundary arithmetic and types
- drain_appends_step and drain_delta_step with p_batch 0 or negative: `greatest(p_batch - 1, 0)` makes a one-row batch, so neither stalls nor errors. A negative p_threshold reaches `offset -1` and fails raw ("OFFSET must not be negative") before anything is consumed: loud, no harm, not claimed.
- `_from_hypertable_tmp_name` at the 63-byte line: the fallback `pgpm_new_<oid>` makes both candidates of `_key_tmp` identical, which still resolves (free or on the destination). Held.
- p_anchor => 'infinity' / '-infinity' on from_hypertable: refused before the copy by `_time_unit_contract` (oddly worded, about fractional digits, but refused with the hypertable untouched); an anchor in year 5000 migrates. Held.

### operator error
- F16r-01 (Tier 3): a mixed month + duration `p_interval` ('1 mon 1 day') passes `_from_hypertable_check_arguments`, the frontier, the handoff-name and preflight checks. The copy and the swap commit (the hypertable is dropped and its incoming key dropped), and transmute then refuses `mixed month + duration interval unsupported` from `_grid_floor`, leaving a plain unregistered table. That is #1085's shape for a fourth argument rule. '1 mon -40 days' (net negative on every date) meets the frontier check first, whose remedy says to delete every row newer than now() - 10 days. tests/timescale/db/58 lines 78-81 pin that frontier refusal as the intended behaviour. The reproduction was run against the tree (fails) and against a scratch copy of the hypertable install with the mixed rule added to `_from_hypertable_check_arguments` (passes, every LIVENESS holding).
- Every refusal in the slice whose remedy is an action was checked for the remedy being typed: 34 (constraint, p_force_frontier), 46 (BYPASSRLS twin), 50 C (VALIDATE), 53 (hand_over_scratch), 59 (the three-call block), 60 (re-run copy), 63 (READ COMMITTED). 50 B's dirty key is the exception: the message's remedy ("VALIDATE CONSTRAINT ... first (or drop the constraint)") applies only through its second branch, since VALIDATE fails over the tolerated orphan. The message offers the drop, so this is not claimed. 56's remedy I typed myself (above).

### failure injection
- 56 injects a dropped delta (the capture refuses, naming the remedy, and the remedy works); 57 injects a concurrent rename with and without a take of the freed name; 59 injects a transmute refusal after the swap (a squatting index name); 61 injects a lost schema USAGE and an owner change mid-window. Not driven by any file in the slice: a cancel or statement_timeout BETWEEN the cutover's swap commit and its transmute call (the state 59 builds by a refusal is the same plain-table-plus-handoff-record state, so 59's remedy covers it), and a crash inside the pre-drain loop (each batch commits whole). No reproduction attempted; see hypotheses.

### contracts versus documentation
- docs/reference.md "`transmute`'s argument rules are asked first" says the cutover and from_hypertable ask the same rules "ahead of every check that reads the table ... with the hypertable untouched". The mixed-step rule is one of transmute's argument rules (reference line ~3067 names '1 month 1 day' and '1 month -40 days' among "the rules transmute applies to a partition_step"), and it is not asked: F16r-01.
- 48 line 147 `LIVENESS: A's change capture went too (#737)` labels a postcondition of the uninstall as a premise. Its wrapper (bench/uninstall_hypertable_copy.sh) counts every `not ok` alike, so no verdict changes; noted, not claimed.
- 49 line 404 says "the operator's tables are untouched by the uninstall" and checks only n49a_mine. I read uninstall.sql's sweeps: both require the module's comment record (lines 276-277, 319-320) and the rest go by pgpm.scratch. So the comment-less n49b_pgpm_delta, n49e_pgpm_dest/delta and n49g_pgpm_delta_fn are not reachable by them. Noted.
- 52 header: "The cutover calls the same helper at its top; tests/timescale/db/53 pins that site". 53 pins the owner-follow refusal at the cutover, not the writer-grant re-sync. Moot for writes since #1073 (see fresh surface), so not claimed.

## Hypotheses (no reproduction)

1. Keyless append-only cutover and ties at the watermark: `_from_hypertable_past(..., p_inclusive => false)` makes the keyless catch-up `control > watermark`. A row appended after the copy whose control value EQUALS max(control) of the copy is caught by neither the pre-drain nor the cutover, and the conservation check then refuses the swap on every re-run (the watermark does not move), blaming out-of-order appends that are not out of order. No loss (the check refuses). The remedy is a fresh copy. Build: keyless hypertable, copy, append one row at exactly the copy's max(ts), cutover. Expect a refusal; check whether the reference documents an equal value as "behind the watermark".
2. from_hypertable_copy under a REPEATABLE READ session default: 63 shows from_hypertable and the cutover refuse, but the copy and the drains are not refused. The copy's horizon record and the drains' snapshot-based reads may assume per-statement snapshots. Build: run from_hypertable_copy(p_track_changes => true) from a dblink session at default_transaction_isolation = 'repeatable read' with a concurrent writer committing between chunks, then cut over from READ COMMITTED and compare rows by identity.
3. A cancel (pg_cancel_backend from a second session) of from_hypertable_cutover after its swap COMMIT and before or inside transmute: this should leave the same state 59 builds by a refusal (plain table, `pgpm.handoff` record, `dropped_fk` rows). Check that the reference's three-call remedy also applies when transmute was interrupted mid-phase (its own claim and bound left behind) rather than refused up front.
