# F15 null results (pass 12, slice S11: tests/28 to tests/99, the rest of the core pgTAP suite)

91 of 98 units read whole (tests/299, 300, 307, 308, 309, 310, 324 not read: budget). One claim built (F15-01, Tier 5).

## Pre-pass (mechanical)

- `throws_ok(` hits (46): every one in the slice is the four-argument form with a pinned SQLSTATE
  (P0001, 23503, 23505, 23514, 22003, 22P02, 22008, 428C9, 42883, 42501) or a pinned message; none is the
  three-argument `throws_ok(sql, NULL, desc)` shape. The ones around a committing procedure (tests/81 and
  tests/83, `call pgpm.transmute`) pin P0001, which a 2D000 cannot satisfy: sound. tests/72 records that its
  old three-argument site was replaced by `throws_like`.
- `count(*)` hits (about 400 across 70 files): grouped verdicts. Sound because paired with identity in the
  same file: 43, 45, 46, 49, 53, 54, 67 (bag_eq after the count), 290, 291, 294, 295, 303, 312, 314, 317, 318,
  320, 321, 323, 325, 327, 328 (counts are of log actions filtered by exact action and range, or LIVENESS
  premises, with rows asserted by identity elsewhere). Sound because the count is of catalog objects by exact
  name/oid or of a single exact log action: 31, 41, 52 (constraint count), 55, 61, 65, 73, 76, 77, 79, 81, 83,
  92, 93, 94, 99. Noted, not claimed (count used where the header asks for conservation, but no realistic
  compensating mutant exists under a primary key and a transmute that moves no rows): 51 (25 rows, and
  contype count 1 not naming the constraint), 52 (40 rows), 70 (2500 rows), 88 and 91 (row count = count
  before), 74 (2001 rows, PK ids), 68 (count 252 plus named rows; untouched neighbours unchecked).
  Claimed: tests/72 line 61 (count 400 over a 5-tenant symmetric fixture, the role outside the policy never
  asked) as F15-01.
- `sum(` hits: tests/316 (sums of pg_stat_xact_user_functions calls, with a ratio and a >=101 liveness:
  sound), tests/317 (index tuples_returned sum: instrument, with liveness: sound), tests/322 (pg_stat sums for
  the H section, PG18 only, with a liveness that a scan moves them: sound), tests/63 (sum(rows_archived)=100,
  backed by the contiguity, first-lo and last-hi checks that prove the chunks tile [0,1000): sound).
- `length(` hits: tests/293 (octet_length of fixed literal names; the 462 = 42*10+42 liveness is odd but
  over literals: sound), tests/79 (array_length of orphan_tables = 0, with the orphan case asserted by value
  later: sound).
- `null ||` hits: none found by the pattern. `is(..., 0, ...)` negatives: each read in place; the unpaired ones
  are listed under the lenses below.

## contracts versus documentation (header promise vs assertions)

- tests/72: claimed (F15-01). A mutant replaying the policy's roles as `public` passes all 15 assertions; ran
  tests/218, 241 and 250 against the same mutant: none fails either.
- tests/47: header and the last description say the preserve FK "was never dropped" across the regrain; the
  swap suspends and re-adds incoming keys inside its transaction (tests/99 header, tests/315 E), so the oid
  changes and the count of 1 cannot see it. The RI contract (no session observes it off) holds; the wording is
  wrong. Not claimed (description only).
- tests/48: assertion (3) names `snapshot()`, which no longer exists in install.sql, and repeats (1) verbatim.
  Redundant; (1) already catches a double count. Not claimed.
- tests/64: header promises the drop lands in the very tick coverage completes; the loop asserts only that it
  dropped within the cap. Not claimed.
- tests/83: its own header says assertions 2 to 5 do not discriminate pre-fix; the first is pinned. Held.
- tests/92: header admits the lock-duration consequence is not pinned (the end state is identical without the
  fix). Held as documented.
- tests/292 D: typed docs/reference.md's `ceil(hi::numeric)` repair; the test uses it verbatim. Held.

## failure injection

- tests/312, 327, 303, 325, 320, 321: each injected failure (killed detacher, lock_timeout, terminated backend,
  in-flight holder) is witnessed by a LIVENESS line that the state was reached. Sibling not driven: tests/327
  part R accepts either outcome of the retire/detach deadlock (by design). tests/325 C drives only the 200 ms
  lock_timeout skip, not a statement_timeout or a cancel of the strategy itself. tests/320 drives the take-over
  of one claim, not a claim whose table was renamed or dropped while the sweep waited.
- tests/94 injects with a dropped relation (deterministic) rather than lock contention; documented.
- tests/298 G: the lost race after a bypass leaves no forget behind; held.

## time and zones

