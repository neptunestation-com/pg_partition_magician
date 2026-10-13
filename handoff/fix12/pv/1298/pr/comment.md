## Per-PR adversarial verification of `8f77fc0` (base `b76002e`)

**Landing: clear.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1260 acceptance (F5-02): archive._owned_key claims object keys as TEXT (key base = p_prefix as archive.configure stored it), but the store (MinIO, the harness's and README's S3-compatible store) reads '/P/x' and 'P/x' as one object; a table that takes a dropped table's name and is configured with the same prefix spelled with a leading slash claims the unclaimed base '/P/public.t', keeps the plain key shape, and its chunk PUT replaces the dropped table's object (the only copy of its rows) instead of getting the oid shape; configure should refuse or canonicalise a leading '/' (and the claims compare the key the store will use) | yes | yes | `archive_key_base_spelled_as_stored`: yes; `archive_recorded_chunk_ledger_spelled`: NO |  |

### Closing claim

**holds**: (1) Call sites: every key the module writes is assembled by archive._owned_key (chunks via _object_key at the NDJSON single/multipart and Parquet strategies, exports via _child_object_key in to_s3 and to_s3_parquet); the only other writers of archive.object_key_owner / object_key_claim are the install seeds, which the new _claim_canonical_spellings follows, and _refuse_recorded_chunk_overwrite, which now locks and reads the canonical claim and matches the ledger by canonical spelling. pgpm_core only records the s3_key a strategy returns; pgpm_hypertable has no keys. (2) Store equivalences beyond the ones canonicalised, measured on the harness MinIO through the module's signer: backslash, trailing '/', case, NFD vs NFC, trailing space, %2F (encoded by s3_url_encode) and a '...' segment are all distinct objects, so no other spelling of one object reaches two claims; '.'/'..' segments are refused in configure and again in _owned_key after canonicalisation (also for ones introduced by a relation name, since quote_ident wraps them). (3) Upgrade path: older raw-spelled claims are re-claimed canonically, earliest wins; where a canonical base is already held by a later namesake the copied whole-key claims still divert/refuse it (v_owner = namesake retries the oid shape), so no overwrite; the #975 refusal finds a '/P/'-recorded ledger row by canonical spelling. Resume and scheduled ticks go through the same _object_key. (4) Mutations: archive_key_base_spelled_as_stored alone restores F5-02 (mechanically confirmed); archive_recorded_chunk_ledger_spelled alone does NOT restore F5-02, by design: it reverts the ledger lookup only and guards the upgraded-install #975 path (test 52 part B), a cousin, not this defect. (5) Contract changes: configure refusing a '.'/'..' segment refuses no working workflow (such keys were 403 before); on AWS a '/P/' prefix now writes at 'P/...', documented in reference.md and conservative (shared claim gives the oid shape). The only residual I could name, an AWS export colliding with an unclaimed pre-claims (#890) object at the single-slash key, needs objects written before claims existed and is the same pre-existing class any 'P/' configuration already meets; not built as a claim.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 1 | seed_hit |  | archive._owned_key claims and PUTs the key base as assembled from the stored prefix and never calls archive._canonical_key (the body says it canonicalises before claiming), so a namesake configured with the same prefix spelled '/P/' claims a fresh base, keeps the plain key shape and its chunk PUT replaces the dropped table's object on MinIO (the only copy of the rows retire() dropped); it should have reached the 'P/' claim and taken the oid shape |
| `P1-02` | 1 | seed_hit |  | introduced: archive._refuse_recorded_chunk_overwrite now matches the ledger row by archive._canonical_key(a.s3_key) = p_key, but p_key is still the raw key archive._owned_key assembles, so for a table configured with a prefix spelled with a leading '/' (its tick recorded the chunk at '/P/...') no ledger row matches, the #975/#1069 refusal the base gave (a.s3_key = p_key) is lost, and a direct call over the recorded chunk after retire() PUTs an empty object over the only copy of its rows; it should have been refused naming the chunk |

### Seed witness

- S1 in `pgpm_archive/install.sql` (archive_key_base_spelled_as_stored): **found**

### Coverage and budget

- P1: 14 of 14 units read (1.00)
- surface: 6 file(s), 14 unit(s) in the ledger (touched units, their callers, touched files)
- budget: P1 finder ~116k tokens (14/14 units), claims verifier ~76k; acceptance F5-02; seed = the PR's mutation archive_key_base_spelled_as_stored (caught by P1 as P1-01; P1-02 is the same seed's effect on the recorded-chunk refusal, which passes on the real head); other spellings (backslash, trailing slash, case, NFD, %2F) and the upgrade path over raw claims exercised by the claims verifier

🤖 Generated with [Claude Code](https://claude.com/claude-code)
