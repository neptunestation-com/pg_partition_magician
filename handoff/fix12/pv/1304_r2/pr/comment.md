## Per-PR adversarial verification of `341b9c8` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- ACC-02: the acceptance reproduction does not fail on the base, so it does not demonstrate the defect the PR says it fixes
- P1-02: pre_existing with no verdict yet (unverified is not clear)
- V-01: regression with no verdict yet (unverified is not clear)
- V-02: pre_existing with no verdict yet (unverified is not clear)
- closing claim: partial (What held, run live in pgpm_prv-archive against the head: a timestamptz grid with partition_tz Asia/Kolkata, driven from UTC and from America/New_York with offset-less bounds, with the cell start given with an explicit offset, from SQL,DMY and from Postgres,DMY, ndjson and parquet: every call keyed ); standing on V-01, V-02

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #814 acceptance (F19-03): In one direct strategy call the range read, the empty-range check and the recorded-chunk check parse p_lo under the session's DateStyle while archive._object_stem parses it under its pinned 'ISO, MDY', so from a 'SQL, DMY' session '02/01/2024 00:00:00+00' archives the 2 January rows under the 1 February chunk's key; the object should be keyed by the instant the call read (or the spelling refused). | yes | yes | `archive_ndjson_bounds_caller_spelling`: yes; `archive_ndjson_bounds_session_zone`: NO; `archive_parquet_bounds_caller_spelling`: NO; `archive_parquet_bounds_session_zone`: NO |  |
| `ACC-02` #814 acceptance (V-01-1304): On a date-column day grid (partition_tz UTC), a direct pgpm.archive_to_s3_ndjson/_parquet call from a non-UTC session with offset-less bounds now keys the chunk by pgpm._native_text's session reading ('2024-01-02' from New York -> 05:00Z, stem 2024010205000000) while the date column's read truncates the bound to the whole 2 January chunk: the same chunk and rows get ..._2024010205000000 from New York and ..._2024010200000000 from UTC, a key no chunk starts at, and the recorded-chunk check looks up the session-shaped key so it never meets the ledger row at the chunk's real key. The base keyed both calls 2024010200000000. The key should name the chunk the read covers (the lo as the column reads it), not the session's instant. | NO | yes | `archive_ndjson_bounds_caller_spelling`: NO; `archive_ndjson_bounds_session_zone`: yes; `archive_parquet_bounds_caller_spelling`: NO; `archive_parquet_bounds_session_zone`: NO |  |

### Closing claim

