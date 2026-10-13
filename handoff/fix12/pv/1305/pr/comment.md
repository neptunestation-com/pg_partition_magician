## Per-PR adversarial verification of `c757390` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: pre_existing with no verdict yet (unverified is not clear)
- closing claim: partial ((1) Call sites: every consumer of the retired-range hold (retain() at install.sql:4194, _archive_step at 5345, scripts/archive_partition_whole.sql:122) goes through pgpm._over_retired_chunks; pgpm_archive and pgpm_hypertable have no sibling copy; uninstall drops the schema cascade, so the new helper); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1264 acceptance (F15-02): _over_retired_chunks casts an offset-less retired ledger bound (an older install's row) with ::timestamptz in the caller's TimeZone, so a partition held over a retired chunk from a UTC session (pg_cron's maintain) is not held from an Asia/Kolkata session (a hand _archive_step or retain()), which then archives it over the retired range; it should read such a bound in the grid's registered partition_tz and give every session the same answer, as its header promises | yes | yes | `native_bound_key_session_datestyle`: NO; `native_bound_key_utc`: NO; `over_retired_chunks_session_zone`: yes |  |

### Closing claim

**partial**: (1) Call sites: every consumer of the retired-range hold (retain() at install.sql:4194, _archive_step at 5345, scripts/archive_partition_whole.sql:122) goes through pgpm._over_retired_chunks; pgpm_archive and pgpm_hypertable have no sibling copy; uninstall drops the schema cascade, so the new helper needs nothing. The floor prefilter keeps every unkeyed row as a candidate, so it never decides an overlap. _archive_fully_covered's caller-session cast is disclosed in the body as out of scope. (2) Resume/upgrade/scheduled: no separate path; partition_tz is NOT NULL (backfilled 'UTC'), so set_config never sees a null. (3) The body's promise fails on one input: _native_bound_key pins TimeZone and DateStyle but not timezone_abbreviations, and a pre-#500 DateStyle-shaped render (the class the body says it covers) carries a zone ABBREVIATION. V-01: a UTC grid, a retired chunk whose hi an Asia/Jerusalem writer rendered under 'SQL, MDY' ('... IST', +02 in January), an hour into p0. From the default session p0 is held; from an operator session with timezone_abbreviations = 'India' (IST = +05:30) the same hi reads 2.5 h before p0's lo and p0 is not held, so it is archived over the retired range, the #1264 consequence, Tier 3. Run live on pgpm_prv-15: 5/6 with every LIVENESS passing, the final check failing, on BOTH head and base (pre_existing, inside the PR's surface, Tier 3 so not blocking by the brief's rule). (4) Mutations: each alone fails tests/334 on non-premise checks (live: utc fails 3,5,7,9,11; session_datestyle fails 7,11; session_zone fails 5,7,9,11,16). Only over_retired_chunks_session_zone puts back the issue's own defect (session-TimeZone read; it alone fails ACC-01); native_bound_key_utc is a wrong-fix variant (the same answer from every session, the wrong instant) and native_bound_key_session_datestyle is the DateStyle sibling, so neither alone restores #1264's TimeZone mechanism, which is consistent with what the body says they guard. (5) No documented workflow is refused: the reference.md and CHANGELOG changes describe a read rule only.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | _over_retired_chunks passes current_setting('TimeZone'), the caller's zone, as p_tz to pgpm._native_bound_key instead of config.partition_tz, so an offset-less retired bound is still read on the session's clock and the held set differs by session (held from UTC, not from Pacific/Kiritimati, over a Asia/Tokyo grid); the body, CHANGELOG, reference.md and tests/334 promise the grid's clock and the same answer from every session, and tests/334 itself fails 5/16 on this tree |
| `V-01` | 3 | pre_existing | unverified | PR #1305's pgpm._native_bound_key pins TimeZone (to partition_tz) and DateStyle (ISO, MDY) but not timezone_abbreviations, so a legacy retired ledger bound that names its zone by abbreviation (a pre-#500 render under DateStyle SQL or Postgres, e.g. '01/01/2026 01:00:00 IST' from an Asia/Jerusalem writer, or a pre-#977 covered_hi kept verbatim) still reads as a different instant per session: IST is +02 under the Default set and +05:30 under the India set. The same _over_retired_chunks call holds the partition from pg_cron's default session and not from an operator session with timezone_abbreviations = 'India', which then archives it over the retired range (the #1264 consequence), against the helper's 'read the same from every session' and tests/317's same-answer contract. The PR's body claims to cover DateStyle-shaped pre-#500 bounds, and those are exactly the renders that carry abbreviations. |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 #         want: t_p2026_01_to_2026_11
(1 row)
RESET
SET
               finish                
-------------------------------------
 # Looks like you failed 1 test of 6
(1 row)
```
head:
```
 #         want: t_p2026_01_to_2026_11
(1 row)
RESET
SET
               finish                
-------------------------------------
 # Looks like you failed 1 test of 6
(1 row)
```

</details>

### Seed witness

- S1 in `pgpm_core/install.sql` (over_retired_chunks_session_zone): **found**

### Coverage and budget

- P1: 10 of 10 units read (1.00)
- surface: 6 file(s), 10 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~70k tokens (10/10 units), claims verifier ~63k (live); acceptance F15-02 (the verifier's rebuilt reproduction); seed caught; BLOCKED on the closing claim: partial, V-01 (the read rule pins TimeZone and DateStyle but not timezone_abbreviations, so an abbreviation-bearing legacy bound reads differently under the India set), fixer round 2 in progress

🤖 Generated with [Claude Code](https://claude.com/claude-code)
