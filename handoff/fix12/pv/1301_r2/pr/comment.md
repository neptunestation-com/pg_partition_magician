## Per-PR adversarial verification of `ee22a70` (base `b76002e`)

**Landing: BLOCKED.** The method is `docs/adversarial-review.md`, "Per-PR verification"; every reproduction below ran in a fresh database against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.

Why:
- V-01: pre_existing with no verdict yet (unverified is not clear)
- closing claim: partial (Tried, live in pgpm_prv-archive against MinIO: (1) entry points: archive.configure is the only writer of archive.config (no other insert/update in pgpm_core/pgpm_archive/pgpm_hypertable); every cfg.endpoint reader (to_s3, the tick's chunk PUTs, multipart POST/DELETE, _s3_abort_uploads_at) goes throu); standing on V-01

### Acceptance: the PR's own claims

| reproduction | fails on base | passes on head | the PR's mutations restore it | note |
|---|---|---|---|---|
| `ACC-01` #1269 acceptance (F19-02): archive.configure accepts p_endpoint 'http://host:port/' (trailing slash); the signers then address '//<bucket>/<key>' and the store answers HTTP 400 on every PUT, so every export and every tick's chunk fails after the read; configure should refuse or normalise an endpoint that can never work, as it refuses p_part_bytes and p_fetch_rows (#594, #636). | yes | yes | `archive_bucket_unrefused`: NO; `archive_endpoint_dot_segment_unrefused`: NO; `archive_endpoint_trailing_slash_kept`: yes; `archive_endpoint_unrefused`: NO; `archive_endpoint_userinfo_unrefused`: NO |  |
| `ACC-02` #1269 acceptance (V-01-1301): PR #1301's new endpoint refusal ('^https?://[^/?#[:space:]]+(/...)?$') admits userinfo: archive.configure takes 'http://minioadmin@minio:9000', the signers take 'minioadmin@minio:9000' as the host they sign, the client sends Host: minio:9000, and every PUT is refused 403 SignatureDoesNotMatch after the read. The body says configure refuses an endpoint the signers cannot use; this one it takes. Loud, nothing lost. | yes | yes | `archive_bucket_unrefused`: NO; `archive_endpoint_dot_segment_unrefused`: NO; `archive_endpoint_trailing_slash_kept`: NO; `archive_endpoint_unrefused`: NO; `archive_endpoint_userinfo_unrefused`: yes |  |
| `ACC-03` #1269 acceptance (V-02-1301): The #1269 consequence through p_bucket rather than p_endpoint: archive.configure stores the bucket verbatim and both signers build endpoint || '/' || bucket || '/' || key, so a bucket spelled '/archive-test-bucket' addresses '//archive-test-bucket/<key>' and MinIO answers HTTP 400 to every PUT, after the read. configure checks nothing about the bucket. Sibling of the mechanism the PR fixes; outside the body's claim. Loud, nothing lost. | yes | yes | `archive_bucket_unrefused`: yes; `archive_endpoint_dot_segment_unrefused`: NO; `archive_endpoint_trailing_slash_kept`: NO; `archive_endpoint_unrefused`: NO; `archive_endpoint_userinfo_unrefused`: NO |  |

### Closing claim

**partial**: Tried, live in pgpm_prv-archive against MinIO: (1) entry points: archive.configure is the only writer of archive.config (no other insert/update in pgpm_core/pgpm_archive/pgpm_hypertable); every cfg.endpoint reader (to_s3, the tick's chunk PUTs, multipart POST/DELETE, _s3_abort_uploads_at) goes through one of the two signers, both of which now canonicalise the endpoint, so the trailing-slash path is closed on the direct, scheduled and upgraded-row paths. (2) Bucket: the head REFUSES rather than canonicalises a bucket with '/', so 'bucket/', 'bucket/sub', '/bucket' are refused naming p_bucket; both signers and the tick read cfg.bucket raw and identically; a slashed bucket stored by an older install is not rewritten and stays loud (HTTP 400), which the body does not promise otherwise. Uppercase/dotted buckets are accepted (store-specific naming, not this mechanism). (3) Endpoint shapes: port+path+trailing slash canonicalised to 'http://minio:9000/pre/fix'; IPv6 '[::1]:9000/' canonicalised and signed host matches the sent one; uppercase scheme refused (base fails on it too). A percent-encoded dot segment ('/%2E%2E/') is accepted although the body says '..' segments are refused (contrived, not filed). (4) Mutations: only archive_endpoint_trailing_slash_kept alone restores the issue's trailing-slash defect; the other four guard the other refusals, as expected. (5) What survives: V-01. An endpoint spelling the scheme's DEFAULT port ('http://host:80', 'https://<ref>.supabase.co:443/storage/v1/s3', both accepted by configure) is signed with v_host = 'host:80' while libcurl sends 'Host: host' (verified by a listener: it drops a default port), so the store answers 403 SignatureDoesNotMatch to every PUT: reproduced end to end on head and base through a TCP relay on port 80 to MinIO (LIVENESS: the same store spelled without the port exports and lands the object). This is the same signed-host-vs-sent-host mechanism as round 1's userinfo endpoint, which the head now refuses for exactly that reason, and an endpoint 'the signers cannot use' that the PR title says configure refuses. Tier 3 (loud, nothing lost), pre_existing on the PR's surface.

### Claims in the PR's surface

| claim | tier | class | verdict | scenario |
|---|---|---|---|---|
| `P1-01` | 3 | seed_hit |  | archive._s3_endpoint_canonical is `select p_endpoint` (the identity) in this tree, so archive.configure stores 'http://minio:9000/' with its slash and both signers address //archive-test-bucket/<key> (HTTP 400 on every PUT, the issue's own defect), while the CHANGELOG, pgpm_archive/README.md, the helper's comment and the PR body all say the trailing slashes are dropped at configure and in both signers; tests/archive/db/53 itself fails 10 of 46 on this tree (7-9, 11, 12, 19, 21-24, the exact set the PR body attributes to the mutant archive_endpoint_trailing_slash_kept). |
| `V-01` | 3 | pre_existing | unverified | archive.configure accepts an endpoint spelling the scheme's default port ('http://host:80', 'https://<ref>.supabase.co:443/storage/v1/s3'); both signers sign the Host as the endpoint's whole authority ('host:80') while libcurl sends 'Host: host' (it drops a default port), so the store answers 403 SignatureDoesNotMatch to every request and every export and every tick's chunk fails after the read. Same signed-host-vs-sent-host mechanism as the userinfo endpoint the round-2 head refuses; an endpoint the signers cannot use that configure still takes. |

<details><summary><code>V-01</code> pre_existing: tails</summary>

base:
```
ok 4 - GUARD: configure either takes the default-port endpoint or refuses it naming the endpoint (got: configured)
not ok 5 - archive.to_s3 through an endpoint configured with its default port is not refused by the store (got: archive.to_s3: PUT of evt failed: HTTP 403 <?xml version="1.0" encoding="UTF-8"?>
# <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided. Check your key and signing metho)
# Failed test 5: "archive.to_s3 through an endpoint configured with its default port is not refused by the store (got: archive.to_s3: PUT of evt failed: HTTP 403 <?xml version="1.0" encoding="UTF-8"?>
# <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided. Check your key and signing metho)"
not ok 6 - its object lands at the key, as it does through the endpoint spelled without the port
# Failed test 6: "its object lands at the key, as it does through the endpoint spelled without the port"
# Looks like you failed 2 tests of 6
```
head:
```
ok 4 - GUARD: configure either takes the default-port endpoint or refuses it naming the endpoint (got: configured)
not ok 5 - archive.to_s3 through an endpoint configured with its default port is not refused by the store (got: archive.to_s3: PUT of evt failed: HTTP 403 <?xml version="1.0" encoding="UTF-8"?>
# <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided. Check your key and signing metho)
# Failed test 5: "archive.to_s3 through an endpoint configured with its default port is not refused by the store (got: archive.to_s3: PUT of evt failed: HTTP 403 <?xml version="1.0" encoding="UTF-8"?>
# <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided. Check your key and signing metho)"
not ok 6 - its object lands at the key, as it does through the endpoint spelled without the port
# Failed test 6: "its object lands at the key, as it does through the endpoint spelled without the port"
# Looks like you failed 2 tests of 6
```

</details>

### Seed witness

- S1 in `pgpm_archive/install.sql` (archive_endpoint_trailing_slash_kept): **found**

### Coverage and budget

- P1: 15 of 15 units read (1.00)
- surface: 6 file(s), 15 unit(s) in the ledger (touched units, their callers, touched files)
- budget: round 2: P1 ~116k tokens (15/15 units), claims verifier ~67k (live, with a TCP relay for the default-port case); acceptance: F19-02 rebuilt, round 1's V-01 and V-02, each restored only by its own mutation; seed caught; BLOCKED on the closing claim: partial, V-01 (round 2): an endpoint spelling the scheme's default port signs host:80 while libcurl omits it, 403 on every PUT; a percent-encoded dot segment is accepted; the fixer's round 3 canonicalises the default port, refuses %2E%2E and restates the refusal list as the limit (last round)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
