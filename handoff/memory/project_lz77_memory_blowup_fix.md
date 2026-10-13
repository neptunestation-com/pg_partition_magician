---
name: lz77-memory-blowup-fix
description: "pgpm_archive memory-blowup saga: #366+#368+#370 all fixed, verified, and MERGED (PR #367, merge commit 53bbeed, 2026-09-11); all three issues auto-closed; #369 investigated+closed, no fix"
metadata: 
  node_type: memory
  type: project
  originSessionId: abc60d5a-7d4c-4377-b39c-eac523ec7ebb
  modified: 2026-09-11T04:17:33.814Z
---

**Status as of 2026-09-11: PR #367 MERGED** (merge commit `53bbeed`, user explicitly confirmed
"yes, merge it" after CI green + mergeable check). Issues #366, #368, #370 all auto-closed on
merge. Follow-up (telling Indranil in the Boardy Slack thread,
[[reference_boardy_slack_support_thread]], that the stopgap `archive_byte_budget` guidance can be
relaxed) -- David said "I'll handle that" himself; do NOT post there unless asked again.

**#370 was FIXED, VERIFIED, and closed out with evidence in a comment on the issue itself**
(commit 03abead, on `fix/lz77-hash-table-memory-blowup` / PR #367, same branch as #366/#368).

The fix eliminated both amplification mechanisms the plan comment (linked below) called out:
(1) `_pq_deflate_encode_dynamic`'s six per-token `int4[]` arrays, replaced by calling
`archive._pq_lz77_tokens` a SECOND time in pass 3 and recomputing each token's code inline instead
of replaying arrays by index; (2) the `v_bytes int4[]` output accumulator in BOTH
`_pq_deflate_encode` and `_pq_deflate_encode_dynamic`, replaced by fixed-8192-byte chunks emitted
via `return next` from new internal `_pq_deflate_encode_chunks`/`_dynamic_chunks` functions
(`returns table(chunk bytea)`), aggregated via `string_agg` by a thin wrapper of the original name.

Verified same-bar-as-always: byte-for-byte identical output old vs. new (empty/tiny/repetitive/
near-random/chunk-boundary sizes 8190-8194+20000), `./test.sh archive` full green, a new
`bench/archive_deflate_memory.sh` guard + `archive_deflate_six_arrays` mutation in
`bench/mutations/mutate.py` with `./test.sh discriminate` confirming it catches a reversion, AND a
direct re-reproduction of the original 256MB incident: pre-fix code still throws the exact same
`invalid memory alloc request size` error class at that exact scale (268,435,456 bytes) after
~6.9GB peak RSS; post-fix code succeeds at ~1.64GB peak RSS. Full numbers in the issue comment:
https://github.com/dventimisupabase/pg_partition_magician/issues/370#issuecomment-5629120150

Stopgap guidance already given to Indranil (lower `archive_byte_budget`) can be relaxed once PR
#367 merges -- follow up in the Slack thread ([[reference_boardy_slack_support_thread]]) then, not
before.

---

**Status as of 2026-09-10, FIRST session on #370 (kept for history) -- four issues deep into
pgpm_archive's memory behavior for Boardy/Indranil:**

1. **#366 (LZ77 matcher, per-position temp table+btree -> fixed-size hash table)** -- fixed,
   verified, in [PR #367](https://github.com/dventimisupabase/pg_partition_magician/pull/367)
   (branch `fix/lz77-hash-table-memory-blowup`). PR still OPEN, not merged.
2. **#368 (`archive._pq_encode_column_data`'s `array_agg`->`unnest`->`string_agg` double
   materialization)** -- ALSO fixed, ALSO verified, landed as a SECOND commit on the SAME PR #367
   (stacked deliberately: #368's discriminate guard needed #366's generalized
   `discriminate.sh`/`mutate.py` container-routing). PR #367's title/body were updated to cover
   both fixes with their own verification sections. **Do not re-implement either #366 or #368** --
   read the PR diff first if in doubt.
3. **#369** (a further ~33% RSS reduction by splitting `_pq_encode_column_data`'s combined
   two-aggregate query into two separate queries) -- investigated, found it only helps when
   `ORDER BY` resolves to an index scan, which neither real call site
   (`_pq_to_parquet`'s `ctid` order, `_pq_to_parquet_range`'s unindexed composite order) can get.
   Also tried collapsing to ONE aggregate via a tagged byte-stream + a set-returning splitter --
   measured WORSE (the splitter's own tuplestore materialization stacks a third full-size buffer
   on top). **Issue CLOSED with these findings, no code change.** Don't re-attempt either idea
   without genuinely new information.
