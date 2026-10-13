# P1 null results: per-PR verification of #1293 (check_time_monotonic in UTC)

Harness: `pgpm_prv-15`, fresh database per run, the review tree's `pgpm_core/install.sql` installed with
`--single-transaction`, database dropped after.

## Lens: fresh surface

- `pgpm.check_time_monotonic` (14295-14317): read whole. The body of the function is unchanged from the
  shape the issue describes (`%2$I::timestamptz as t`, `lag(t) over (order by idv)`, `t >= prev`), the
  null-argument and filtered-read refusals come first as before. The one thing the change promises here,
  a function-level `SET timezone = 'UTC'` between `language plpgsql` and `as $$`, is NOT on this tree:
  the function header reads `language plpgsql` / `as $$` with nothing between, and `pg_proc.proconfig`
  for the function is null after install. That is claim P1-01 (reproduced: `(3,3,1.0000)` from
  America/New_York against `(3,2,0.6667)` from UTC on the same column).
- The comment hunk 14287-14294: states the SET clause and its consequences; it is accurate for the
  intended fix and wrong for this tree (covered by P1-01's scenario rather than a separate Tier 4 claim,
  since it is a code comment and changes nothing an operator types).
- `CHANGELOG.md` entry and `docs/reference.md` 3481-3485: both describe the guarantee; the reference text
  is what P1-01's reproduction asserts (same answer from every zone, naive column as its own wall-clock
  values, `timestamptz` by instant). Not filed separately: one root cause, one claim.
- `tests/335_check_time_monotonic_session_zone_test.sql`: read whole. The fixtures are asymmetric
  (dip335: three pairs, one falling), every negative is paired with a liveness line, the
  spring-forward premise is asserted before use, Part D's `off335` carries its own two liveness lines
  (falls as text, rises as instants) so "compared by instant" cannot pass vacuously, Part E's TimeZone
  checks are preceded by a liveness call. I found no assertion that would pass for the wrong reason:
  against this tree (no SET clause) parts A (test 3), B (test 6) and C (test 8) fail, matching what the
  body says the mutation produces; D and E hold with or without the clause, as expected since D's
  fixtures are zone-independent by instant and E only reads `current_setting`.
- `bench/check_time_monotonic_session_zone.sh`: read whole. Installs the arbitrary `install.sql` under
  `ON_ERROR_STOP` and reports a mutant that does not install as a FAIL, runs pg_prove on tests/335,
  asserts the count of assertions reached separately (`LIVENESS: the assertions were reached at all`),
  drops its database. `TAP_GUARD_TEST_FILE` override present. Nothing to claim.
- `test.sh` 1268: the guard is registered in the perf shard list with `pgpm_perf373`; that database name
  occurs once in the file (no collision with another guard's database). Nothing to claim.

## Lens: time and zones

- Sibling check functions, as the brief asked: `check_uuidv7` (14150) decodes through `pgpm._uuid_to_ts`
  and compares against `timestamptz '2015-01-01'` and `now()`, no column cast through the session zone;
  `check_text_time` (14209) takes `p_epoch timestamptz` as a bound parameter (`using p_epoch`) and
  compares decoded instants, no `::timestamptz` of a column. The body's statement that neither needs the
  change holds on reading.
- `date` column (body: compared as its own wall-clock values): `date::timestamptz` is midnight of the
  session zone; with the clause in place it is midnight UTC, and no zone has a transition at a date
  boundary that reorders two dates. Holds by reading; on this tree it holds anyway, since no two
  distinct dates can swap under any zone's cast.
- Fall-back repeated hour: a naive pair 00:30, 01:30, 02:30 on 2025-11-02 cannot be reordered by the
  session cast because PostgreSQL resolves an ambiguous wall time consistently and the surrounding hours
  bracket both readings; only a spring-forward gap can reorder a rising naive column. So the fixture
  class the fix targets (the gap) is the only one; held by reasoning, not built.
- Caller's TimeZone after the call: a function-level SET is restored on return in autocommit and under
  `SET LOCAL`; tests/335 Part E asserts both. On this tree there is no SET clause so the setting is
  trivially unchanged; nothing to claim either way.
- `timestamptz` column and text with explicit offsets: the cast is kept, so comparison stays by instant
  on this tree and on the intended one; tests/335 Part D holds here (observed by reading the function;
  the cast is unchanged).

## Hypotheses (no reproduction built)

- H1 (the body names it as not covered): a text column holding `MM/DD/YYYY` wall times parses under the
  caller's `DateStyle`, so `'03/08/2026 ...'` means March 8 under `MDY` and 3 August under `DMY`, and a
  column's fraction can still differ between two sessions that set different `DateStyle`. The clause the
  PR adds (`SET timezone`) does not pin `DateStyle`, unlike `archive._row_digest`'s shape it cites, which
  pins `datestyle = 'ISO, YMD'` as well. Out of the PR's declared scope; worth an issue of its own if the
  reference's "does not depend on the caller's TimeZone" is read by an operator as "does not depend on
  the session".
- H2: the body says the guard fails on tests 3, 6 and 8 against the mutation; consistent with my reading
  of what the clause-less function returns on each fixture, but I could not run `discriminate` (the
  mutation catalogue is out of bounds).
