# F2 null results (pass 12, slice S2)

Every unit of the slice was read whole against its own comment (see coverage.md). Experiments ran in
throwaway databases `f2_*` on `pgpm_test-15` (PostgreSQL 15.19, `--with-system-tzdata`) and one on
`pgpm_test-archive` (PostgreSQL 17.11); all were dropped.

## fresh surface

- `_naive_grid_zone_off` (new, #1117 V-01): asked which zones it calls off. It returns true only when a
  zone's offset at the 1st of some month 2000-2100 differs from its offset at 2000-01-01, i.e. when the
  offset VARIES. Its comment, the CHANGELOG (#1117: "a zero-offset zone such as Etc/UTC counts as UTC") and
  docs/reference.md `set_regrain` ("a zone whose offset is always zero ... is UTC here") all say ZERO. So
  every fixed-offset zone (America/Phoenix, Asia/Tokyo, Asia/Kolkata, Pacific/Honolulu, Etc/GMT+5) is called
  on-clock. Built: tests/324's own fixture (frozen monthly date monolith, zone planted as an older install
  recorded it) with America/Phoenix: `regrain(.., '1 day')` is not refused, every fine bound renders as the
  date before, and the swap drops the rows dated the monolith's last day. **Claimed F2-01 (Tier 1).** The
  upgrade block's `warn_grid_off_unit` uses the same predicate and misses the same grids (in the claim).
  East-of-UTC constant zones on a UTC-built grid do not lose rows (00:00Z reads as the same date); on a grid
  built in the zone (a real pre-#504 install) the first clamped sub-range reads as empty and the swap fails.
- `_time_unit_breach` asked of the registered grid: date anchors before 1970 (negative epoch, numeric `%`
  keeps the sign: -86400 % 86400 = 0, -43200 refused), typmod 0 and -1, a domain over a domain (unwrapped by
  both callers' loops). Held.
- The install block after `_regrain_step_forward`: a parent that is gone (skipped), a renamed key (followed by
  attnum), an unknown recorded zone (`_naive_grid_zone_off` catches 22023 and returns false; the block
  continues). Held.
- `_retain_horizon` (#627): read against tests/311's claims; see time and zones. Held.

## time and zones

- `_ts_text`, `_time_literal`, `_native_text`, `_col_to_native`: rendered and re-parsed under 'SQL, DMY',
  'German', 'Postgres, YMD' and ISO, Asia/Kolkata (whose 1800 LMT offset has seconds), 5-digit years
  (10000-03-01) and BC years; every literal parsed back to the same instant. Held.
- `_grid_floor` / `_grid_next` calendar branch: property sweep (floor <= x < next, floor(next) = next) over
  26 zones (Havana, Asuncion, Amman, Santiago, Sao_Paulo, Beirut, Damascus, Cairo, Gaza, Nuuk, Apia, Tehran,
  Lisbon, Scoresbysund, Azores, Casablanca, Mazatlan, Dhaka, Caracas, Kiritimati, Goose_Bay, Troll, Moscow,
  Kwajalein, Kolkata, St_Johns), steps 1, 3 and 12 months, every local midnight on the 1st from 1950 to 2040
  +-1 us, 30, 60, 90, 120 minutes. No violation. Fixed branch from anchors in year 1, 4000 BC, 9999 and
  200000 with fractional steps down to 1 us: no violation except `timestamp out of range` at the range's
  far edge (anchor 4000 BC, value 290000 AD), not a realistic grid.
- `_retain_horizon`: Pacific/Apia's skipped 2011-12-30 gives exactly now() for '1 day' (as the comment
  says); spring-forward gap and ambiguous earlier wall time resolve into the past. Held.
- `adopt_partition` (a caller of `_col_to_native`): under Asia/Kolkata with 'SQL, DMY' pg_get_expr renders
  'IST', which this server parses as Israel; the adopted row still recorded the right instant, so the
  function's session pinning holds the reference's "read the same way whatever the caller's DateStyle and
  TimeZone". Held.
- `check_time_monotonic`: casts the time column `::timestamptz` in the caller's zone, so a naive timestamp
  pair straddling a spring-forward gap is counted decreasing (0.5 vs 1.0 from UTC). **Claimed F2-02
  (Tier 3).**
- `_uuid_to_ts` / `_text_time_to_ts` go through float8 (to_timestamp, interval_mul); swept the uuid round
  trip monthly 2000-10000 exactly; error past 2^53 us is sub-ms and grid bounds are whole ms, so no
  placement changes. Held.
- IntervalStyle: stored steps and retains render as `interval::text` in the writing session; round trip of
  13 shapes under sql_standard, iso_8601, postgres_verbose and postgres parsed back equal. Held.

## boundary arithmetic and types

- `_floor_div` signs and -Infinity; `_id_label` / `_is_fine_child_label` negatives and fractions (-0.5 ->
  `00000000000000000-1_5` round-trips), 20-digit values; `_part_name` byte budget figures in the reference
  (43/54 monthly, 19/42 id, staging +9) recomputed. Held.
- `_text_time_to_ts_bounded`: interval edge 9223372036853 s and timestamptz edge 9224318015999 s, ms branch,
  infinite epoch. Held.
- `_retain_nonnegative`: id 'Infinity' is accepted (horizon -Infinity: keeps everything, harmless); PG17
  interval 'infinity' raises a bare 'interval out of range' from `_retain_nonnegative` rather than the
  pgpm refusal (message quality only), '-infinity' is refused. Not claimed.

## operator error

- `_canonical_tz` / `set_partition_tz`: 'EST', 'EST5EDT', 'PST8PDT', 'US/Eastern', 'UCT', 'Zulu', 'GMT0',
  'posix/UTC', 'right/UTC', 'localtime' all return null on this host (its system tzdata ships no legacy
  links), so they are refused; 'utc' canonicalises to 'UTC'. The docs say a POSIX rule or bare abbreviation
  is refused; a legacy link name (US/Eastern) is refused here too though it is neither (host-dependent).
- `set_partition_tz` on a naive key: refused. On a grid whose recorded zone the host no longer knows
  (America/Godthab, planted): the switch to UTC still succeeded. Held.
- `check_text_time` / `check_uuidv7`: shape refusals before a row is read, NULL-skipping maximum. Held.

## failure injection

- The upgrade block against a missing parent, an unknown zone and a renamed column (above). Held.
- `_frontier_native` against a dropped parent (raises the forget_missing message) and an undecodable
  text_time maximum (falls back to now()). Held.

## contracts versus documentation

- reference.md "Partition naming": label grains, `_bc`, id padding, explicit-range names, byte budget. The
  sentence "a year, month, day or hour step is labelled at that grain, a step of a minute or more to the
  minute" leaves a 90-minute step's grain implicit (the code labels it to the hour, which stays injective).
  Not claimed.
- reference.md `set_regrain` / `warn_grid_off_unit` / CHANGELOG #1117 versus `_naive_grid_zone_off`: broken
  for fixed-offset zones (F2-01).
- reference.md `check_time_monotonic`: "fraction of adjacent pairs whose time is non-decreasing" (F2-02).

## Hypotheses (not reproduced)

1. **A monthly `date` grid anchored at noon is refused and flagged as off its unit though its month bounds
   are midnight.** `_time_unit_breach` (date branch) refuses any anchor with `epoch % 86400 <> 0`, and
   `_regrain_step_shape` raises it for ANY target, the install block logging "every partition obtain mints
   is attached at other bounds than pgpm.part records for it". But `_grid_floor`'s month branch uses only
   `date_trunc('month', anchor at partition_tz)`, so a month-step grid's bounds are midnight UTC whatever the
   anchor's hour, and pgpm.part and the catalog agree; only a FIXED target would be off. The documentation
   says "any target at all", so this is over-refusal plus a warning whose text is false for month steps, not
   a contract break. Build: tests/324's d324 with `regrain(.., '1 month')` from a '3 months' grid.
2. **The regrain swap does not check that its fine children cover the source's literal range.** F2-01's row
   loss happens because nothing compares the copies' rendered bounds (as the column reads them) with the
   source's: any other way to render a fine bound off the column's clock (a hand-edited anchor on a
   `timestamp(0)` key that `_time_unit_breach` misses, a future rule gap) would drop rows silently instead
   of failing. Mechanism: regrain_step's swap ATTACHes children whose catalog bounds are `_time_literal` of
   pgpm's native bounds, drops the source, and never asks whether the union of the children's catalog ranges
   equals the source's.
3. **A grid recorded under a legacy zone link breaks after a tzdata split.** `_canonical_tz` stores the
   name as pg_timezone_names spells it, never the link's target; on a host with `tzdata-legacy` a session
   in `Asia/Calcutta` or `US/Eastern` records that name, and after an OS upgrade without the legacy package
   every `at time zone` on it raises (seen here: `America/Godthab` is "not recognized"), so every tick's
   grid arithmetic fails until the package is restored or `set_partition_tz` is run (which does work).
4. **`warn_grid_off_unit` is deduplicated by the full message, which embeds `parent_table::text`.** A re-run
   of install.sql under another `search_path` renders the table name differently and logs a second row,
   against "Logged once per grid". Cosmetic; not built.

## Round 2

- Hypothesis 1 (older-install state, shape 5: a monthly `date` grid anchored at noon): **built as F2-03
  (Tier 4, contracts versus documentation).** After the anchor is planted (tests/324's d324 fixture),
  extend_to mints six partitions whose pgpm.part bounds equal the catalog's (midnight UTC, the same dates),
  yet the re-run install logs `warn_grid_off_unit` saying every partition obtain mints is attached at other
  bounds than pgpm.part records and sends the operator to a reconversion. The over-refusal of a whole-month
  regrain target on such a grid is named in the scenario but not separately asserted.
- Hypothesis 2 (the swap never checks that the fine children's catalog bounds cover the source): tried, not
  reproduced without the zone. Every other route I could find that renders a fine bound off the column's
  reading is now refused before the copy: a date or `timestamp(p)` key's registered anchor and step
  (`_time_unit_breach` of the registered grid), an encoded key's unit, and a mixed-month registered step
  (`_grid_floor` raises, so the run fails without loss). For a `numeric(p, 0)` id key with an anchor planted
  at 0.5, the copy predicate (`ctl >= '10.5'`) and ATTACH's rounding (to 11) select the same integer rows, so
  nothing is lost. The only path to the loss I found is F2-01's. The missing coverage check stays a
  defence-in-depth hypothesis that F2-01 demonstrates.
- Hypothesis 3 (a legacy zone link recorded, then removed by a tzdata split): not attempted. It needs the
  host's tzdata to change under a live grid, and round 1 showed that the supported remedy (`set_partition_tz`)
  works on such a grid.
- Hypothesis 4 (`warn_grid_off_unit` logged again under another `search_path`): not attempted. It is cosmetic,
  and building it would cost more than it is worth.
