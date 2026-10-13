# F13 null results (pass 12, slice S9: the pgTAP suite tests/01 .. tests/183, 108 files)

No claims filed. Every file in the slice was read in full against its own header, and the whole slice was
run against the review tree (pgpm_test-15, one database per file cloned from a template with the install,
fixtures/demo.sql, pgtap and dblink; tests/31 and 78 are not in this slice). 107 of 108 passed; tests/107
failed one liveness assertion in the suite run and passed when re-run alone (see Hypotheses, H1).

## Pre-pass (mechanical grep: count(*), sum(, length(, throws_ok(, is(..., 0, and null concatenation)

- `throws_ok(` NULL / three-argument shapes around committing procedures: none. Every `throws_ok` around a
  `call pgpm.transmute` pins either the SQLSTATE (tests/09 `'P0001', null`; 125_transmute_preconditions
  `'P0001', msg`) or the message (tests/101 `null, msg`). The remaining `throws_ok(..., '<state>', NULL, ...)`
  sites wrap plain INSERT/ALTER statements (15, 140, 142, 145, 155, 159, 166, 175, 180) or a dblink_exec
  whose remote 55P03 is the asserted liveness (139, 182), none of which can die with 2D000. Sound.
- `sum(`: 107 (sum of reconcile rows = 120002, a LIVENESS beside per-id identity checks: sound); 125_uuidv7
  `coalesce(sum(rows))` of regrain_copy rows (twice) beside an md5 over every row (sound) and
  `sum(rows_archived)` of the ledger as "every row of the aged month was handed" (cardinality; see H3);
  136 `sum(rows)` per table as a LIVENESS beside per-row identity (sound).
- `length(` / `octet_length(`: 124_part_name_length, 143, 150, 160, 161 use them as LIVENESS witnesses of
  exact byte lengths at the 63-byte edge (sound: each is paired with the refusal or acceptance it sets up).
- `is(..., 0, ...)` on counts: read each one; every negative count of this shape in the slice is paired with
  a liveness witness in the same section (e.g. 102, 103, 104, 112, 115, 116, 125_*, 129_*, 130, 141, 146,
  166, 167, 173). Exceptions noted as hypotheses: tests/08 item 5 (H4), tests/101 assertion 5 (H5).
- `|| null` / `null ||`: no site in the slice concatenates a value that can be null into an expected value
  without coalesce; the `string_agg ... = null` assertions (111, 125_day_label, 126, 128, 138) compare an
  aggregate over an empty set to null on purpose and each is paired with a builder-ran liveness. Sound.

## Lens: fresh surface

Read every file the pass-11 fix phase and the lever phase touched in this slice: 125_archive_chunk_ties,
125_archive_ledger_identity, 125_day_label_utc, 125_regrain_candidate_subdivides, 125_transmute_preconditions,
125_untransmute_residue, 125_uuidv7_regrain_archive, the four 129_* files, 147, 155 and 162, plus every
LIVENESS-prefixed premise. Each prefixed line I read is a premise (a state the defect needs), not a defect
check; I found no defect check mislabelled LIVENESS (which would hide a real failure as "fixture never ran").
Checked 147's new deterministic ordering (first-in-tick sequence, is_called read) and 148's X-before-Y
liveness against maintain_all's actual ORDER BY (`sweep_turn_at asc nulls first, parent_table`): both hold.
Checked 162's waits (pg_stat_clear_snapshot each poll) and 149's shell-loop wait that avoids holding a
snapshot against regrain()'s new _snapshot_wait: sound. The one fresh-surface interaction the slice shows is
107 under a busy cluster (H1).

## Lens: time and zones

Zone-sensitive files and what each did NOT vary: 105 (UTC only), 111 (America/New_York vs UTC; no
fixed-offset non-UTC zone), 124_datestyle (DateStyle varied, TimeZone UTC only), 125_day_label (NY, Sydney,
Azores), 126 (NY), 127 (Asuncion, Amman, NY), 128 (NY vs UTC), 131 (UTC), 136 (Asia/Kolkata with SQL
DateStyle: the only file exercising a zone abbreviation; fixed-offset zone with an ambiguous abbreviation),
138/161 (Asia/Tokyo, fixed offset east of UTC), 151 (UTC/London or Azores/UTC chosen by date), 152 (Havana),
163 (Africa/Sao_Tome). No file runs the archive ledger's or the log's bounds from a non-UTC session reader
other than 124_datestyle's MDY reader; no file varies the zone of a pg_cron-like reader for text_time.
These are coverage notes, not defects: the corresponding pgpm code (_ts_text, _grid_floor/_grid_next with an
explicit zone) was read where the tests lean on it and found to take the zone as an argument.