- Zone-varied files: 301 (Asia/Kolkata, Europe/Dublin under SQL DMY), 304 (localtime/posixrules/Factory),
  306 (America/New_York session), 311 (America/New_York fall-back and spring-forward, clk shim), 317 (Asia/Kolkata,
  SQL DMY), 303 C (Asia/Kolkata, SQL DMY). All others run in the session default (UTC/ISO in the harness).
- tests/311 matrix has no case whose '1 day' calendar part lands on a NONEXISTENT spring-forward wall time
  (clock at 02:xx EDT the morning after the change). Worked by hand: PostgreSQL reads the nonexistent 02:30 as
  standard time, 23 hours back, so the horizon stays in the past. Held, no claim.
- tests/316 E and tests/96 D run only under UTC: 96 D computes its expected cells with `_grid_floor(..., 'UTC')`
  and `date_trunc('day', now() + 10 days)` in the session zone, so the file assumes the session is UTC.
- tests/317: the offset-less chunk is placed mid-January so it overlaps whatever the session zone; see H3.

## boundary arithmetic and types

- tests/315: cap = slots/4 integer division; (B) sits exactly at the line (2*cap = slots/2 when slots is a
  multiple of 4, as it is for max_locks x (max_connections + max_prepared) on the harness, 64 x 100). Held.
- tests/305, 302, 39, 86, 293: each refusal witnessed one step either side of the edge. Held.
- tests/322 on PostgreSQL 15: (E) "every partition carries the key as b322 holds it" compares 0 with 0 and
  (H) is skipped; the PG18 contract is not exercised on the core harness. Noted.

## operator error

- Remedies typed from the message: 312 (FINALIZE), 321 (drop the holder), 305 (finest step, wider type),
  306 (transmute_abort), 303 (adopt_partition), 292 (ceil repair), 296 (none needed). Held.
- tests/97: set_obtain refuses a negative and accepts 0; no test of a NULL p_obtain in this slice (outside
  slice ownership to build).

## fresh surface

- 312 to 328 read whole (326 does not exist in the tree). Each new file's fixture separates the defect it
  names; the LIVENESS-prefixed lines read as premises. No prefixed defect check found in these files.

## Hypotheses (not built)

- H1 (tests/68): the mixed-DML case asserts count 252 plus rows 55, 65, 50, 60 by name but not the untouched
  neighbours; a reconcile that dropped one unrelated row of the batch range while resurrecting 50 would be
  caught (50 is checked), but one that dropped row 70 and duplicated nothing would drop the count to 251 and be
  caught too. No compensating mutant found; left as a note.
- H2 (tests/41): `prosrc ~* 'pg_stat_activity' and prosrc ~* 'wait_event'` has no witness that some pgpm
  function reads pg_stat_activity at all (several do, e.g. the snapshot wait); a reader through
  `pg_stat_get_activity(null)` would escape the regex. Build: a mutant _snapshot_wait reading wait_event through
  pg_stat_get_activity, run tests/41.
- H3 (pgpm._over_retired_chunks, install.sql 5144): the overlap test casts ledger and part bounds with
  `::timestamptz` in the CALLER's session zone, so an offset-less retired chunk bound (pre-#500 install or hand
  edit) near a partition's lo is held from a UTC session (pg_cron's maintain) and not from an Asia/Kolkata one
  (a hand _archive_step), or the reverse. tests/317 chose a chunk mid-month that cannot show it. Build: retired
  chunk [2025-12-31 20:00:00, 2026-01-01 03:00:00) offset-less over a partition at 2026-01-01 00:00+00; call
  from UTC (held) and Asia/Kolkata (hi = 21:30Z, not held). Severity depends on whether such rows survive the
  upgrade; not built.
- H4 (tests/80): the ON DELETE CASCADE count of 0 for ofk2 has no witness that ofk2 still held its 100 rows
  after transmute; a transmute that lost them would pass it. Build: a mutant losing ofk2's monolith rows.

## Round 2

- Built: H3 as F15-02 (Tier 3, time and zones; shape 5, an older-install state a reader does not expect).
  `pgpm._over_retired_chunks` (install.sql 5180) reads an offset-less retired ledger bound in the caller's
  TimeZone. From UTC the first attached partition is held over the chunk; from Asia/Kolkata the same call holds
  nothing. Reproduced with repro.sql (4 LIVENESS premises, 1 defect check), run against the review tree.
  I did not drive the downstream `_archive_step` bypass from a Kolkata session (that needs a retention fixture);
  the claim stops at the function's own cross-session contract.
- Not built: H4 (tests/80, cascade count 0 with no witness that ofk2 kept its rows). The only mutant that
  survives the file's other checks would lose rows on the composite-FK table alone, which is contrived.
- Not built: H2 (tests/41, regex negative with no witness). The escaping reader (wait_event through
  `pg_stat_get_activity` in a function that never names pg_stat_activity) is contrived.
- Not built: H1 (tests/68) and the pre-pass count notes (51, 52, 70, 74, 88, 91). I found no realistic
  compensating mutant under a primary key with a transmute that moves no rows, so they stay notes.
