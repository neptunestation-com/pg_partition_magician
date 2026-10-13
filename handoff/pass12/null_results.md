## Null results (by lens)

### Fresh surface

- `_transmute_reap`'s re-read under ACCESS EXCLUSIVE with SKIP LOCKED and the PGPMR rollback, walked through every interleaving of the take-over's row lock against the reaper's table lock and of the reaper's delete against the take-over's ON CONFLICT re-insert: each ends with a live conversion intact or a fresh one (F1, F9, F18).
- The transmute cutover's forward-name block: the post-obtain re-ask, `_transmute_names_present` read before obtain, and the 23505 / 42P07 / 42710 handler, which can fire only on a concurrent creator; a holder still open at lock_timeout surfaces as 55P03 and leaves the resumable state, as documented (F1, F9, F18).
- `_snapshot_wait` and `_regrain_snapshot_wait` within one database: `age(backend_xmin) >= age(reference)`, the per-poll `pg_stat_clear_snapshot`, the own-xid exemption for direct blockers, the chained refusal at depth 16, the peer advisory marker, and `regrain_written_xid` written by every copy and reconcile batch, rolled back with a cancelled tick and reset by `_scratch_record` (F3, F6, F9, F10).
- The hypertable copy's lock order (#1158): every drain and drain step takes ROW EXCLUSIVE on the copy before it reads the delta or the source, nothing taken earlier conflicts with the cutover's ACCESS EXCLUSIVE, and a drain still waiting after the swap fails 42P01 as documented (F6, F9).
- `_archive_hold_partition` against a DETACH ... CONCURRENTLY started after the hold, driven in two sessions with a slow strategy: the strategy saw all 50 rows because the partition stays visible to the rest of the same top-level statement; the hold's ACCESS SHARE also leaves `archive_recorded_chunk_tick_race`'s wait witness intact (F9, F11r).
- `retire()`'s SHARE UPDATE EXCLUSIVE before `pg_partition_ancestors`, its failed-dispatch path with no pg_cron (mark stamped, `fail_retain_detach`, later disowned), `_disown_unvouched_retirements`, `_retain_recall`'s three arms and `_detach_reap`'s disown ahead of FINALIZE (F4, F9).
- `_cell_walk_rows` / `_cell_walk_step` in obtain and extend_to: strict `>` on a built row's hi, a dead row spanning several cells, and obtain over a hole building every nameable cell around it (F4, F10).
- `_over_retired_chunks`' floor and native overlap test, `_backfill_chunk_oids` over five write-block states and an adopted successor, and forget_missing writing its chunk list before the ledger delete (F4, F10).
- The archive digest (#1069): `_row_digest` pins every setting `row_to_json` output reads (TimeZone, DateStyle, IntervalStyle, extra_float_digits, bytea_output, lc_monetary, search_path), the NDJSON and Parquet digests cover the same columns, the claim row is locked FOR UPDATE before the ledger read, and a zero-row chunk digests to `md5('')` on both paths (F5, F19).
- Every bench LIVENESS relabel (237 pure relabels, 149 new lines) and every prefixed line in the new pgTAP files judged a premise rather than a defect check, with each TAP wrapper's body compared mechanically against the shared template (F11, F11r, F13, F15).

### Time and zones

- `_ts_text`, `_time_literal`, `_native_text` and `_col_to_native` rendered and re-parsed under `SQL, DMY`, German, `Postgres, YMD` and ISO, in Asia/Kolkata (an LMT offset with seconds), with five-digit and BC years; `_native_order_key` gives the same epoch under four DateStyles and a `+05:30` offset (F2, F4, F9).
- `_grid_floor` / `_grid_next` property sweep (floor <= x < next, floor(next) = next) over 26 zones including Havana, Apia, Troll, Kwajalein and St_Johns, steps of 1, 3 and 12 months, every local midnight on the 1st from 1950 to 2040 plus and minus 1 us; the fixed branch from anchors in year 1, 4000 BC and 9999 with steps down to 1 us (F2).
- Fixed steps form an absolute, zone-free lattice, so `'24 hours'` and `'1 day'` give the same grid in any partition_tz, as `_same_step` and the reference assume (F10, F12).
- `_retain_horizon` on Pacific/Apia's skipped 2011-12-30, a spring-forward gap, an ambiguous fall-back wall time and tests/311's nonexistent 02:30 the morning after: each resolves into the past (F2, F15).
- IntervalStyle round trips of stored steps and retains: 13 shapes under postgres, postgres_verbose, sql_standard and iso_8601 (F2), transmute's `p_interval::text` hand-off for shapes such as `'-1 month 30 days'` (F18), and from_hypertable run end to end under iso_8601, storing `'P1D'` (F6).
- archive.to_s3 at fetch_rows 1 under sql_standard, `bytea_output escape`, `SQL, DMY` and New York over timetz, mixed-sign intervals, bytea, timestamptz across the 2024-11-03 repeated hour, real NaN and -0, BC and year-20240 dates; `_cursor_text` under Asia/Kolkata; every row exported once (F5, F16, F19).
- adopt_partition under Asia/Kolkata with `SQL, DMY`, where `pg_get_expr` renders `IST` (which the server parses as Israel), still records the right instant through its pinned session settings (F2).
- Every bound `_transmute` writes (claim lo/hi, CHECK, ATTACH, config, part) goes through `_ts_text` / `_encode` in the claim's zone, and a resume adopts `partition_tz` from the claim before the grid check and the monolith name (F1, F18).
- A hypertable `date` dimension copied under Asia/Tokyo and America/Los_Angeles kept all ten rows, and timescale/35's spring-forward pre-drain was confirmed to reach the gap it tests (F16r).
- The uuid and text_time decoders' float8 path swept monthly from 2000 to 10000 (sub-millisecond error against whole-millisecond bounds), `_pq_epoch_micros`' clamps and infinity sentinels, and the S3 signers' use of `clock_timestamp()` (F2, F5, F19).

### Boundary arithmetic and types

- `_floor_div` signs and -Infinity, `_id_label` and `_is_fine_child_label` for negatives and fractions (`-0.5` round-trips), 20-digit values, and the reference's `_part_name` byte budgets (43/54 monthly, 19/42 id) recomputed (F2).
- 63-byte clipping in `_array_type_name` and `_is_clone_pkey_name` on character boundaries, and the suites' fixtures sitting exactly on the 63/64-byte line (F1, F13, F14, F18).
- The lock-budget line `2 * n > slots / 2`: `slots / 4` admitted and `slots / 4 + 1` refused for every residue of slots mod 4, refusal from the 1601st child at stock 64 x 100, and the swap's measured charge of 2 + 2k slots per child (F3, F10, F12, F15, F17).
- `_text_time_to_ts_bounded` at the interval edge (9223372036853 s), the timestamptz edge (9224318015999 s), the millisecond branch and an infinite epoch (F2).
- `_control_bound_contract` and `_id_step_contract` with domains unwrapped, typmod -1 skipped and NaN / Infinity refused; NaN and Infinity id steps reach regrain only as `nosubdiv` or a set_regrain refusal, never a wedge (F1, F3, F18).
- The Parquet and DEFLATE encoders: every Thrift compact field id against parquet.thrift, length codes 257 to 285, distance codes to 32768, the length-limited Huffman repair, gzip trailers, and `_pq_plain_decimal`'s two's complement at negative scale and width 1 (-9 to f7) (F5, F19).
- archive part_bytes accepted at exactly 5242880 and refused at 5242879, fetch_rows at 0 and negative, and the timescale name budget at 48 and 49 bytes (F16, F19).
- Hypertable drain steps with `p_batch` 0 or negative (a one-row batch, no stall), `_from_hypertable_tmp_name`'s fallback at the 63-byte line, and `'infinity'` / `'-infinity'` anchors refused before the copy (F6, F16r).
- obtain at the int4 ceiling (the last cell 2147470000..2147480000) and tests/146's exact int4 and int2 ceiling cells (F8, F13).
- S3 object keys holding space, `+`, `%`, `&`, `?`, `#`, quotes and a non-ASCII byte PUT, GET back byte-identical and DELETE through the signers (F19).

### Operator error

- transmute over a converted table, a re-run from the same and another live session, transmute_abort of nothing, a `'1 day -1 hour'` step (a consistent 23-hour lattice), `'1 month 1 day'` refused by `_grid_floor` before any commit, and `_retain_nonnegative` refusing mixed-sign retains (F1, F18).
- regrain_cancel of nothing and of an unmanaged table, set_regrain twice with a respelled target, set_regrain(null) mid-run, and `_same_step`'s `'1 mon'` / `'1 month'` and `'24 hours'` / `'1 day'` equivalences (F3, F9, F10).
- set_obtain negative and null refused and 0 accepted; set_retain refusing a tightening and naming the partition it would drop (F4, F9, F17).
- `_canonical_tz` refusing legacy and abbreviation zone names on this host while canonicalising `'utc'`, and `set_partition_tz` succeeding on a grid whose recorded zone the host no longer knows (F2).
- archive.configure with a scheme-less endpoint, a `x//` prefix and a `x/a/../` prefix (each loud at the store, nothing written), a schema-qualified `p_child`, swapped strategy bounds and an unconfigure mid-export (F5, F19).
- Remedies typed from their messages and shown to work: `_refuse_detach_pending`'s FINALIZE, the runbook's `adopt_partition(regclass, regclass)`, the `ceil(hi::numeric)` ledger repair, the refused-handoff three calls and c56's re-run copy, which kept writes 300001 and 300002 (F12, F15, F16r, F17, F18).
- The TABLE-form `GRANT USAGE` on an identity sequence that `_acl_carry_ddl` emits, with `REVOKE ALL ... CASCADE` and `GRANT ALL`, accepted on PostgreSQL 15 (F18).
- A second from_hypertable_copy, a re-run with `p_track_changes` toggled, a drain before the copy and a cutover without one, plus all eight documented install commands stopping at the first error (F6, F11r).

### Failure injection

- A cancel or timeout inside the snapshot wait, between the swap's DETACH and ATTACHes, and inside regrain_cancel: each rolls back whole with a transaction-scoped marker, and a cancelled `_regrain_fresh_copy_drift` leaves no probe (F3).
- `_dispatch_detach` with no cron schema (reason logged, mark left without a record, re-dispatched or disowned next call), `_detach_job_holds` failing towards the safe answer, and the per-item `when others` loops in retain, `_enforce_write_blocks`, `_archive_step` and maintain each logging a prefixed skip (F4).
- archive.to_s3's claim inside the `<<export>>` subtransaction, the outer `query_canceled` handler aborting by id or by key, and a returned non-2xx part raising into `_s3_abort_uploads_at` (F5, F16, F19).
- A strategy PUT that fails rolls back the digest and the claim; a tick that fails after its PUT leaves an unrecorded object the next tick may overwrite at the same key (F5, F19).
- The install's upgrade block against a missing parent, an unknown recorded zone and a renamed key column, and `_frontier_native` against a dropped parent and an undecodable text_time maximum (F2).
- Cutover refusals before the swap's COMMIT roll back the catch-up and the index pre-builds, with the FK records and `pgpm.handoff` written inside the swap; transmute's phase boundaries leave a claim the re-run resumes by oid (F6, F18).
- An interrupted DETACH ... CONCURRENTLY against retire (skip_retain) and `_detach_reap` (finalized after the disown), and against tests/312 and 327's killed detachers (F9, F15, F17).
- F10-01's run ticked to its end (3204 sub-ranges at 6400 slots): the swap's measured budget refused every swap tick, so no swap tried to hold more than half the lock table (F10).

### Contracts versus documentation

- The README Quickstart run from the tree, maintain's `p_status` format, maintain_obtain's `obtained=`, forget_missing's `ARCHIVED CHUNKS` method text, the runbook's orphan-table and missing-oid refusal texts and the `pgpm.partitions` view it queries (F4, F12, F17).
- reference.md's transmute entries: each listed refusal maps to a preflight site, and `transmute_abort`'s three promises and the `pgpm.transmute_inflight` column table match the code (F1, F18).
- reference.md's regrain_step budget: the "two slots a child plus two more" charge matches `regrain_step`, and the "about one more" sentence describes the measured cost, not the charge (F3, F17).
- The archive README and reference: key shapes, the oid shape, the whole-key claim, the digest, paging rules, the allowlist, the Parquet type list and the null-argument paragraph, with `archive.configure`, `set_archive_fn` and `archive.to_s3` typed as documented (F5, F19).
- The from_hypertable reference entries: argument rules, the drains' lock order, the snapshot wait and its limit, and the 42P01 after the swap (F6).
- Every `throws_*` around a committing procedure across tests/, the archive suite and the timescale suite pins a SQLSTATE or a message, and an experiment confirmed that a non-refusing transmute dies 2D000 so the P0001 pin discriminates (F10, F13, F14, F15, F16, F16r).
- The `doc_*` guards measure their fact before reading the docs, each with a planted CONTROL, and all host-only and doc guards PASS on the tree (F7, F11r).
- lint.yml against `test.sh run_lint` (job list equal to `summary.needs`, each job in `bash -e -o pipefail`), the review tooling's selftests, and the test.sh lines in RELEASING.md, ONBOARDING.md and README.md (F7, F12).
- Every `pgpm.log` action in the reference's vocabulary is written somewhere outside the claimed sites (`obtain_backoff` is a `p_status` note), and observe_window's `regrains` counts the `regrain` action regrain() writes (F4, F17).
