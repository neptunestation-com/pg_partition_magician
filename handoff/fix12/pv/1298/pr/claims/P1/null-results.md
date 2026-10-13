# P1 null results: PR #1298 (archive key canonical spelling)

Harness: `pgpm_prv-archive` + MinIO, fresh database per run from the tree's `tests/archive/fixtures.sql`,
`pgpm_core/install.sql`, `pgpm_archive/install.sql` (`--single-transaction`).

## Fresh surface

- `archive._canonical_key`: read; strips `^/+`, collapses `/{2,}`; immutable strict. Used by only two callers in the
  tree (`_claim_canonical_spellings`, `_refuse_recorded_chunk_overwrite`); NOT called by `archive._owned_key`, which is
  the claim P1-01 (the body's central guarantee) and P1-02 (the introduced loss of the #975 refusal).
- `archive.configure`: the `.`/`..` regex `(^|/)\.{1,2}/` refuses `x/../`, `./`, `/../`, `P//./`; a prefix ending in
  `..` without a slash (`P/..`) is not refused and yields the segment `..schema.table`, which is a legal key segment,
  so that is sound. The refusal sits before the upsert, so an existing row is left untouched (test 22 asserts the
  no-row case only; the existing-row case holds by reading). The remedy named ("spell the prefix without it") is
  typed in test 23 and works.
- `archive._owned_key` dot-segment regex `(^|/)\.{1,2}(/|$)`: the `$` branch is unreachable (a base ends in a
  quote_ident'ed name, never in `.`); harmless.
- `archive._claim_canonical_spellings`: distinct-on per canonical key ordered by `claimed_at, parent_oid`, copies
  digest/relation/kind, `on conflict do nothing` keeps an existing canonical claim. Install order (after the ledger
  seeds and `_record_claim_relations`) is right. Ran it on a fresh install: returns 0; test 52 part B shows it
  claiming the canonical spelling of raw-spelled claims. Held.
- `archive._refuse_recorded_chunk_overwrite`: the `for update` is still on `p_key`; the join is now on `p_key`
  rather than `a.s3_key`, which is right once `p_key` is canonical. On this tree it is not (P1-02).
- `archive._object_key`, `archive._child_object_key`, both encoders: every key reaches `_owned_key` and the encoders
  hand the returned key unchanged to the refusal and to the PUT, so there is one spelling per path, just not the
  canonical one on this tree. No sibling site assembles a key.
- `bench/archive_key_base_canonical.sh`: set -u/pipefail, every setup step exit-checked, LIVENESS witnesses named
  separately, zero-ran guard. Ran test 52 by hand on this tree: 6 of 26 fail (6, 7, 8, 10, 11, 20), every LIVENESS
  witness held, so the guard discriminates the tree's state as the defect, not as a fixture failure.
- `test.sh` hunk: adds the guard to the archive track after #1173's, same shape. `CHANGELOG.md`, `docs/reference.md`
  hunks: describe the intended behaviour; on this tree they are not kept (P1-01), which the claims cover rather than
  a separate Tier 4.

## Identity and names

- Namesake after drop, prefix `/P/` vs `P/`: P1-01. Prefix with every `/` doubled: same path (test 52 assertion 10).
- Prefix that is only `/`: in this tree the base is `/schema.t`, on MinIO the same object as `schema.t`; same root
  cause as P1-01, not a separate claim.
- A relation name containing `//` collapsing onto another's base: the body documents the oid shape; on this tree
  nothing collapses (no canonicalisation), so the key is written at the doubled spelling, which MinIO refuses (400)
  and the PUT raises; no overwrite, loud. Not claimed.
- Two databases under one prefix: documented as not covered; not probed.
- Upgraded install with a stored prefix `/P/` (the body says the stored prefix is not rewritten): on this tree the
  table keeps writing raw `/P/...` keys, its new chunks are claimed raw and `_claim_canonical_spellings` only runs at
  install, so the canonical claims lag the raw ones until the next re-install; the #975 refusal for its own chunks is
  lost (P1-02). In the intended design (canonical `_owned_key`) this path holds by reading.
- Core's readers of `pgpm.archive_ledger.s3_key`: none compare it (grep of `pgpm_core/install.sql`); the archive
  module has no restore path and no `scripts/` directory in this tree, so the ledger's key has exactly two readers
  (`_claim_archived_key*` seeds, `_refuse_recorded_chunk_overwrite`).

## Hypotheses (no reproduction)

- `_owned_key`'s dot-segment refusal fires for a RELATION named with a `/./` or `/../` substring (`"a/./b"`), and its
  message blames `archive.config.prefix` and tells the operator to reconfigure the prefix, which cannot help: the
  segment is in the name. The write would fail at the store anyway (signature mismatch), so the consequence is a
  misleading remedy for a contrived name. Tier 4 at most; not built.
- Test 52 part B configures the surviving table with the canonical prefix, so it never exercises an upgraded install
  whose stored prefix is still `/<p>` writing a NEW chunk and then re-running it; that is the state P1-02 uses. The
  mutation `archive_recorded_chunk_ledger_spelled` covers the ledger lookup, and part A covers the missing
  canonicalisation, so this is a coverage note, not a Tier 5 claim.
- With a raw-spelled key (this tree) the multipart abort-by-key listing in `archive.to_s3` would list under `/P/...`
  while MinIO stores the upload under `P/...`; whether an orphaned multipart upload is then missed was not probed.
