## G8 (#1265, PR #1293)
- pgpm_core/install.sql check_time_monotonic: a text time column is still parsed under the caller's DateStyle (MDY vs DMY), so '03/08/2026' can order differently by session (outside #1265; the PR body says so).
- check_time_monotonic's `order by random() limit p_sample` reads and sorts the whole table (pass-11 F2 H5; unchanged).
- pgpm_core/install.sql:7190 and :7203 `_time_unit_breach` reads `p_anchor::timestamptz` in the session zone (pass-11 F9r H4; unchanged).
## PR #1294 (#1261) claims verifier, lead to file
- pgpm_hypertable/install.sql:1184 `from_hypertable_copy` has its own `LIKE ... INCLUDING CONSTRAINTS` and (per the fixer's reading) does not refuse or carry a NOT VALID CHECK on the hypertable: the #1261 shape in the hypertable copy; unverified (no timescale harness in the verification).
## G4 (#1261, PR #1294)
- pgpm_hypertable/install.sql:1184 `from_hypertable_copy` makes its own copy `LIKE ... INCLUDING CONSTRAINTS` (not through `_regrain_copy_make`); nothing refuses a NOT VALID CHECK on the hypertable, so an old violating row would likely fail that copy with 23514 (not run; the #1261 shape in the hypertable copy; also raised by PR #1294's claims verifier).
- pgpm_hypertable/install.sql:645 comment assumes "the copy's rows were checked as they were inserted", the same blind spot.
## G10 (#1267, PR #1297)
- pgpm_core/install.sql ~9980 (old transmute/_transmute signatures) and ~11663 (transmute_by_id/transmute_by_uuidv7): `drop function if exists` on retired signatures carries no grants to the replacements.
- `_surface_unreplaceable` flags prokind <> 'f', but `_surface_prepare`'s default-grants branch still runs `drop function`; on a procedure that raises "is not a function" (PG15; pre-existing).
## G3 (#1260, PR #1298)
- Harness MinIO refuses keys with an inner `//` (400 XMinioInvalidObjectName) and `.`/`..` segments fail 403 SignatureDoesNotMatch (curl rewrites the path after signing): before the fix a table whose quoted name held `//` could never archive; it now archives at the collapsed spelling.
- pgpm_archive/install.sql `archive._claim_archived_key_bases` and `_claim_archived_keys` still seed claims from ledger keys as spelled (redundant now that canonical copies follow).
## G5 (#1262, PR #1295)
- pgpm_core/install.sql:3730-3735: retire() locks `v_rel::text` by name (`lock table only %s`) then judges v_rel by oid with pg_partition_ancestors: the V-01 shape (a rename plus a squatter committed while it waits could leave its lock on the squatter). Unverified.
## G6 (#1263, PR #1296)
- tests/328 part J keeps a writer idle with an xid for seconds while other files run in parallel; any such transaction holds back every snapshot in the cluster, so other files' regrain swaps can defer meanwhile (a possible flake source in the core suite).
- pgpm_core/install.sql: every other `skip_*` row is cut at `left(sqlerrm, 200)`, so any long refusal loses its remedy text the same way.
- test.sh lines 111 and 163 carry pre-existing shellcheck info findings.
## G11 (#1268 + #1232, PR #1302)
- #1221 (the session-zone rule asked only after the swap) is open and assigned to no brief this phase.
- pgpm_core/install.sql `_time_unit_breach`: an infinite anchor is refused as off-unit with a "whole multiples of 0.000001 seconds" remedy that cannot apply; on an unconstrained timestamptz column the message offers `ALTER ... TYPE timestamp with time zone`, a no-op.
## G15 (#1272, PR #1303)
- `retire()`'s `fail_retain_drop` method for a table detached by hand ("detached from the parent by something other than retirement; not dropping it", pgpm_core/install.sql ~3767) gives no remedy, although docs/reference.md ~1482 documents one (attach it back or delete the row).
- Coverage gaps the fixer names: `_disown_retirement`'s not-judged branch, `_detach_reap` and `retire()`'s pending branch have no test of their logged remedy.
## PR #1295 round 2 (P1-02, folded into round 3)
- A rename without a squatter while adopt_partition waits: LOCK TABLE raises 42P01 on the old name, against the reference's "names the partition as it is now".
## G2 (#1259, PR #1299)
- pgpm_core/install.sql ~3864 retire()'s one-detach-in-flight tiebreak: a mark with no dispatch record on an attached or pending partition still holds the database-wide slot.
- ~14420 `status().retain_detaching` counts marks with no dispatch record as dispatched detaches.
- Possible archiving stall: with archive_batch 1, a detached retirement of pgpm's own that is not yet covered takes the only turn every tick (logged skip_archive each tick) until the operator applies the remedy.
## PR #1296 round 2 (P1 hypothesis)
- tests/333 LIVENESS 6 flaked once in three runs: the importer's imported xmin can be older than X's xid when an older local or autovacuum xid was running at the export.
## PR #1305 round 2 (claims verifier, unfiled)
- Under the pinned Default abbreviation set, WST and SAT raise from every session (on the base they were readable only in Australia-set sessions); an IST written by an Indian or Irish session reads as Israel's (the PR's documented choice).
- On PG 18 a grid registered in an IST zone may read IST by that zone, unlike what reference.md says (untested: harness is PG 15).
- `set_partition_tz` moves where an offset-less legacy bound falls (an operator state change; say so in the reference?).
## G1 (#1258, PR #1306)
- pgpm_hypertable/install.sql:934 `from_hypertable_copy`, :1317 `from_hypertable_drain_delta_step`, :1495 `from_hypertable_drain_appends_step` are public entry points that never call `_refuse_strict_isolation` (only from_hypertable :2429 and from_hypertable_cutover :1660 do): a copy run inside a REPEATABLE READ transaction might miss a row committed after its snapshot. Unverified; the #1258 shape in the hypertable module (verify first: possible Tier 1).
- pgpm_core/install.sql untransmute (~12191) carries its own inline copy of the isolation check rather than the shared helper.
## PR #1305 round 2 (P1 hypotheses)
- retain/_archive_step session casts of ledger bounds; `_archive_fully_covered` watermark read: the same rule's other readers (null-results.md).
