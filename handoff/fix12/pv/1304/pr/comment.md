## Per-PR adversarial verification of `d18620c` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: regression with no verdict yet (unverified is not clear)
- closing claim: partial (What I tried: (1) Call sites. archive._object_stem is reached only through archive._object_key, whose only callers are the two encoders the diff changes. archive.to_s3/to_s3_parquet key by child oid, not bounds. pgpm_hypertable and pgpm_core/uninstall.sql derive no key from bounds. _refuse_empty_ran); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #814 acceptance (F19-03): In one direct strategy call the range read, the empty-range check and the recorded-chunk check parse p_lo under the session's DateStyle while archive._object_stem parses it under its pinned 'ISO, MDY', so from a 'SQL, DMY' session '02/01/2024 00:00:00+00' archives the 2 January rows under the 1 February chunk's key; the object should be keyed by the instant the call read (or the spelling refused). | yes | yes | `archive_ndjson_bounds_caller_spelling`: yes; `archive_parquet_bounds_caller_spelling`: NO |  |

### Closing claim

**partial**: What I tried: (1) Call sites. archive._object_stem is reached only through archive._object_key, whose only callers are the two encoders the diff changes. archive.to_s3/to_s3_parquet key by child oid, not bounds. pgpm_hypertable and pgpm_core/uninstall.sql derive no key from bounds. _refuse_empty_range parses the raw text in the same session _native_text does. (2) Tick, resume and upgrade paths. A tick hands canonical text, so it is unchanged. An id chunk recorded under a trailing-zero key (_100.0) is re-keyed _100 on the head, which cannot overwrite the recorded object, so there is no loss on upgrade. (3) Mutations. Each removes only its encoder's p_lo reading. The parquet mutant alone passes ACC-01 only because ACC-01 is NDJSON; test 54 part B covers parquet. Both mutations are sound. (4) The body's guarantee that 'from any DateStyle or TimeZone, the object key's stem is the stem of the instant the call's range read began at', and the new reference.md text that 'the range it reads, the recorded-chunk check and the key all take that one reading', BREAK on a date-column grid (V-01, run live in pgpm_prv-archive). The grid has partition_tz UTC with cells at 00:00Z. From an America/New_York session, archive_to_s3_ndjson('v1.d', null, '2024-01-02', '2024-01-03') reads the whole 2 January cell (2 rows), because the date column truncates the '2024-01-02 05:00:00+00' literal. The head keys that cell ..._2024010205000000, but the same call from UTC keys it ..._2024010200000000. So one chunk with the same rows gets two keys depending on the session zone, and the 05:00Z key starts no cell. That is #814's consequence (the key names an instant other than the chunk the object holds, and it varies by session). The recorded-chunk check looks up the session-shaped key, so it never meets a ledger row at the cell's real key. The base keyed both calls 2024010200000000: V-01 passes on the base and fails 3 defect checks on the head, with every LIVENESS holding. It is a regression in the code the PR covers, Tier 3 (a documented contract not kept, no overwrite: no cell starts at the stray key). _encode_upload_parquet takes the same path. Naive-timestamp and timestamptz grids keep the guarantee; only the date column's truncation splits the read from the key.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | archive._encode_upload_ndjson_single canonicalises only p_hi (line 3073; no `p_lo := pgpm._native_text(...)` beside it, unlike archive._encode_upload_parquet at 3165-3166), so the NDJSON strategy still hands archive._object_key the caller's spelling of lo: from a 'SQL, DMY' session '02/01/2024 00:00:00+00' reads and archives the 2 January rows (ids 1, 2) and PUTs them at the 1 February chunk's key (returned s3_key ..._2024020100000000.ndjson, nothing at the 2 January key), an offset-less bound from America/New_York is read from 05:00Z and keyed from 00:00Z, and on an id grid '0100' is keyed _0100 rather than the _100 a tick keys; the PR body, CHANGELOG and docs/reference.md all say both encoders read p_lo once and key the instant the call read, and tests/archive/db/54 parts A, C and D (and bench/archive_direct_call_bounds.sh) fail against this tree |
| `V-01` | 3 | regression | unverified | On a date-column day grid (partition_tz UTC), a direct pgpm.archive_to_s3_ndjson/_parquet call from a non-UTC session with offset-less bounds now keys the chunk by pgpm._native_text's session reading ('2024-01-02' from New York -> 05:00Z, stem 2024010205000000) while the date column's read truncates the bound to the whole 2 January chunk: the same chunk and rows get ..._2024010205000000 from New York and ..._2024010200000000 from UTC, a key no chunk starts at, and the recorded-chunk check looks up the session-shaped key so it never meets the ledger row at the chunk's real key. The base keyed both calls 2024010200000000. The key should name the chunk the read covers (the lo as the column reads it), not the session's instant. |

<details><summary><code>V-01</code> regression: tails</summary>

base:
```
                                              is                                               
-----------------------------------------------------------------------------------------------
 ok 7 - the same chunk, the same rows, gets the same key from a New York session and a UTC one
(1 row)
 finish 
--------
(0 rows)
psql:<stdin>:10: NOTICE:  extension "pgtap" already exists, skipping
```
head:
```
 #         have: v1-rv_v_01_h/v1.d_2024010205000000.ndjson                                                +
 #         want: v1-rv_v_01_h/v1.d_2024010200000000.ndjson
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 3 tests of 7
(1 row)
psql:<stdin>:10: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

### Seed witness

- S1 in `pgpm_archive/install.sql` (archive_ndjson_bounds_caller_spelling): **found**

### Coverage and budget

- P1: 10 of 10 units read (1.00)
- surface: 6 file(s), 10 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~100k tokens (10/10 units), claims verifier ~108k (live on the archive harness); acceptance F19-03; seed caught; BLOCKED on the closing claim: partial, with V-01 a regression (a date-column grid driven from America/New_York keys the chunk by the session's offset, a key no cell starts at, while UTC keys the cell's start; the base keyed both by the cell's real start); fixer round 2 in progress

🤖 Generated with [Claude Code](https://claude.com/claude-code)
