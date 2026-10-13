# Null results: P1, per-PR verification of #1302

Harness: pgpm_prv-timescale (TimescaleDB 2.16) over TCP, fresh databases prv_p1_1302_a..e, each with the tree's
pgpm_core/install.sql, pgpm_hypertable/install.sql and tests/timescale/fixtures.sql; pgpm_prv-15 for the core tests.
All dropped.

## Lens: fresh surface

- The #1268 half of the change is NOT in the tree: pgpm_hypertable/install.sql:452-453 holds `begin null; exception
  when others ...`, not the `_grid_floor` call the body, the CHANGELOG, the function's own comment and
  docs/reference.md describe (the file's mtime, 13:54, is 48 minutes later than every other file of the tree, 13:06;
  the shape is exactly the body's description of the `hypertable_mixed_step_unchecked` mutant). Claim P1-01; the
  PR's own test 69 fails 6 of 27 on this tree.
- The #1232 half holds. `pgpm._time_unit_contract` takes `p_remedy`, splices it into both off-unit raises and only
  those; the old four-argument signature is dropped before the create (one pg_proc row named `_time_unit_contract`
  after install); `_transmute` still calls it with four arguments, so its remedy is the default, word for word the
  old text: tests/287 (42) and /306 (34) pass against this core on PostgreSQL 15, and test 69's assertion 3 pins the
  transmute wording on a plain date table in the timescale harness. The #581 date-step raise names no call.
- Every other argument-only rule is asked up front through BOTH entry points, with the hypertable, its incoming key
  and its rows untouched and no scratch or handoff row left: p_interval '0 days', '-1 day', '-1 mon 40 days'
  (`the partition step must be positive`), p_retain '-1 day', p_obtain -1, p_anchor 'infinity' and '-infinity'
  (refused by the timestamptz(6) unit rule as an off-unit anchor), a date key with '12 hours' (#581) and with a noon
  anchor (#769), a timestamptz(0) key with '500 milliseconds' (#1039). The cutover refuses each with its copy still
  recorded (scratch=1) and then migrates on the corrected re-run (h2 with '1 day', d2 with the 00:00 anchor: relkind p,
  registered, FK restored, rows 1,2,3).
- The remedies as typed re-run cleanly after a refusal: whole-month and pure-duration steps through both entry points
  (test 69, 20-21), the 00:00 UTC anchor through both (22-23), the ALTER TABLE then from_hypertable on a keyless
  timestamptz(0) hypertable (24). Through the cutover after a copy the ALTER remedy is one call short: claim P1-02.
- `_from_hypertable_check_handoff` (unchanged) asks `_part_name`, which reaches `_grid_next` but never `_grid_floor`,
  so nothing else on the pre-swap path asks the mixed-step rule; confirmed by behaviour (the swap committed).
- The `exception when others` handler in `_from_hypertable_check_arguments` can never fire around `null;`, so the
  "any other error _grid_floor raises is re-raised unchanged" clause is untestable on this tree; with the call
  restored, `_grid_floor('time', p_interval, anchor, anchor, 'UTC')` on an infinite anchor is reached only after
  `_time_unit_contract` has already refused it, so no raw PostgreSQL error from the grid can surface there.

## Lens: contracts versus documentation

- docs/reference.md 1058-1082: the argument-rules paragraph's sign, retain, obtain and column-unit sentences hold
  (probed above, both entry points). The two new sentences on the mixed step and "'1 mon -40 days' ... never by the
  frontier check" do not hold on this tree (P1-01: the frontier check refuses it with "Delete or correct the rows").
  "for timestamp(p) widening the column first (the ALTER TABLE the message gives) also works" holds through
  from_hypertable and not through the cutover after a copy (P1-02: the shape check refuses the swap, and its own
  message is what tells the operator to re-copy).
- The #1232 remedy's claim "this call was refused before anything was changed, so the table is still a hypertable
  ... and no transmute bound was left to abort" is true on every refusal observed (hypertable count 1, no
  pgpm_monolith_bound CHECK, no config, no handoff row; the copy's scratch record is the copy's, made before).
- CHANGELOG's #1232 bullet matches the code; its #1268 bullet matches the body and the docs, not the tree.
- The new test's descriptions: every assertion that passes on this tree asserts what the code does; the six that
  fail describe the fix the tree lacks. No assertion passes for the wrong reason (a non-refusing procedure dies with
  2D000 inside throws_like/pg_temp.err, and every defect check pins a message prefix that 2D000 cannot match; the
  state checks are marked invariant).
- bench/hypertable_mixed_step_and_unit_remedy.sh runs the real install on run_timescale, so if the tree is what CI
  sees, the timescale track itself reports the 6 failures (test 69 is in tests/timescale/db/ and the guard re-runs it).

## Hypotheses (no reproduction)

- `ALTER TABLE <keyed hypertable> ALTER COLUMN <dimension> TYPE timestamp with time zone` fails inside TimescaleDB
  2.16 with `duplicate key value violates unique constraint "chunk_index_chunk_id_index_name_key"` when the
  dimension is part of the primary key (observed on k1 and k2, with and without a copy; the keyless u1 and t69 take
  it). So the ALTER the #1232 message gives cannot be typed on a keyed timestamp(p) hypertable at all; the operator
  is left with the other half of the remedy (a whole-second step). That is TimescaleDB's defect, not pgpm's, and the
  message's "or" leaves a working path, so it is recorded here rather than claimed.
- `from_hypertable_cutover` defaults `v_retain` from the source's drop_chunks policy AFTER `_from_hypertable_check_
  arguments` has judged `p_retain` (null), so a policy whose `drop_after` is not a non-negative interval would meet
  `_refuse_bad_transmute_arguments` only at the handoff. TimescaleDB refuses a negative drop_after itself, so no
  value was found that reaches it; not probed further (outside this PR's lenses).
- The tree's hypertable install mtime (13:54 against 13:06 for every other file) suggests the review tree was
  overwritten by a mutation run after it was assembled; if the PR's actual head holds the `_grid_floor` call, P1-01
  is a harness contamination finding rather than a code one, and the coordinator should check which. The claim is
  stated against the tree as given, which is all a finder may review.