## Lens: boundary arithmetic and types

Probed the edges the tests pin and those they stop one step short of: 124_part_name_length (63/64 bytes both
sides), 143 (only 63 refused and 58 accepted; read the preflight, `octet_length(n || '_pgpm') > 63`, so 59..62
are refused too), 146 (exact int4/int2 ceiling cells), 150 (10^19, sub-minute, fractional labels), 156 (budget
+1 cells refused; read extend_to's measured per-partition slot projection, `v_projected > v_slots / 2`, sound),
174 (exact floor), 175 (malformed max). Probed by hand: transmute on a `time` column whose OLDEST value is
`-infinity`, and on a `date` column holding `infinity` / `-infinity`. `infinity` maximum: refused with pgpm's
message and remedy (documented, reference.md 461). `-infinity` minimum (timestamptz and date): transmute raises
a raw `cannot convert infinity to integer` / `cannot subtract infinite timestamps` from _grid_floor before any
commit; the table is left untouched (no bound, no claim). Not documented either way, nothing lost: hypothesis H6.

## Lens: operator error

Every refusal in the slice was read for whether the test types the remedy: 113 (widened key), 125_transmute_
preconditions (drop the squatter, owner resume/abort), 139/182 (correct step/column), 143 (rename to 58
bytes), 155 (re-add the key by hand), 162/163 (regrain_cancel then retry), 172 (rename aside), 177 (none
offered: a one-way door), 181 (drop/rename the type). Each types the remedy from the message and shows it
working. 108/131/168 type set_retain as the repair of a hand-edited retain and show it. Held.

## Lens: failure injection

Read every injected failure for the sibling it does not drive: 112/128/140 (phase-2 stray via ordered
dblink; phase-1 failure not driven, but phase 1 commits nothing on failure), 115 (four lying strategies;
a strategy that RAISES is driven in 125_untransmute_residue and 129_coverage_reset), 116 (killed detacher),
147 (statement_timeout mid-sweep), 166 (reader blocks the reaper), 167 (held config row), 173 (dropped
referencing table). Sibling not driven anywhere in this slice: a cancel inside _snapshot_wait's poll (the
lever-phase wait) during a hand regrain(); left to the S1..S6 owners as it is pgpm surface, noted in H1.

## Lens: contracts versus documentation