4. **#370 (NEW this session, UNIMPLEMENTED) -- what Indranil actually hit.** After
   reviewing/installing #366+#368, he hit `invalid memory alloc request size 1468780843`
   archiving a `prompts."PromptRunLog"` chunk at `archive_byte_budget=256MB`. Root-caused and
   **reproduced with a synthetic payload** (not just theorized):
   `archive._pq_deflate_encode_dynamic`'s six parallel `int4[]` token-bookkeeping arrays (one
   element per LZ77 token) can exceed Postgres's hard ~1GB single-value ceiling on
   poorly-compressible payloads -- Boardy's JSONB prompt/model-output blobs are exactly this
   shape. Confirmed independent of #366/#368: that function is untouched by both. Also found a
   second, related amplification: `v_bytes int4[]` (4 bytes per OUTPUT byte, plus a hex-round-trip
   at the end) present identically in BOTH `_pq_deflate_encode` (fixed-Huffman, no current call
   site) and `_pq_deflate_encode_dynamic` (dynamic, what every call site actually uses).

   **A full implementation plan is approved and posted as a comment on issue #370 itself:**
   https://github.com/dventimisupabase/pg_partition_magician/issues/370 -- read that comment
   first; it is the source of truth for the design (two-pass tokenize in
   `_pq_deflate_encode_dynamic` to eliminate the six arrays entirely; a fixed-size-chunk +
   `string_agg` accumulator replacing `v_bytes int4[]` in BOTH encoders -- scope explicitly
   confirmed as "fix both" even though only the dynamic one has a live call site today).
   **NOT YET IMPLEMENTED as of this memory** -- this is the next thing to build, on the SAME
   branch (`fix/lz77-hash-table-memory-blowup`, still PR #367) unless told otherwise.

**Live incident context:** Indranil (Boardy, Slack channel C0BRQJML6P3 --
[[reference_boardy_slack_support_thread]]) runs `archive_batch=1`, `archive_byte_budget=256MB`,
hit this on 2026-09-10 after reviewing/installing #366+#368. **David already replied to him in
Slack** -- do not re-reply assuming no response was sent; check the thread directly if the exact
wording matters. An immediate stopgap was already suggested to Indranil: lower
`archive_byte_budget` further (e.g. 64-128MB) while #370 gets implemented. That is a stopgap, not
a fix -- a sufficiently large/poorly-compressible single chunk can still hit this at a lower
budget, just less often.

**How to pick this up cold in a new session:**
1. Read issue #370's plan comment (link above) in full -- it has the complete design, not just
   this summary.
2. `git checkout fix/lz77-hash-table-memory-blowup` (or confirm already on it). Only
   `pgpm_archive/install.sql`, `bench/`, `test.sh`, and `bench/mutations/mutate.py` are in scope
   for #370 -- `pgpm_core/install.sql` is untouched by this entire branch (verified byte-identical
   to `main`).
3. Implement, then verify with the SAME bar every fix in this saga has used: byte-for-byte
   identical output old vs. new (empty, tiny, highly repetitive, near-random, and sizes straddling
   the new chunk-size boundary exactly), `./test.sh archive`, a new `bench/` guard + `mutate.py`
   mutation proving `./test.sh discriminate` catches a regression back to the old pattern, and a
   direct re-reproduction of the original 256MB failure (a synthetic poorly-compressible payload
   through `_pq_deflate_encode_dynamic` directly) confirming it now succeeds with a real peak-RSS
   number, not an assumption.
4. Update issue #370 with the fix's results once done, matching how #366/#368/#369 were each
   closed out with real evidence.
5. See [[feedback_dont_assume_standing_merge_authorization]] before merging or pushing PR #367
   once #370's fix lands on it.

---

**Original #366/#368 evidence and methodology (kept for reference -- still accurate for those two
specifically):**

One correction to the original #366 scoping comment, discovered while implementing: it proposed a
`32768`-bucket hash table. That's wrong for byte-identical equivalence -- `h` is the literal 24-bit
3-byte value with zero collisions today, and reducing to 15 bits (32768 buckets) lets two different
3-byte sequences collide, silently hiding an older real match behind a newer unrelated one (still
valid DEFLATE, but not byte-identical to pre-fix output). The PR uses a full `int4[16777216]` (2^24
entries, ~64 MiB flat, zero collisions) instead.

Self-verified evidence (both old and new code run by the same methodology), posted as PR #367
comments so it's durable:

| scale | old (pre-#366) peak RSS | new (#366-fixed) peak RSS | ratio |
|---|---|---|---|
| 10MB | 243,456 KB | 322,124 KB | new *higher* (fixed 64MB table dominates at small scale) |
| 30MB | 561,212 KB | 402,244 KB | ~1.4x |
| 150MB (incident's own scale) | ~2.33-2.39 GB | ~753-802 MB | ~3x |
| 512MB | 8,037,536 KB (~7.66 GB) | 3,126,684 KB (~3.05 GB) | ~2.57x |

At 512MB, profiling found `archive._pq_encode_column_data` alone (pre-#368) accounted for
~3.05-3.2 GB in isolation -- essentially the entire full-pipeline number, via
`array_agg`->`unnest`->`string_agg` materializing 2-3 full-size copies of the column. After #368,
the SAME 512MB scale lands at ~1.7x-3.1x depending on `ORDER BY`/scale (see #369's notes above for
why it doesn't go lower without a bigger rewrite).

How the memory measurements were actually done (needed again if any of these ever regress): a
scratch Postgres instance built FROM the archive track's own image (`pgpm_test:17-archive`, has
real `pgsql-http`, not a stub), core + archive installed, a table with wide text/jsonb rows
matching Boardy's `PromptRunLog` shape, large enough for the target chunk size, then calling
`archive._pq_to_parquet_range(parent, control, lo, hi, true)` (or
`archive._pq_encode_column_data(...)` directly, to isolate just the encode step) while polling the
backend's RSS from a SEPARATE `docker exec` reading `/proc/<pid>/status`'s `VmRSS` line directly
(not `ps`). Restart the container between old-vs-new comparison runs at the same size --
`shared_buffers` residency from an earlier large run carries over across databases in the same
server and contaminates a same-container A/B comparison. The CI-sized guards
(`bench/archive_lz77_memory.sh`, `bench/archive_encode_memory.sh`) use smaller fixtures, calibrated
empirically (not by formula) so the old pattern clears the guard's threshold and the new
implementation stays comfortably under it.
