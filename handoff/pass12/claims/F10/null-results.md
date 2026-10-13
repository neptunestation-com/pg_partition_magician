# F10 null results (pass 12, slice S8b: the tests the pass-11 fix phase and the lever phase wrote or changed)

Claims: F10-01 (Tier 3, install.sql `_regrain_fine_count`), F10-02 (Tier 5, tests/timescale/db/65),
F10-03 (Tier 5, tests/timescale/db/66). Everything below held, or is a hypothesis without a reproduction.

## Pre-pass (mechanical grep over the 151 files)

- `throws_ok(` with a NULL or three-argument shape: 11 hits (125 x5, 189:59, 77:166, 92:37, 92:85,
  archive/27:47, timescale/41:44). Every one pins a five-character SQLSTATE (55P03, P0001, 23514, 23P01,
  23503, 22008-class); none wraps a committing procedure with a NULL errcode. Sound.
- `count(*)`: several hundred hits; triaged by file. In the new files they are counts of `pgpm.log` rows by
  exact action and range (one event, named), counts of waiting backends by application_name (liveness polls),
  or `= 0` negatives each paired with a witness that the state was reached (312:97 rows invisible through the
  parent, 314:183 strategy never handed the successor's rows with 314:180 showing the tick reached it,
  316:149/171 one row per cell, 320:159 no claim left beside the named reaped set a,c, 327 per-part counts of
  exact actions beside identity checks of the rows). The exception: 65:126 and 66:136 count `pgpm.scratch`
  rows by `'name'::regclass` AFTER the cutover renamed a new table into that name: CLAIMED F10-02, F10-03.
  74:51 and 74:137 (`count = 2001`) are cardinality checks under a primary key with no write in between;
  not compensating-error shaped; pre-existing and unchanged; sound enough.
- `sum(`: 11 hits, all instrument counters (316 `_native_gt` calls, 317 ledger tuples, 322 H read
  counters), each paired with a liveness that the instrument moves (316:74, 317:74, 322:426). Sound.
- `length(`: 30 hits, mostly `octet_length` of names (208 63-byte key, 189 64-byte label), array
  `cardinality` in pgpm code, not assertions. Sound.
- `is(..., 0, ...)`: 117 hits; the new files' ones are reviewed above. 315:105 (no warning at the line) is
  paired with 315:103/107 (accepted and prepared at the same size). 318:117/125 paired with the method text.
- `|| ... null`: no assertion whose expected value is built by `||` over a possibly-null value was found;
  295's `coalesce(nullif(:'twin_x0', ''), 'the copy wrote no twin')` fails loudly when the copy wrote no twin.

## Lens: fresh surface

- 312 (untransmute vs pending detach): both gates; (B) relies on lock-queue order, and if untransmute were
  granted first it would succeed and the test would fail, so the order cannot make it pass wrongly. Held.
- 313/325 (archive script and step vs hand detach, in flight): identity of strategy calls and ledger; 325 C
  lacks a `call_waited` assertion, but its skip_archive-for-lock-timeout row stands for the wait. Held.
