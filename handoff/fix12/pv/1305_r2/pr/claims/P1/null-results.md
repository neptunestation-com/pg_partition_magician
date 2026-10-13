# P1 null results: PR #1305 round 2

## Lens: fresh surface

- `pgpm._native_bound_key` (install.sql 5159-5171): probed by hand from a session on Asia/Kolkata, `SQL, DMY`,
  `timezone_abbreviations = 'India'`: `'2026-01-01 00:00:00'` with p_tz Asia/Tokyo is the epoch of
  `2026-01-01 00:00:00+09` (offset-less text on the given clock, not the session's); `'01/03/2026 00:00:00'` reads as
  3 January (`ISO, MDY` pinned, not the session's DMY); `'01/01/2026 03:00:00 IST'` reads as `2026-01-01 01:00:00+00`
  (Israel's +02 from the `Default` set, not India's +05:30: round 1's V-01 is fixed in the helper); the `id` kind
  returns `p_text::numeric`; `'infinity'` keys as `Infinity` on PG 15 (and no pgpm.part bound is ever infinity, the
  only `'infinity'` casts in install.sql are retiring_at / retry_after sorts). After the call the session still read
  `Asia/Kolkata / SQL, DMY / India`: the function SET clauses restore all three, the `set_config(..., true)` inside
  included (tests/334 parts F and H, 12, 13 and 22, pass on this head). Held.
- The pin's restoration when the helper raises on unparsable text: the SET clause restores on error exit as on
  normal exit (PostgreSQL's rule for a function SET clause); not separately exercised.
- The materialized CTE shape: `lo_k`/`hi_k` are computed once per row after the parent filter and the retired /
  floor filters (#973 and #1163 kept). The floor read still goes through `_native_order_key` and keys only
  offset-carrying text; an unkeyed hi is always a candidate (checked by reading, and by the UTC run holding
  offset-less rows). Held.
- The overlap join, the `m.lo_k < max(x.hi_k)` prefilter and the description's `order by l.lo_k` all use the keys;
  no `::%1$s` cast is left inside `_over_retired_chunks`. Held. The one defect is the VALUE handed as p_tz (P1-01).
- `pgpm.retain` and `pgpm._archive_step` call `_over_retired_chunks` unchanged and only consume `child_name`
  (and lo/hi/chunks/other_names for the skip row). Their own candidate queries (`hi::timestamptz <= boundary`,
  the orphan-discard overlap) still cast in the caller's session, which the PR body names as adjacent and
  out of scope (unretired rows, pgpm.part bounds pgpm itself always writes with an offset). Not claimed.
- `bench/over_retired_chunks_grid_zone.sh`: the wrapper reports the file's `not ok` lines, counts assertions
  reached and fails on zero; it is `bench/retain_recall_moved_parent.sh`'s shape. Against THIS head it would
  FAIL (tests/334 fails 5 of 22 here), so the body's "green on PG 15 and PG 18" is not kept on this tree; that is
  the same root cause as P1-01, not a separate claim.
- `test.sh` line 1259: the guard is registered in the perf list as `pgpm_perf372`, a database name no other entry
  in the list uses. Held.
- `CHANGELOG.md` and `docs/reference.md` hunks describe the intended behaviour (grid clock, `ISO, MDY`, `Default`
  abbreviations, caller's settings untouched). On this tree the first of those is not what the code does (P1-01);
  the other three are.

## Lens: time and zones

- Five session zones (Asia/Tokyo, UTC, Asia/Kolkata, Pacific/Kiritimati, America/Los_Angeles), three DateStyles
  and two abbreviation sets, through the PR's own tests/334 run on this head: parts A, F and H (the grid's own
  zone, the settings' restoration, the abbreviation pin) pass; every cross-zone part (B, C, D, E, G) fails,
  because the zone the helper is given is the caller's. P1-01 covers this with its own asymmetric fixture
  (one chunk gained from UTC, one lost from Kiritimati).
- DST: an offset-less bound inside a DST gap or overlap in partition_tz would be read by PostgreSQL's rule for
  that zone, the same way `_col_to_native` reads a naive column; the same rule in both places, so no new
  disagreement. Not exercised.
- A `timestamp`/`date` (naive) control column has partition_tz 'UTC' (#504) and its bounds are written by
  `_ts_text` with an offset; an offset-less legacy bound on such a grid reads as UTC wall time, which is the
  column's own clock. Consistent with `_col_to_native`. Held by reading.

## Hypotheses (no reproduction)

- `pgpm.retain`'s candidate query (`hi::%s <= boundary`) and `_archive_step`'s orphan-discard overlap still read
  pgpm.part and unretired ledger bounds in the caller's session; an operator's hand-written offset-less
  pgpm.part bound (tests/317 part C's shape) is read on the session clock there while `_over_retired_chunks`
  (once P1-01 is fixed) reads it on the grid's. Adjacent, named out of scope by the PR body; worth its own
  bullet rather than a claim here.
- `_archive_fully_covered`'s watermark over an unretired pre-#977 offset-less row (the body's own adjacent note).
