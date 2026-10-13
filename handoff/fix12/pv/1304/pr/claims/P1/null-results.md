# P1 null results: PR #1304 (key a direct strategy call by the bounds it read)

Harness: pgpm_prv-archive (PG 17.11, MinIO). Databases prv_p1_1304_a and prv_p1_1304_b, created and dropped.

## Lens: fresh surface

- `archive._encode_upload_parquet` (3164-3166): reads both bounds through `pgpm._native_text` before
  `pgpm._encode`, `archive._object_key` and `archive._refuse_recorded_chunk_overwrite`. Probed from a
  `SQL, DMY` session with `'02/01/2024 00:00:00+00'`: s3_key `..._2024010200000000.parquet`, the 2 January
  key. Held.
- `archive._encode_upload_ndjson_single` (3062-3074): canonicalises `p_hi` only. NOT held: claim P1-01.
  The range read (`pgpm._encode(p_lo raw)` with `p_hi` canonical) still selects the session's instants, and
  `_refuse_recorded_chunk_overwrite` compares through `pgpm._native_gt` in the session, so only the key is
  wrong; the refusal's message would print the raw spelling of lo beside the canonical hi (cosmetic, not claimed).
- `pgpm.archive_to_s3_ndjson` / `pgpm.archive_to_s3_parquet` (3878-3934): unchanged by the PR as the body
  says; `archive._refuse_empty_range` parses the raw text in the caller's session via `pgpm._native_gt`,
  the same reading `pgpm._native_text` applies, and `covered_hi` is returned as the caller passed `p_hi`
  (core canonicalises it at `_archive_step`, core install.sql:5436). Read; consistent with the body.
- Other reads of a bound text in pgpm_archive: `grep '::timestamptz|::timestamp\b|::date\b'` over the
  module finds only `archive._object_stem` (2779-2780, pinned), the Parquet epoch encoder on column values
  (2100) and the int64 clamp (663-664). No `restore` routine exists in pgpm_archive; the only ledger write is
  core's `_archive_step` insert (5437), which stores `v_range.lo` from `pgpm.part` and the canonicalised
  `covered_hi`. The synchronous exports `archive.to_s3` / `to_s3_parquet` take a child name, not bounds.
- `archive._object_key` callers: only the two encoders (2914, 3116, 3187); the body's "only callers" claim holds.
- `pgpm._native_text('id', '0100')` = `'100'`; distinct numbers keep distinct stems (#502 holds).
- `tests/archive/db/54`: parts A, C, D fail against this tree for the reason above and part B passes, which
  matches the body's description of the ndjson mutant exactly; the body's "`./test.sh archive`: PASS" is not
  what this tree does. `bench/archive_direct_call_bounds.sh`: read; reports LIVENESS failures separately,
  counts assertions ran, installs via `/repo` paths (harness-mounted, as the other archive guards do);
  nothing further to claim. `test.sh` hunk wires the guard with a fresh db name `pgpm_perf396`. CHANGELOG and
  docs/reference.md describe the intended behaviour; their claim for NDJSON is the P1-01 defect (not filed
  separately as Tier 4: one root cause).

## Lens: time and zones

- Session TimeZone differing from the grid's: NDJSON from `America/New_York` with offset-less bounds on a
  UTC grid read ids 1 and 4 (05:00Z to 05:00Z next day) and keyed `_2024010200000000` (00:00Z): the same
  missing line as P1-01 (folded into the claim's scenario, not a second claim). Parquet from the same
  session was not re-run; its code path canonicalises lo, as the DMY probe showed.
- `pgpm._native_text` under `DateStyle 'Postgres, DMY'` and `IntervalStyle postgres_verbose`:
  `'Tue 02 Jan 00:00:00 2024 +00'` and `'02/01/2024 00:00:00+00'` both render `2024-01-02 00:00:00+00`
  (`_ts_text` pins ISO; IntervalStyle does not touch timestamptz output). Held.
- `Asia/Kolkata` with `SQL, MDY`: `_native_text` renders `2024-01-02 00:00:00+05:30` and `_object_stem`
  reads it under its UTC pin to `2024010118300000`; the offset travels in the text, so #788's abbreviation
  class ('IST') cannot arise from a canonical bound. Held.
- Key, ledger row and object agreement for a tick from a DMY / New York session: a tick's lo comes from
  `pgpm.part` (canonical) and its hi is canonicalised by core before the ledger insert; the strategy's new
  reading of canonical text is the identity. Not reached dynamically: a fresh transmute's monolith always
  extends to today and is never retention-eligible without a drain, which the budget did not cover.

## Hypotheses (no reproduction)

- The recorded-chunk refusal's message in the NDJSON path prints `p_lo` as the caller spelled it and `p_hi`
  canonical, so a `SQL, DMY` caller reads `[02/01/2024 ..., 2024-01-03 00:00:00+00)` in one refusal; cosmetic,
  and moot once P1-01 is fixed.
- A tick's id lo stored by `pgpm.part` with trailing zeros (`'100.0'`) is now keyed `_100` on a direct call
  but was keyed `_100.0` by the tick that archived it; the ledger keeps the old key, so a direct re-run of
  that chunk computes a different key, finds no ledger row at it, and is admitted to PUT a second object
  rather than being held to the recorded one. Not built: needs a grid whose `part.lo` carries a scale, and
  the body documents the key change.