Headers read against assertions. Stale header text (no assertion behind it): tests/08 header item 3 ("the
DEFAULT has exactly two indexes") and tests/02/06's DEFAULT wording describe the pre-#288 DEFAULT partition;
the assertions that remain test the current contract. tests/101's header promises the fresh conversion
"records a claim naming THIS session"; the file asserts only that the claim is gone afterwards (H5; 125's
part C pins the owner elsewhere). 124_datestyle's header lists the archive ledger and transmute_inflight
among the stored texts; the file checks part, log, partition_anchor, frontier and status only (the claim's
lo/hi is pinned in 128). None of these is a test passing for a wrong reason by itself.

## Hypotheses (not reproduced, not claimed)

- H1 (fresh surface, tests/107 and pgpm._snapshot_wait, install.sql ~7707). In the full-slice run, 107's
  LIVENESS 9 failed: the swap tick (regrain_step, PgSleep inside _snapshot_wait) waited on the writer, whose
  DO block holds a snapshot while it polls for the swap's ungranted ACCESS EXCLUSIVE; the writer gave up after
  its 60 s bound, wrote, committed, and the swap then proceeded. Run alone, 107 passes (the swap queues on the
  lock as designed). Mechanism: `backend_xmin` is computed cluster-wide, so a transaction in ANOTHER database
  (other finders' sessions in the shared container) holding an xid at or before config.regrain_written_xid
  makes the writer's backend_xmin <= the reference, and the wait counts a session whose snapshot can in fact
  see the copies. Consequences to build from: (a) tests/107 is a false red whenever any transaction older than
  the copy's last write is open anywhere in the cluster; (b) in production, any long transaction in any
  database of the cluster (a pg_dump of another database) makes every session of this database with an
  active statement look "older than the copies", so maintain's swap defers as skip_regrain at its budget on
  every tick, and a hand regrain() under lock_timeout 0 waits for that foreign transaction. CREATE INDEX
  CONCURRENTLY has the same over-approximation and the comment adopts its rule, so this may be by design;
  reproduction: open a transaction with an xid in database B, then run 107 (or a maintain swap under writes)
  in database A.
- H2 (tests/107 design). Even granting H1, 107's writer holds a snapshot for its whole DO block while waiting
  for the swap; under the new wait any regression that makes the swap wait for that writer turns the file into
  a 60 s stall followed by a liveness failure rather than a direct "the swap waited on a reader it should not"
  failure. Not a pass-for-the-wrong-reason (it fails), so not claimed.
- H3 (tests/125_uuidv7_regrain_archive section C). "the ledger covers exactly the aged month" is
  `min(lo), max(hi)` and "the strategy was handed every row" is `sum(rows_archived)` from `_archive_noop`,
  which counts rows in [lo, hi). Gaps between chunks are not excluded by min/max, and the sum is a
  cardinality. The md5 of the KEPT rows is the only identity check. Building a Tier 5 needs a mutant chunker
  that skips one row's range and double-counts another; the ledger's (parent, lo) key and _archive_step's
  resume-from-watermark probably prevent a gap structurally, so likely sound in practice.
- H4 (tests/08 item 5). `count(*) = 0` of managed partitions lacking the index has no liveness that pgpm.part
  holds any attached row for messages; item 4 (a premade partition has it) makes an empty set unlikely.
- H5 (tests/101 assertion 5). "a completed conversion releases its claim" would pass against a transmute that
  never records a claim; the header promises the record. Covered elsewhere (125_transmute_preconditions part C
  pins owner_pid), so the suite as a whole is not blind.
- H6 (pgpm, transmute with a `-infinity` oldest value on a time/date control, _grid_floor called from
  _transmute line ~603). Raw error instead of pgpm's refusal-with-remedy that the `+infinity` maximum and the
  numeric `-Infinity` id minimum (#895) get; nothing is committed. Operator-error lens Tier 3/4 at most, and
  only if the documentation is read as promising a refusal for every non-finite value.

## Round 2

Built (each run against the review tree in a fresh database in pgpm_test-15, and failing there):

- F13-01 (from H1, Tier 3, fresh surface; install.sql 7737, `_snapshot_wait`'s `age(backend_xmin) >= age(v_limit)`):
  repro.sh opens a transaction holding an xid in a SECOND database of the container before the copies of a
  regrain finish, then starts a reader statement in this database AFTER the last copy committed. The reader's
  backend_xmin is held at or before config.regrain_written_xid by the foreign transaction, and the swap tick
  (lock_timeout 2 s) is refused as "1 snapshot(s) older than the copies". Control: the same swap with no other
  session in this database goes through. The control was first written with a reader present and no foreign
  transaction of mine, and it failed on the shared container: other agents' transactions held xmin back, which
  is the defect itself. So the control now uses no reader at all.
- F13-02 (from H6, Tier 3, boundary arithmetic and types; install.sql 10562, beside the `infinity` newest-value
  refusal): repro.sql. A `-infinity` oldest value on a timestamptz or date control makes transmute die with a
  raw `_grid_floor` error, not with pgpm's refusal and remedy. LIVENESS: the `+infinity` refusal fires on the
  same shape of table. Nothing is committed either way (GUARD).
- F13-03 (from H5, a pre-pass hypothesis, Tier 5; tests/101 line 49): repro.sh derives a mutant from
  $TREE/pgpm_core/install.sql whose `_transmute` records its claim with owner_pid/backend_start null, installs it
  in a second database, shows a claim recorded that way reads as a dead session's (LIVENESS), and runs
  tests/101, read from $TREE unchanged: all 10 assertions pass on the mutant.

Not built (pre-pass hypotheses, with the reason):

- H3 (tests/125_uuidv7 min/max coverage and sum(rows_archived)): building it needs a mutant chunker that
  leaves a gap and double-counts elsewhere so the sum still balances. The ledger's (parent, lo) key and
  _archive_step's resume-from-watermark make that hard to build without breaking the pipeline's other
  assertions in the same file. It did not fit the remaining budget.
- H4 (tests/08 item 5, count = 0 with no witness that pgpm.part has rows): item 4 of the same file needs a
  premade partition to exist, so a mutant that empties pgpm.part fails item 4. Building a passing mutant means
  one that records nothing for messages yet keeps the premade relation, which is an unrealistic state. Left as a
  hypothesis.

Not attempted: H2 (a design note on tests/107 under the new wait; it fails rather than passing, so it is not
a claim of this lens).
