Addresses #814 (the archive bullet: a direct strategy call's range read, empty-range check and recorded-chunk check parse p_lo under the session DateStyle while _object_stem parses it under its pinned one). The issue's other bullets (`_crossing_keys`, `archive_coverage_reset`'s log rendering, `row_to_json`'s `bytea_output`/`IntervalStyle`, `_log_unbuilt_cell`) are untouched.

## The defect

Within one direct call of `pgpm.archive_to_s3_ndjson` or `pgpm.archive_to_s3_parquet`, the bounds text was parsed several times. The range read (`pgpm._encode`), the empty-range check (`archive._refuse_empty_range`) and the recorded-chunk check (`archive._refuse_recorded_chunk_overwrite`) parsed it in the caller's session, but `archive._object_stem`, which names the object, parsed it under its own pinned `TimeZone 'UTC'` / `DateStyle 'ISO, MDY'`. A tick hands canonical ISO text with an offset, which every one of those parses reads the same way. A direct call does not have to. From a `SQL, DMY` session, `'02/01/2024 00:00:00+00'` read the 2 January rows and PUT them at the 1 February chunk's key (F19-03). In the same way, an offset-less bound from a New York session was read from 05:00Z and keyed from 00:00Z (the zone half of the bullet).

## The fix

Both encoders, `archive._encode_upload_ndjson_single` and `archive._encode_upload_parquet` (the only callers of `archive._object_key`, so the only places a chunk key is derived from a bound), now read `p_lo` and `p_hi` once, at the top. They read them as `pgpm._native_text` renders what the calling session reads them as, the same reading core gives an archive_fn's `covered_hi` (#977). From there on the range read, the recorded-chunk check and the object key all take that canonical text. `archive._object_stem` is unchanged; its pinned parse of canonical text names the same instant the session read.

What it guarantees: for both strategies, from any `DateStyle` or `TimeZone`, the object key's stem is the stem of the instant the call's range read began at, and the recorded-chunk check compares that same instant. `archive._refuse_empty_range` still parses the raw text in the caller's session, so it reads the same instant `pgpm._native_text` does. The semantics are the caller's session reading, as with any timestamp literal. A tick's canonical text is unchanged by the reading.

One consequence beyond the time kinds: an `id` bound is read the same way, at its least scale, so `'0100'` is keyed `_100`, as a tick keys that chunk (it used to be keyed `_0100`). Distinct numbers keep distinct stems, so #502's uniqueness holds. A tick's id lo is already least-scale except where `pgpm.part` stored one with trailing zeros, and that chunk's key now drops them. Keys already recorded in `pgpm.archive_ledger` stay as written.

`covered_hi` is still returned as the caller passed `p_hi`: core canonicalizes it itself (#977). This PR does not touch `archive.to_s3`, which does not read its bounds.

## Acceptance

- Reproduction: F19-03's `repro.sql` (claim dir F19/F19-03). It fails 5, 6 and 7 on the base with liveness 1 to 4 holding, passes all 7 on this head, and fails 5, 6 and 7 again against the ndjson mutant.
- Test: `tests/archive/db/54_archive_direct_call_bounds_session_test.sql`, 28 assertions. Part A is NDJSON from `SQL, DMY`, part B is Parquet from `SQL, DMY`, part C is offset-less bounds from `America/New_York`, and part D is an id grid with `'0100'`. Each part asserts the exact key, the object's rows by identity (asymmetric fixtures: the session's range holds 2 or 3 rows, the other reading's range other rows), and 404 at the other reading's key. Each is paired with LIVENESS witnesses that the session's reading and the default reading of the text differ.
- Guard: `bench/archive_direct_call_bounds.sh` (archive track, `pgpm_perf396`).
- Mutations: `archive_ndjson_bounds_caller_spelling` (caught by parts A, C and D: 9 defect checks) and `archive_parquet_bounds_caller_spelling` (caught by part B: 3 defect checks). Each removes only the lo's reading in one encoder. No LIVENESS line fails against either.

## Local proof

- `./test.sh archive` (gated): PASS. `./test.sh 15 --channel=psql` (gated): PASS.
- Every mutation in `bench/mutations/` builds.
- `check_quoted_splices.py`, `check_archive_object_keys.py`, `check_archive_child_by_oid.py`, `check_living_docs.sh`, `check_track_filters.py`: PASS.
- `shellcheck` 0.11.0 is clean on the new guard, and `bash -n test.sh` passes.
- markdownlint-cli2@0.13.0 is clean on `CHANGELOG.md` and `docs/reference.md`.
- Caveat: the test leans on DateStyle/TimeZone, but there is no PG 18 archive image (the archive track runs on 17 only), so it ran on 17 alone.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

