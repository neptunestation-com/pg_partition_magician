## Defect (#1260, pass 12 F5-02)

`archive._owned_key` claimed key bases (`archive.object_key_owner`) and whole keys (`archive.object_key_claim`) as raw text, built from the prefix exactly as `archive.configure` stored it. MinIO, the store the harness and `pgpm_archive/README.md` name, reads `/P/x`, `//P/x` and `P/x` as one object (measured on the harness's MinIO: all three GET the same object; `P//x` is refused 400 `XMinioInvalidObjectName`). So a table that took a dropped table's name, configured with the same prefix spelled with a leading `/`, claimed the unclaimed base `/P/public.t`, kept the plain key shape, and its chunk PUT replaced the dropped table's object, the only copy of the rows `retire()` dropped.

## Fix

- `archive._canonical_key(text)` (new, immutable): strips leading `/` and collapses every run of `/` to one.
- `archive._owned_key` (the one function that assembles and claims every key, for chunks via `archive._object_key` and for exports via `archive._child_object_key`) canonicalises the assembled base before it claims anything, so the base claim, the whole-key claim and the key PUT are all the canonical spelling. A namesake therefore reaches the dropped table's claim whatever the spelling of its prefix, and takes the oid shape. It refuses a base with a `.` or `..` segment, naming the base and the stored prefix (no store can be addressed with one: curl resolves the segment before sending and the SigV4 signature no longer matches, measured as 403 on MinIO).
- `archive.configure` refuses a prefix with a `.` or `..` segment up front, naming it. It does not rewrite the stored prefix: `scripts/check_archive_object_keys.py` (#872) forbids handing the prefix to any function other than the one that claims, so canonicalisation lives in `_owned_key`, which covers every stored value, old rows included.
- Older-install state: `archive._claim_canonical_spellings()` (new, run by install on every (re-)install after the existing seeds) claims again, in the canonical spelling, every owner base and whole key claimed under another spelling, copying parent, kind, relation and digest; the earliest claim wins where several spellings collapse to one. `archive._refuse_recorded_chunk_overwrite` matches a chunk's `pgpm.archive_ledger` row by the canonical spelling of its recorded key, so the #975/#1069 refusal still finds a chunk an older install recorded as `/P/...` when the key is now assembled as `P/...`.

### What it guarantees, and the store contract

- Every key this module writes, on every path (archive_fn chunks NDJSON/Parquet, `archive.to_s3`, `archive.to_s3_parquet`), is written and claimed in the canonical spelling. Two prefix spellings that differ only by a leading `/` or a doubled `/` are one claim.
- AWS S3 keeps `/P/x`, `//P/x`, `P//x` and `P/x` as distinct objects. On AWS, a prefix configured with a leading or doubled `/` now writes new objects at the single-slash key, not at the spelling configured (documented in `docs/reference.md`). Objects already written stay where the ledger records them. Two spellings AWS would keep apart now share one claim, so the later writer takes the oid shape: conservative, never an overwrite.
- The whole base is canonicalised, not only the prefix: a quoted relation or schema name containing `//` collapses too, so on MinIO a key the store used to refuse (400) is now written at the single-slash spelling and claimed like any other (a relation whose name collapses onto another's base takes the oid shape).
- Not covered: two databases writing one bucket under one prefix (claims live per database, as documented before).

## Acceptance

- F5-02's `repro.sql`, run unchanged in the archive harness: fails on base (`have: 1:new,2:new,3:new,4:new`), passes on this head, fails again on mutant `archive_key_base_spelled_as_stored`.
- `tests/archive/db/52_archive_key_base_canonical_test.sql` (26 assertions): part A the issue (leading `/` and every `/` doubled, identity of both objects); part B an older install's raw-spelled claims and ledger row (install's seed, the #975 refusal still found, a namesake still diverted); part C `.`/`..` refusals in `archive.configure` and `_owned_key`, each remedy typed and shown to archive the chunk.
- Guard `bench/archive_key_base_canonical.sh` (pgTAP wrapper, run by the archive track as `pgpm_perf368`). Mutations: `archive_key_base_spelled_as_stored` (fails part A, assertions 6, 7, 8, 10, 11) and `archive_recorded_chunk_ledger_spelled` (fails part B, assertions 17, 18, 20); no LIVENESS witness fails against either.

Closes #1260

🤖 Generated with [Claude Code](https://claude.com/claude-code)

