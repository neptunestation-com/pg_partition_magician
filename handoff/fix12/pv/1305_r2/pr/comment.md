## Per-PR adversarial verification of `e79fa9c` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1264 acceptance (F15-02): _over_retired_chunks casts an offset-less retired ledger bound (an older install's row) with ::timestamptz in the caller's TimeZone, so a partition held over a retired chunk from a UTC session (pg_cron's maintain) is not held from an Asia/Kolkata session (a hand _archive_step or retain()), which then archives it over the retired range; it should read such a bound in the grid's registered partition_tz and give every session the same answer, as its header promises | yes | yes | `native_bound_key_session_abbreviations`: NO; `native_bound_key_session_datestyle`: NO; `native_bound_key_utc`: NO; `over_retired_chunks_session_zone`: yes |  |
| `ACC-02` #1264 acceptance (V-01-1305): PR #1305's pgpm._native_bound_key pins TimeZone (to partition_tz) and DateStyle (ISO, MDY) but not timezone_abbreviations, so a legacy retired ledger bound that names its zone by abbreviation (a pre-#500 render under DateStyle SQL or Postgres, e.g. '01/01/2026 01:00:00 IST' from an Asia/Jerusalem writer, or a pre-#977 covered_hi kept verbatim) still reads as a different instant per session: IST is +02 under the Default set and +05:30 under the India set. The same _over_retired_chunks call holds the partition from pg_cron's default session and not from an operator session with timezone_abbreviations = 'India', which then archives it over the retired range (the #1264 consequence), against the helper's 'read the same from every session' and tests/317's same-answer contract. The PR's body claims to cover DateStyle-shaped pre-#500 bounds, and those are exactly the renders that carry abbreviations. | yes | yes | `native_bound_key_session_abbreviations`: yes; `native_bound_key_session_datestyle`: NO; `native_bound_key_utc`: NO; `over_retired_chunks_session_zone`: NO |  |

### Closing claim

**holds**: Tried to reach #1264's consequence (the same _over_retired_chunks call holding different partitions from different sessions) and failed. (1) Call sites: _over_retired_chunks is the only reader of retired ledger bounds; its callers are _archive_step (install.sql:5351), retain() (4194) and scripts/archive_partition_whole.sql, all through it; no copy in pgpm_archive/pgpm_hypertable; uninstall drops the schema. The floor via _native_order_key keys only ISO text with a numeric offset (session-invariant) and leaves every other row a candidate. (2) Live on pgpm_prv-15: pgpm._native_bound_key over 14 legacy shapes (SQL/German/Postgres-style renders ending in IST, EST, CST, SAST, BST; offset-less ISO; DMY-shaped; numeric offset; full zone name Asia/Kolkata; T...Z; Julian; 9-digit fractions) from 675 sessions (5 TimeZones x 5 DateStyles x Default/Australia/India x 3 IntervalStyles x extra_float_digits -15/0/3) gave exactly one key per text; _over_retired_chunks over a UTC grid with IST/EST/CST/DMY/zone-name hi chunks gave 1 distinct answer over 180 sessions on head, 2 on base. (3) Settings: the caller's TimeZone, DateStyle and timezone_abbreviations are restored after the call whether set by SET, SET LOCAL in an open transaction, or set_config(...,true) in a DO block, and after an error the function raised and the caller caught. (4) Mutations each put back a part of this defect (session zone, UTC read, DateStyle pin, abbreviation pin); the ACC repro fails only on the session-zone mutant, as expected for a UTC grid. Residue, not claims: an abbreviation absent from Default (WST, SAT, Australia-set only; not produced by tzdata since 2014) now raises from every session, where on base it parsed only in Australia-set sessions and raised in pg_cron's Default one; Default reads a Kolkata or Dublin-written 'IST' as Israel's, deterministically, the documented choice; on PG 18, input prefers the abbreviations of the pinned TimeZone (partition_tz), so on a grid registered in an IST zone 'IST' would not be Israel's as reference.md says, but it would still be the same from every session (not testable here, PG 15 only); set_partition_tz moves where an offset-less legacy bound falls, which is an operator's state change, not session dependence.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | _over_retired_chunks reads current_setting('TimeZone') into v_tz and hands the CALLER's zone to _native_bound_key as p_tz, not config.partition_tz, so an offset-less retired bound is still wall time in the session's zone: over an Asia/Tokyo grid a UTC session (pg_cron's) holds p0 over a chunk that ends below p0 on the grid's clock, and a Pacific/Kiritimati session holds nothing over the chunk that reaches into p0; it should read the bound on the grid's clock and answer the same from every session, as the PR body, the CHANGELOG, docs/reference.md and the function's own header promise (the PR's own tests/334 fails 5 of 22 on this head: parts B to E and G) |

### Seed witness

- S1 in `pgpm_core/install.sql` (over_retired_chunks_session_zone): **found**

### Coverage and budget

- P1: 10 of 10 units read (1.00)
- surface: 6 file(s), 10 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~114k tokens (10/10 units), claims verifier ~69k (14 legacy bound shapes across 675 session configurations: one key each; the caller's three settings restored after SET, SET LOCAL, set_config and a caught error); acceptance: F15-02 rebuilt and round 1's V-01, each restored only by its own mutation; seed caught; round 1's timezone_abbreviations gap is closed

🤖 Generated with [Claude Code](https://claude.com/claude-code)
