# P1 null results: PR #1302 round 2

## Fresh surface

- `pgpm._from_hypertable_check_arguments` (pgpm_hypertable/install.sql 447-462): read whole. The #1232
  remedy argument to `_time_unit_contract` is present and names both paths (from_hypertable; the cutover,
  re-running from_hypertable_copy first when the type was changed). The #1268 `_grid_floor` call is NOT
  present: the inner block is `begin null; exception when others ... end;`, so the handler is dead and the
  mixed-step rule is never asked. Claim P1-01 (Tier 3). Verified by running tests/timescale/db/69 against
  the tree as installed: exactly its six #1268 checks fail (4, 5, 6, 7, 10, 11), every #1232 check and
  every LIVENESS line passes; and by a scratch-database-only copy of the function with the call present,
  against which P1-01's repro.sh passes (exit 0) and test 69's shape of failure is explained.
- `pgpm._time_unit_contract` (pgpm_core/install.sql 9069-9105): the fifth argument defaults to null and
  `coalesce` keeps transmute's remedy word for word; both off-unit messages take `v_remedy` after "then";
  the #581 date-step message is unchanged and names no call; the four-argument signature is dropped before
  the create, so an older module's four-argument call binds to this one by default. `_transmute`'s call
  (10193) passes four arguments and so keeps transmute's text (test 69's LIVENESS pin of the noon anchor on
  a plain date table passed on the tree). Held.
- `pgpm.from_hypertable` (2432-2473) and `pgpm.from_hypertable_cutover` (1639-2420): the one shared helper
  is called before the copy (from_hypertable) and before the pre-drain, the lock and the swap (cutover),
  ahead of `_from_hypertable_check_frontier` at both sites, so the fix's ordering claim holds once the
  call exists. No other site in either procedure asks `_time_unit_contract` or `_grid_floor`.
- Two-phase remedy as typed (round 1's P1-02): on the tree, u69's part of test 69 passed: the cutover's
  timestamp(0) refusal pins the re-copy clause, the cutover alone after the ALTER is refused by the shape
  check (LIVENESS), ALTER + from_hypertable_copy + cutover migrates u69 with 41,42,43. Held.
- `bench/hypertable_mixed_step_and_unit_remedy.sh`: the standard pgTAP-wrapper verdict block (raw ERROR,
  psql exit, plan count), scratch database `pgpm_perf376`, test file overridable by env; `test.sh` calls it
  on the timescale track with that database. Its header names two of the three mutations the body lists
  (`hypertable_unit_remedy_recopy_unnamed` is not named in the header comment): a comment, not a defect.
- `test.sh` 601-604: the new guard line matches the sibling guards' form and database naming. Held.

## Contracts versus documentation

- docs/reference.md 1062-1084 against the code: the remedy sentence quotes the module's message text
  exactly as `_from_hypertable_check_arguments` passes it, and the "widening the column also works: then
  re-run from_hypertable, or on the two-phase path from_hypertable_copy and then the cutover" sentence is
  what test 69 typed and what passed on the tree. Held.
- docs/reference.md 1081-1084 ("a p_interval that mixes a month count with a duration ... is refused before
  the copy and the swap"; "'1 mon -40 days' ... is refused that way, never by the frontier check"): NOT kept
  on this tree, same root cause as P1-01 (the repro's '1 mon -40 days' check is that sentence). Folded into
  P1-01 rather than filed as a separate Tier 4, since the code, not the sentence, is wrong.
- CHANGELOG.md 5-27: the two entries describe the fix as the body does; the #1268 entry is not kept on this
  tree (P1-01). The #1232 entry is kept.
- PR body "transmute itself is unchanged": test 69's LIVENESS lines pin transmute's mixed-step refusal and
  its date-anchor remedy on plain tables; both passed on the tree. Held.
- tests/timescale/db/58 lines 78-81: pins only the `cannot migrate hypertable a58 with p_interval 1 mon -40
  days -- %` prefix, as the body's caveat says, so it passes on this tree too (the frontier refusal carries
  the same prefix); that is why only test 69 catches P1-01.

## Hypotheses (no reproduction)

- `_grid_floor` refuses only `v_months > 0 and v_fixsecs <> 0`; a step with months < 0 is refused earlier
  by `_refuse_bad_transmute_arguments` (months < 0 is "not positive"), so no mixed negative-month step reaches
  the grid. Not probed further; looked sound by reading.
- A pgpm_hypertable from this commit on an older pgpm_core (four-argument `_time_unit_contract`) fails every
  from_hypertable call with "function does not exist" at the five-argument call. The body states the
  dependency; no install-time check exists in the module for it. Out of the slice's units; not built.
- The bench wrapper's header comment lists two mutations where the body lists three; cosmetic.