**partial**: What held, run live in pgpm_prv-archive against the head: a timestamptz grid with partition_tz Asia/Kolkata, driven from UTC and from America/New_York with offset-less bounds, with the cell start given with an explicit offset, from SQL,DMY and from Postgres,DMY, ndjson and parquet: every call keyed k.ev_2024010118300000 (the cell's start) and read the same 2 rows. The scheduled path: a 1-second Kolkata grid ticked by pgpm.maintain from a New York, SQL,DMY session wrote 6 ledger rows; for each one the key's stem equals _object_stem of the ledger lo, and the object's rows match the live rows of [lo, hi). A date grid driven from Asia/Tokyo with '2024-01-02' and with '02/01/2024' under SQL,DMY was keyed 2024010200000000 and held both 2 January rows (the base keyed Jan 2 and held the Jan 1 row there). ACC-02 (round 1's V-01) is accepted on its three-tree evidence: it passes on the base, where the regression did not exist; it passes on the head; and it fails on the archive_ndjson_bounds_session_zone mutant. It is a regression guard, not a 'fails on base' acceptance. Other entry points: only the two encoders call archive._object_key, and archive.to_s3 keys by child oid, so it is out of scope. What did not hold. (1) V-01, a regression, Tier 3. The encoders now read the bounds on the grid's clock, but archive._refuse_empty_range (#969) still compares the raw text in the caller's session. So the body's sentence 'archive._refuse_empty_range ... reads the same instant pgpm._native_text does' is no longer true on this head, because the read uses partition_tz and not the session zone. The case: a Kolkata grid, a UTC caller, lo '2024-01-02 18:30:00+00' (the cell's start, with its offset) and hi '2024-01-03' (offset-less). The session reads this range as non-empty. On the grid's clock hi equals lo, so the range is empty. The call is admitted, reads 0 rows, and PUTs an empty object (HTTP 200, no content) at the cell's own key instead of refusing. The base read the session's non-empty range (1 row). The recorded-chunk check still refuses this at a recorded key, so nothing is lost: Tier 3 (acts when it should refuse). (2) V-02, pre-existing in the PR's surface, Tier 3, the issue's own consequence. On a date grid the key is the stem of the lo instant, but the read truncates that instant to its day. A Tokyo caller's '2024-01-02 00:00:00+09' (15:00Z on 1 January) reads the whole 1 January cell and keys it d.ev_2024010115000000, a key no cell starts at, while a tick keys it 2024010100000000. That breaks the body's guarantee 'the stem of the instant the call's range read began at' from any TimeZone. The same holds for any offset-less non-midnight lo, from any zone. No open issue names either mechanism: #1030 covers other archive paths and the #969 advice text, and #769 covers a date grid's non-midnight anchor, not a direct call's bound. The new mutations and ACC-02 discriminate as reported.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | archive._encode_upload_ndjson_single reads only p_hi through archive._bound_native and never p_lo, so the NDJSON strategy still keys its object by the caller's spelling of lo and reads the range from the session's parse of it: from a 'SQL, DMY' session '02/01/2024 00:00:00+00' archives the 2 January rows at the 1 February chunk's key (the F19-03 shape the PR says both encoders fix), and on a date grid from Asia/Tokyo '2024-01-02' is read as 2024-01-01 15:00Z, truncated to 1 January by the date column, so the object keyed 2 January holds 1 January's row too; the lo should be read once on the grid's clock as the Parquet encoder's is (3181) |
| `P1-02` | 3 | pre_existing | unverified | archive._bound_native reads an offset-less bound in the grid's partition_tz while archive._refuse_empty_range (#969) still reads it in the caller's TimeZone, so the two order a range differently across a DST gap in partition_tz: from a UTC session on an America/New_York 30-minute grid, '2024-03-10 02:30:00'..'03:00:00' passes the refusal (02:30Z < 03:00Z) but the Parquet encoder reads it as [07:30Z, 07:00Z), inverted, finds no row and PUTs an empty object at the live cell [07:30Z, 08:00Z)'s key; the PR body's claim that the refusal reads the same instant the encoder reads is not kept, and the call should be refused (or the refusal should compare the canonical bounds the encoder reads) |
| `V-01` | 3 | regression | unverified | The head reads a direct call's bounds on the grid's clock (archive._bound_native, offset-less text in partition_tz) for the read, the recorded-chunk check and the key, but archive._refuse_empty_range (#969) still compares the raw text in the caller's session. On a timestamptz grid with partition_tz Asia/Kolkata, a UTC caller's [lo '2024-01-02 18:30:00+00', hi '2024-01-03') is non-empty to the session and empty on the grid's clock (hi = 2024-01-03 00:00 IST = lo), so the call is admitted, reads no row, and PUTs an empty object at the 2 January cell's own key instead of refusing. The base read the range in the session too, so it archived the session's non-empty range: a regression of #969's refusal. The empty-range check should read the same canonical bounds the encoders read. |
| `V-02` | 3 | pre_existing | unverified | On a date-column day grid (partition_tz UTC), a direct pgpm.archive_to_s3_ndjson call keys the object by the instant its lo names, while the read compares the date column, which truncates that instant to its day. A Tokyo caller's lo '2024-01-02 00:00:00+09' (2024-01-01 15:00Z) reads the whole 1 January cell and PUTs it at d.ev_2024010115000000, a key no cell starts at, while a tick keys the same chunk d.ev_2024010100000000: one chunk, two objects, and the recorded-chunk check (looked up by key) never meets the ledger row at the cell's key. The PR body's guarantee 'the object key's stem is the stem of the instant the call's range read began at' from any TimeZone does not hold on a date grid for a bound with an explicit offset (or any offset-less bound that is not a midnight). The key should name the cell the read covers (the lo as the column reads it), or the bound be refused. |

<details><summary><code>P1-02</code> pre_existing: tails</summary>

base:
```
------------------------------------------------------------------------------------------------------------------------
 ok 3 - LIVENESS: the session (UTC) reads [02:30, 03:00) as a non-empty range, so archive._refuse_empty_range admits it
(1 row)
psql:<stdin>:12: NOTICE:  extension "pgtap" already exists, skipping
psql:<stdin>:42: ERROR:  function archive._bound_native(unknown, unknown, unknown) does not exist
LINE 1: select is(archive._bound_native('time', '2024-03-10 02:30:00...
                  ^
HINT:  No function matches the given name and argument types. You might need to add explicit type casts.
```
head:
```
--------
    204
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 9
(1 row)
psql:<stdin>:12: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

<details><summary><code>V-01</code> regression: tails</summary>

base:
```
                                        ok                                        
----------------------------------------------------------------------------------
 ok 6 - no empty object lands at the 2 January cell's key (k.ev_2024010218300000)
(1 row)
 finish 
--------
(0 rows)
psql:<stdin>:9: NOTICE:  extension "pgtap" already exists, skipping
```
head:
```
 not ok 6 - no empty object lands at the 2 January cell's key (k.ev_2024010218300000)        +
 # Failed test 6: "no empty object lands at the 2 January cell's key (k.ev_2024010218300000)"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
psql:<stdin>:9: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

<details><summary><code>V-02</code> pre_existing: tails</summary>

base:
```
 # Failed test 6: "the object at the 1 January cell's key holds exactly the row jan1"
(1 row)
RESET
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 6
(1 row)
psql:<stdin>:8: NOTICE:  extension "pgtap" already exists, skipping
```
head:
```
 # Failed test 6: "the object at the 1 January cell's key holds exactly the row jan1"
(1 row)
RESET
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 6
(1 row)
psql:<stdin>:8: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

### Seed witness

- S1 in `pgpm_archive/install.sql` (archive_ndjson_bounds_caller_spelling): **found**

### Coverage and budget

- P1: 11 of 11 units read (1.00)
- surface: 6 file(s), 11 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~113k tokens (11/11 units), claims verifier ~90k (live on the archive harness: a Kolkata grid from UTC and New York, explicit offsets, SQL,DMY and Postgres,DMY, the scheduled tick, a date grid from Tokyo); acceptance: F19-03 and round 1's V-01 (a regression, so it passes on the base by definition; passes on the head, fails against archive_ndjson_bounds_session_zone); seed caught; BLOCKED on the closing claim: partial, with V-01 and P1-02 (a regression: _refuse_empty_range still reads the bounds in the session zone while the encoders read on the grid's clock, so an empty-on-grid range is not refused and an empty object is PUT at the live cell's key) and V-02 (a date grid with an explicit-offset bound keyed off the cell); the fixer's round 3 reads the bounds once under the grid's clock for every check and the key (last round)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
