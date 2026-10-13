## #1268: the mixed month + duration step was refused only after the swap

**Defect.** `transmute` refuses a `p_interval` that mixes a month count with a duration (`'1 mon 1 day'`,
`'1 year 2 hours'`, `'1 mon -40 days'`) only in `pgpm._grid_floor` (`mixed month + duration interval
unsupported`), when it first places a bound. `pgpm._from_hypertable_check_arguments` asked
`_refuse_bad_transmute_arguments` (which reads such a step as positive: a whole month first) and
`_time_unit_contract`, neither of which knows the rule. So `from_hypertable` copied and `from_hypertable_cutover`
committed the swap, dropping the hypertable and its incoming foreign key, and only the handoff refused, leaving a
plain table pgpm does not manage. `'1 mon -40 days'` met the frontier check first instead, whose limit then lay in
the past, with a remedy that deleted the newest rows.

**Fix.** `_from_hypertable_check_arguments` (pgpm_hypertable) now calls `pgpm._grid_floor('time', p_interval,
anchor, anchor, 'UTC')` itself, after the two rules it already asked, and refuses its mixed-step error in the
module's pre-swap words (`cannot migrate hypertable X with p_interval ... -- refused before anything is changed,
... (mixed month + duration interval unsupported). Give a whole number of months or a pure duration, then re-run
pgpm.from_hypertable (or pgpm.from_hypertable_cutover, ...)`). Any other error `_grid_floor` raises is re-raised
unchanged, as `_from_hypertable_check_handoff` does for `_part_name`. Calling the function rather than restating
its predicate means the rule asked is the one `transmute` meets. The mixed-step rule is the only argument rule
`_grid_floor` raises for a time grid; the other argument-only rules transmute applies were already asked here
(#1085, #1118).

**Sites covered.** Both module entry points that reach `transmute`, through the one helper they share:
`from_hypertable` before its copy (and so before the cutover it calls), and `from_hypertable_cutover` before its
pre-drain and its swap, ahead of the frontier check, so `'1 mon -40 days'` is refused as a mixed step with or
without `p_force_frontier`. `transmute` itself is unchanged (it still refuses the shape from `_grid_floor`, before
committing anything).

## #1232: the column-unit refusals named transmute as the re-run

**Defect.** `_time_unit_contract`'s date-anchor (#769) and `timestamp(p)` (#1039) refusals, asked by the module
before its copy and swap, ended "then re-run transmute; ... call pgpm.transmute_abort(<table>) first". Raised
there the table is still a hypertable, which `transmute` refuses, and nothing left a bound to abort.

**Fix.** `pgpm._time_unit_contract` (pgpm_core) takes a fifth argument, `p_remedy text default null`, the clause
after "then" in both off-unit refusals; null keeps `transmute`'s remedy word for word, so `transmute`'s own
messages are unchanged (tests/287, /306 pass unchanged, and test 69 pins `transmute`'s text on a plain table). The
four-argument signature is dropped before the create so no call by arity can bind to a copy without it. The
module passes "re-run pgpm.from_hypertable, or on the two-phase path pgpm.from_hypertable_cutover, re-running
pgpm.from_hypertable_copy before it if the column's type was changed (the copy keeps the type it was made with, and
the cutover refuses a copy whose shape is not the hypertable's): this call was refused before anything was changed,
so the table is still a hypertable, which transmute does not take, and no transmute bound was left to abort". The
re-copy clause is round 2 (verification finding P1-02): the `timestamp(p)` refusal offers widening the column, and
after that `ALTER` the cutover alone is refused by its shape check, because the copy `from_hypertable_copy` made
still has the old type. The #581 date-step message names no
call and is unchanged. `_time_unit_contract` is the only core helper the module asks before its swap whose
message names `transmute` or `transmute_abort` as a remedy.

## Acceptance

- Test: `tests/timescale/db/69_from_hypertable_mixed_step_and_unit_remedy_test.sql` (30 assertions). Parts A/B pin
  the mixed-step refusal of both entry points (`'1 mon 1 day'`, `'1 year 2 hours'`, `'1 mon -40 days'` with and
  without `p_force_frontier`), with invariants that each hypertable, its incoming key and its rows are untouched;
  the #1232 part pins the remedy of three refusals (date anchor and `timestamptz(0)` step through
  `from_hypertable`, date anchor through the cutover). Each remedy is then TYPED as its message gives it and
  repairs the table: a whole-month step and a pure-duration step migrate the two keyed tables with their keys
  restored; the anchor at 00:00 UTC migrates both date tables; `ALTER TABLE ... TYPE timestamp with time zone`
  then the same `500 milliseconds` step migrates the `timestamptz(0)` one through `from_hypertable`, and, on the
  two-phase path (u69, copied before the refusal), the message pins the re-copy clause, the cutover alone after
  the `ALTER` is refused by the shape check (LIVENESS), and `ALTER`, `from_hypertable_copy`, then the cutover
  migrates it.
- Guard: `bench/hypertable_mixed_step_and_unit_remedy.sh` (pgTAP wrapper, timescale track, database
  `pgpm_perf376`), run against the real install by `run_timescale`.
- Mutations (timescale track): `hypertable_mixed_step_unchecked` (the `_grid_floor` call becomes `null;`: test 69
  fails 6 defect checks, parts A and B) and `hypertable_unit_rules_transmute_remedy` (the call drops the remedy
  argument: 5 defect checks of the #1232 part fail) and `hypertable_unit_remedy_recopy_unnamed` (the re-copy
  clause removed from the remedy, the half-remedy of round 1: 4 defect checks fail, the two-phase pin among
  them). No LIVENESS line fails against any of them.
- `hypertable_column_unit_rules_unchecked`'s pattern is updated to the new two-line call (it still fails
  tests/timescale/db/66 parts A and B, 7 checks).
- Reproductions: F16r-01's `repro.sh` (#1268), F16-01's `repro.sql` and B04-03's `repro.sh` (#1232) fail on
  `main` at their defect checks, pass on this head, and each mutant brings back exactly its own issue's failures.

P1-02's `repro.sh` cannot pass on any head that keeps the cutover's shape check: it types the half-remedy
(cutover alone after the `ALTER`), which is still, correctly, refused, and its LIVENESS line greps for the round-1
message text, which this head no longer prints. On this head it fails at that LIVENESS line; the two-phase part of
test 69 is its acceptance test.

Caveats: `tests/timescale/db/58`'s `'1 mon -40 days'` assertion pins only the prefix `cannot migrate hypertable
a58 with p_interval 1 mon -40 days -- %`, which the new refusal also carries, so it passes unchanged; it no
longer reaches the frontier check, and test 69 pins the exact message. A pgpm_hypertable from this commit needs
the pgpm_core from this commit (the five-argument `_time_unit_contract`), as #1118 needed its own.

Closes #1268
Addresses #1232 (the remedy of `_time_unit_contract`'s date-anchor and `timestamp(p)` refusals when raised
through `from_hypertable` and `from_hypertable_cutover`)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