- 314 (`_backfill_chunk_oids`): five block states and an adopted successor, verdicts per chunk. Held.
- 315 (lock budget): A at cap + 1, B at cap, C aged prefix, D/E measured swap, F ordinary. Probing C against
  `_regrain_fine_count` found that the count discounts the aged prefix whenever retain is set, while the
  copy skips it only without an archive_fn (#278, tests/74): CLAIMED F10-01.
- 316 (`_cell_walk_rows/_step`): read both helpers; the walk's passed-row reach rule and the one-directional
  "covered" are as documented. Held.
- 317, 318, 319, 320, 321, 322, 323, 324: read whole against their headers; held (notes in coverage.md).
- 327: read whole (A-N, R); read `_disown_unvouched_retirements` and `_detach_job_holds`; the install pass
  gives an ATTACHED mark its record only when the job holds its detach, as part N says. Held.
- 328/67 (snapshot wait): read `_snapshot_wait` in full: `age(backend_xmin) >= age(limit)`, the
  directly-blocked exemption only against the caller's own xid, the chained refusal, the marker yield, the
  budget = lock_timeout. G's mid-statement reader (pg_sleep 1.5 s) outlasts maintain's 200 ms budget, so it
  really is mid-statement when the budget ends. Held.
- 64/65/66 (hypertable): 64 names copies by recorded oid (r64_rel) and holds; 65 and 66 name scratch rows by
  the post-cutover names: CLAIMED F10-02/F10-03 (reproduced: both files stay green, 17/17 and 20/20,
  against a `from_hypertable_cutover` with its `delete from pgpm.scratch where parent_oid = p_hypertable::oid`
  removed, which leaves 6 and 3 rows).
- 303 F/G (adopt_partition vs pending detach): witnessed in pg_locks, refusals pinned. Held.
- 147 (sweep turns): the clock cut set by order (first-in-tick sequence), not speed. Held.
- Label-only files (about 110): every relabelled line read in its hunk; each prefixed line is a premise. No
  defect check carries the prefix, with the one exception claimed (66:136, a postcondition labelled
  LIVENESS that is also vacuous).

## Lens: time and zones

- Zone-sensitive files and what each did not vary: 316 E (time grid under the session zone only); 319 (UTC
  only, but a fixed step is an absolute lattice, so '24 hours' = '1 day' in any partition_tz: `_grid_floor`
  and `_grid_next` read); 317 (UTC and Asia/Kolkata with SQL,DMY; offset-less bound far from any edge, H4);
  320 (UTC); 323 (UTC); 324 (Europe/London, America/New_York, Etc/UTC for naive keys; no fixed-offset
  non-UTC zone such as Asia/Tokyo for a naive key); 303 C (Asia/Kolkata + SQL,DMY); archive 51 F
  (Asia/Tokyo for a timestamptz cursor under a timestamp parent); 67 (server default).
- `archive._cursor_text` pins TimeZone and DateStyle; `to_s3` pins extra_float_digits = 1, so real/double
  cursors round-trip. IntervalStyle is not pinned (H6).

## Lens: boundary arithmetic and types

- 315's line: `2 * v_n > v_slots / 2` with `v_slots / 4` as the cap is consistent for every residue of slots
  mod 4 (checked by hand); A at cap + 1 and B at cap sit exactly on it. Held.
- archive 51: char(3), numeric(10,2), bit(3), domain with NOT VALID check, enum, composite, array, json,
  regproc, view, foreign leaf, matview, domain over enum. The allowlist plus the parse probe matches the
  header. Held.
- 316: a dead row over a BUILT cell in both B and D (asymmetric 3 holes/4 dead vs 1 hole/2 dead). Held.

## Lens: operator error

- 324 names `pgpm.untransmute(...)` then re-transmute as the remedy; the test types untransmute only on
  y324 (the refusal), never the remedy on d324 (H5).
- 319: set_regrain twice with a respelled target; a hand run with regrain_to null still refused. Held.
- 303 D: every refusal paired with the allowed call after the obstacle goes. Held.

## Lens: failure injection

- 312/327: an interrupted DETACH CONCURRENTLY (terminated in its virtualxid wait) driven for real. Sibling
  not driven: a detach cancelled (pg_cancel_backend) rather than terminated, which leaves the same flag; the
  catalog state is the same, so no different path is expected.
- 320: a dead owner made real by ending a dblink session; sibling not driven: an owner pid reused by another
  backend (backend_start differs), covered by `_session_alive`'s two-field check (read).
- 147: statement_timeout inside the archive strategy, by order. Held.
- 65 drives a delta moved and renamed, and one dropped by hand; 66 drives refusals before the copy and before
  the swap. The sibling 65/66 do not catch: a swap that leaves its scratch records (F10-02/03).

## Lens: contracts versus documentation

- 315 header: "The aged prefix a retention policy discards is not counted, since the copy skips it": the
  copy does not skip it under an archive_fn (#278), and the count does not ask (F10-01).
- 66 header calls its last block LIVENESS witnesses; the scratch line is a postcondition, and vacuous (F10-03).
- 317 header's remark that 17+ admits the subtransaction in parallel mode was not tested (not in scope).

## Hypotheses (not counted)

- H1. `set_regrain`'s warning path (`_regrain_swap_budget(..., p_catalog_only => true, p_warn => true)`)
  shares F10-01's discount: with an archive_fn set and retain set, `_regrain_fine_count` subtracts the aged
  prefix from the catalog-only count too, so set_regrain neither warns nor logs `warn_regrain_lock_budget`
  for the run F10-01 shows prepared. Build: F10-01's fixture, then `select pgpm.set_regrain('public.f10a',
  '100')` in a second psql and grep its WARNING.
- H2. When F10-01's run reaches its swap, the swap's measured budget (regrain_step around line 8564) should
  refuse it; not driven to the end (3204 copy children at stock settings). If the measured projection
  under-counts for some reason, the swap would try to hold more than half the lock table (Tier 2). Build with
  a server started with a small max_locks_per_transaction (e.g. 10) so cap is small.
- H3. 323 keys every table `collate "C"`. A text_time key under a non-C collation (tests/122, 134, 274 shapes)
  with an off-shape value: the copy places a row by the column's collation (`>= lo_lit and < hi_lit`), and
  `_regrain_reconcile` places a captured off-shape key "by its ENCODED value"; if the reconcile compares
  bytewise or under another collation than the copy's predicate, an off-shape key between the two orders is
  reconciled into a different fine child than the copy put its row in (a duplicate after the swap, or a
  DELETE that misses). Mechanism to read: `_regrain_reconcile`'s grouping for unshaped keys.
- H4. `_over_retired_chunks` with an offset-less ledger bound near a partition edge: the bound is read in the
  session TimeZone (317 keeps gone_z mid-January), so a retired chunk ending at '2026-01-01 03:00:00' is over
  the first partition from Asia/Kolkata's session but not from UTC's (or the reverse), and the archive step
  and retain() run from different sessions (pg_cron vs a hand call) disagree on holding it.
- H5. 324's remedy for an off-unit grid (untransmute, then transmute with whole-unit anchor and step) is
  never typed on d324 (all rows in the monolith); the forward partition p_obtain => 1 built may already hold
  a row or not; whether untransmute accepts d324 and the re-transmute at '2000-01-01 00:00:00+00' then
  succeeds is unproven by the test.
- H6. `archive._cursor_text` does not pin IntervalStyle; an interval control column exported from a session
  with IntervalStyle = 'sql_standard' renders mixed-sign intervals in a form whose read-back has differed
  across versions; if it reads back as another value, the next page's `>` skips or re-reads rows (refused
  as a write, or never ends). Build: archive 51's shape with an interval column holding '1 day -1 hour' and
  fetch_rows 1, under `set intervalstyle = 'sql_standard'`.

## Round 2

- Pre-pass: no pre-pass line was left as "claimed" or as a hypothesis unbuilt. The two claimed lines (65:126,
  66:136) are F10-02 and F10-03 from round 1. 74:51/137 were judged sound (PK-bounded counts with no write
  between), not left as hypotheses.
- H1 BUILT as F10-04 (Tier 3; shape 4, the sibling copy of F10-01's mechanism). set_regrain on F10-01's fixture
  (archive_fn set, retain set, monolith 3204 sub-ranges against a line of 1600) stores the target with no
  WARNING and no warn_regrain_lock_budget row. Its catalog-only branch of `_regrain_fine_count` subtracts the
  aged prefix by the newest attached hi, even though the copy keeps that prefix under an archive_fn.
- H2 DRIVEN, NOT A NEW DEFECT. F10-01's run, ticked to the end on pgpm_test-15 (64 x 100 = 6400 slots,
  5 min 38 s): 3204 sub-ranges were copied (3203 `copied:0`, one `copied:1`). Every swap tick after that
  refused: "attaching its 3204 fine partitions ... about 6408 lock-table slots ... more than half ...".
  So the swap's measured budget holds. The run then repeats that refusal on every tick until
  regrain_cancel or a restart with a larger max_locks_per_transaction: the copy-everything-then-refuse cost
  that F10-01 describes, measured. F10-01 was not revisited.
- H6 TRIED, REFUTED on the archive harness (PostgreSQL 17). Under IntervalStyle sql_standard, every mixed-sign
  interval tried ('1 day -1 hour', '-1 day +1 hour', '1 mon -1 day', '-1 mon 2 days -3 hours', '-1 day
  -1 hour', '1 year -1 mon') reads back equal from its text, so the cursor round-trips. PostgreSQL 15/16
  were not checked, because the archive harness is 17.
- Not attempted (budget): H3 (non-C collation off-shape reconcile), H4 (offset-less ledger bound near an
  edge), H5 (324's untransmute remedy typed on d324).
