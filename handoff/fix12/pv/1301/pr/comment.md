## Per-PR adversarial verification of `4cd5c0a` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: pre_existing with no verdict yet (unverified is not clear)
- V-02: pre_existing with no verdict yet (unverified is not clear)

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1269 acceptance (F19-02): archive.configure accepts p_endpoint 'http://host:port/' (trailing slash); the signers then address '//<bucket>/<key>' and the store answers HTTP 400 on every PUT, so every export and every tick's chunk fails after the read; configure should refuse or normalise an endpoint that can never work, as it refuses p_part_bytes and p_fetch_rows (#594, #636). | yes | yes | `archive_endpoint_trailing_slash_kept`: yes; `archive_endpoint_unrefused`: NO |  |

### Closing claim

**holds**: 1) Call sites: every cfg.endpoint reader in pgpm_archive/install.sql (to_s3 PUT/multipart POST/DELETE, the archive_fn chunk writers, _s3_abort_uploads_at) hands the endpoint to one of the two signers, and both now canonicalise it; no other module or uninstall.sql builds an S3 URL. 2) Upgrade/hand-stored path: a row updated by hand to 'http://minio:9000/' on the head exports and lands at the key (live, pgpm_prv-archive); scheduled ticks use the same signers. Also live on the head: 'http://minio:9000///' and '//' canonicalise and export ok; 'HTTP://' is refused (the signers could not use it either). 3) Body promises: the refusal admits userinfo ('http://minioadmin@minio:9000' is taken, signed with host 'minioadmin@minio:9000', every PUT 403 SignatureDoesNotMatch): V-01, Tier 3, fails on base and head (pre_existing; also 'http://minio:9000/.' is taken and 403s, same class, not filed separately). The #1269 consequence itself (//bucket/key, HTTP 400) is still reachable through p_bucket spelled '/archive-test-bucket', which configure stores verbatim: V-02, Tier 3, fails on base and head, a sibling operand outside the body's claim. 4) Mutations: archive_endpoint_trailing_slash_kept alone restores the issue's defect (ACC fails); archive_endpoint_unrefused alone does not, as expected, since it guards the new refusal half (test 53's refusal assertions), not the trailing slash. 5) Contract change: the refusal rejects only endpoints the signers could never use, and a path prefix (Supabase Storage) is kept; no documented workflow is refused. The trailing-slash endpoint path the issue names is closed on every entry point: holds.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | archive._s3_endpoint_canonical is `select p_endpoint` (the identity) in this tree, so archive.configure stores 'http://minio:9000/' with its slash and both signers still address //<bucket>/<key> (HTTP 400 on every PUT, the issue #1269 defect intact), while the PR body, CHANGELOG and pgpm_archive/README.md say the trailing slash is dropped and the tree's own tests/archive/db/53 fails tests 7-9, 11, 12, 19, 21-24 (the set the body lists for the archive_endpoint_trailing_slash_kept mutant); the helper should return the endpoint without its trailing slashes. |
| `V-01` | 3 | pre_existing | unverified | PR #1301's new endpoint refusal ('^https?://[^/?#[:space:]]+(/...)?$') admits userinfo: archive.configure takes 'http://minioadmin@minio:9000', the signers take 'minioadmin@minio:9000' as the host they sign, the client sends Host: minio:9000, and every PUT is refused 403 SignatureDoesNotMatch after the read. The body says configure refuses an endpoint the signers cannot use; this one it takes. Loud, nothing lost. |
| `V-02` | 3 | pre_existing | unverified | The #1269 consequence through p_bucket rather than p_endpoint: archive.configure stores the bucket verbatim and both signers build endpoint || '/' || bucket || '/' || key, so a bucket spelled '/archive-test-bucket' addresses '//archive-test-bucket/<key>' and MinIO answers HTTP 400 to every PUT, after the read. configure checks nothing about the bucket. Sibling of the mechanism the PR fixes; outside the body's claim. Loud, nothing lost. |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
 not ok 6 - its object lands at the key, as it does through the plain spelling        +
 # Failed test 6: "its object lands at the key, as it does through the plain spelling"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
psql:<stdin>:6: NOTICE:  extension "pgtap" already exists, skipping
```
head:
```
 not ok 6 - its object lands at the key, as it does through the plain spelling        +
 # Failed test 6: "its object lands at the key, as it does through the plain spelling"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
psql:<stdin>:6: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

<details><summary><code>V-02</code> pre_existing: tails</summary>

base:
```
 not ok 6 - its object lands at the key, as it does through the plain spelling        +
 # Failed test 6: "its object lands at the key, as it does through the plain spelling"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
psql:<stdin>:5: NOTICE:  extension "pgtap" already exists, skipping
```
head:
```
 not ok 6 - its object lands at the key, as it does through the plain spelling        +
 # Failed test 6: "its object lands at the key, as it does through the plain spelling"
(1 row)
                finish                
--------------------------------------
 # Looks like you failed 2 tests of 6
(1 row)
psql:<stdin>:5: NOTICE:  extension "pgtap" already exists, skipping
```

</details>

### Seed witness

- S1 in `pgpm_archive/install.sql` (archive_endpoint_trailing_slash_kept): **found**

### Coverage and budget

- P1: 15 of 15 units read (1.00)
- surface: 6 file(s), 15 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 1: P1 ~75k tokens (15/15 units), claims verifier ~65k (live on the archive harness); acceptance F19-02 (the verifier's rebuilt reproduction); seed caught; V-01 (userinfo in the endpoint accepted, 403 on every PUT) and V-02 (the bucket spelled with a leading slash reaches the issue's own //bucket failure) are Tier 3 siblings of the fix's mechanism and go back to the fixer for an in-place round 2 rather than to a candidate verifier

🤖 Generated with [Claude Code](https://claude.com/claude-code)
