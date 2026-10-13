# P1 null results: PR #1304 round 2

## Fresh surface

- `archive._bound_native`: read whole. `set timezone = 'UTC'` on the function plus `set_config(..., true)` inside it:
  the function-level SET clause restores the session's zone on return (by the SET-clause semantics; not separately
  executed: test 54 parts C, E and F rely on it and P1-01 part B's later statements saw the session zone unchanged).
  Null `p_tz` falls to UTC. The id kind bypasses the zone switch and goes through `trim_scale` (`'0100'` -> `100`).
- `archive._encode_upload_parquet`: both bounds read through `_bound_native` before `pgpm._encode`, the recorded-chunk
  check and `_object_key`; from 'SQL, DMY' the Parquet key is the 2 January stem (P1-01's GUARD 6 shows it). Held.
- `archive._encode_upload_ndjson_single`: only `p_hi` is read (line 3090). NOT held: P1-01.
- `pgpm.archive_to_s3_ndjson` / `_parquet`: `covered_hi` is still the caller's raw `p_hi` (as the body says; core
  canonicalises it, #977). `_refuse_null_arguments` and `_refuse_filtered_reads` run before the encoder, unchanged.
- `archive._object_stem` unchanged; its pinned parse of canonical ISO text with offset is the same instant.
- `tests/archive/db/54`: plan(44) matches the assertion count (A 9, B 6, C 9, D 5, E 9, F 6). Every part clears and
  witnesses its candidate keys absent first; asymmetric fixtures; identity checks on NDJSON objects. On this tree
  parts A, C, D and E would fail (the NDJSON lo is unread), so the test discriminates the state the tree is in.
  Part F's Parquet half asserts only the key and 404, not the file's rows (Parquet is not read back here); noted,
  not claimed, since `tests/archive/db/08` reads Parquet back and the key here is exact.
- `bench/archive_direct_call_bounds.sh`: creates the bucket idempotently, counts assertions ran, names failed
  LIVENESS lines, drops its database. `set -uo pipefail` without `-e` is deliberate (each step reports). Held.
- `test.sh` hunk: wired after the #1173 guard with its own database name `pgpm_perf396`; no collision with the
  other names in the archive track (grep'd). Held.
- `CHANGELOG.md` / `docs/reference.md` hunks: describe both encoders reading both bounds; true of Parquet, not of
  NDJSON on this tree (covered by P1-01, not filed separately as Tier 4).

## Time and zones

- Session east of the grid (Asia/Tokyo) on a date grid: with the lo read (Parquet) the key is the cell's start;
  with it unread (NDJSON) the object holds the previous day's row: P1-01 part B.
- Session west (America/New_York) on a timestamptz UTC grid, offset-less bounds: Parquet keys 00:00Z and reads
  ids of the grid's day; NDJSON mirrors test 54 part C's failure (lo unread). Covered by P1-01's mechanism.
- Bound with an explicit offset ('2024-01-02 00:00:00+09') from a UTC session: `_bound_native` renders the same
  instant in partition_tz (`2024-01-01 15:00:00+00`), stem 2024010115000000, both encoders agree. Held.
- `_refuse_empty_range` versus `_bound_native` on a DST gap in partition_tz: NOT held, P1-02 (Parquet). The NDJSON
  strategy in the same call reads [02:30Z (raw lo, session), 07:00Z (hi, grid)), a 4.5-hour range on a 30-minute
  grid, keyed 2024031002300000: the same P1-01 mechanism, not a separate claim.
- The fall-back fold (01:30 ambiguous): PostgreSQL resolves both bounds consistently (standard time), so the
  ordering agrees between the session and the grid; no inversion. Held.
- Ledger row and object agreeing: a tick's `_archive_step` passes canonical text, so `_bound_native` is an
  identity on it and the ledger's lo/hi, the key and the object agree. A direct call writes no ledger row.

## Hypotheses (no reproduction)

- `_refuse_recorded_chunk_overwrite` compares the ledger's canonical lo with the encoder's p_lo through
  `pgpm._native_gt` in the caller's session; with a canonical p_lo (Parquet) every DateStyle/zone parses both the
  same way. With the raw NDJSON lo it is session-parsed, which agrees with the raw read; no third reading found.
- An offset-less bound on a text_time or uuidv7 grid takes the same `_bound_native` path as `time`; not exercised.
