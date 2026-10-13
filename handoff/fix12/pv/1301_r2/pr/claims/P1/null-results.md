# P1 null results, PR #1301 round 2

Harness: pgpm_prv-archive, fresh databases prv_p1_1301r2_{a,b,c,d} built from the review tree's
tests/archive/fixtures.sql, pgpm_core/install.sql, pgpm_archive/install.sql (--single-transaction), all dropped.

## Fresh surface

- `archive._s3_endpoint_canonical` (install.sql:146-149): its body in this tree is `select p_endpoint;`, the identity.
  Ran tests/archive/db/53 against the tree: 10 of 46 fail (7-9, 11, 12, 19, 21-24; every LIVENESS line passes), the
  exact set the PR body attributes to the mutant `archive_endpoint_trailing_slash_kept`. The tree's install.sql mtime
  (14:33:41) is 39 minutes later than every other file of the tree (13:54:17), so this looks like a mutant left in
  place by a discriminate run rather than the PR's intended head, but the tree is what I review: claim P1-01.
- The refusals (configure lines 211-232), which do not depend on the helper, probed on this tree (prv_p1_1301r2_b):
  no scheme, `ftp://`, `HTTP://` (case-sensitive, matches the signers' own case-sensitive host regexes), query string,
  fragment, `http:///`, leading or trailing whitespace: all refused naming p_endpoint. Credentials: `http://u:s3cr3t@h`,
  `http://u@h`, `u:s3cr3t@h` (no scheme), `HTTP://u:s3cr3t@h` (uppercase scheme): refused as credentials first, so the
  password is never echoed by the later refusals. Dot segments: `/.`, `/./`, `/storage/../s3/`, `//s3` refused;
  `/a/..b` (a legitimate segment) and `/a@b` (an @ in the path, not the authority) accepted, correctly. IPv6
  `http://[::1]:9000` accepted. Null endpoint stays null through every check (`if null` is not taken).
- With a slash-dropping helper swapped into a scratch database only (prv_p1_1301r2_d, to check the interaction the tree
  cannot show): `/s3/.//` and `/./` are refused after the trailing slashes go (`/s3/.`, `/.`), `/s3//` and `////` store
  as `/s3` and the bare host, `/storage/v1/s3/` keeps its prefix. The order (canonicalise, then userinfo, shape, dot
  segments) holds.
- Bucket refusal (line 211): `/b`, `b/`, `b/sub`, `''`, `.`, `..`, a tab inside: refused naming p_bucket; `my.bucket-1`,
  `Bucket_X`, `a\b` taken (store-side validity is not pgpm's to judge). Runs before the insert, after the null
  refusal and the part_bytes/fetch_rows ones; a refused call leaves the stored row untouched (tests 19, 33, 42).
- Every reader of `archive.config.endpoint` in the module (lines 3149, 3152, 3214, 3723, 3737, 3747, 3763, 3777,
  3787, 3799, 3806, 3847) hands it to a signer or to `archive._s3_abort_uploads_at`, whose two requests go through
  `archive.s3_signed_request`: the body's "every request is built by one of the two signers" holds. Both signers
  assign the canonical form to `p_endpoint` before the host, URI and URL are built, so host, canonical request and
  wire URL cannot drift apart (the sites at 415-419 and 490-494 all read the reassigned parameter).
- `archive.to_s3` re-checks part_bytes and fetch_rows from the row but not the endpoint's shape; the body says an old
  row with a bad endpoint "stays loud at the store, as before", and it does (a no-scheme row makes a URL the http
  extension rejects by name).
- test.sh: the guard runs in the archive track with database pgpm_perf377, a name used nowhere else in the tree.
  bench/archive_configure_endpoint.sh: unchanged from round 1 except its header (names five mutations; I cannot
  read bench/mutations to check they exist); its setup steps each read their exit, pg_prove's count and the
  LIVENESS grep separate a fixture failure from a catch.
- CHANGELOG and pgpm_archive/README.md describe the refusals as the code implements them (every listed shape probed
  above); their "trailing slash is dropped" sentence is false on this tree for the P1-01 reason only.

## Operator error

- An endpoint pasted with a trailing slash, three slashes, a path prefix with a slash: on this tree all stored
  verbatim (P1-01); with a working helper, all canonical.
- Credentials pasted into the URL (the natural mistake the V-01 sibling named): refused without echoing the password
  in every spelling I tried, including no scheme and an uppercase scheme.
- A key path put in the bucket (`archive-test-bucket/sub`) and a bucket with a leading slash: refused naming
  p_bucket and pointing at p_prefix. The remedy as typed from each message (the bare bucket, the URL without
  credentials) configures a table whose export lands rows 1 and 2 by identity (tests 34-35, 44-45 pass on this tree).
- An older row holding a slashed endpoint: on this tree still HTTP 400 at //bucket/key through to_s3 and both
  signers (P1-01 checks 9-11); with the slash-dropping helper, lands.

## Hypotheses (no claim written)

- `http://:9000` (a port, no host) is accepted by configure's shape regex (`[^/?#[:space:]]+` matches `:9000`), though
  the body says a value with no host is refused; the first request then fails at once with the http extension's
  "URL rejected: No host part in the URL". Loud, one step later, clearly named: below the bar for a claim, recorded here.
- `http://user:p/ss@minio:9000` (a password holding an unencoded `/`) slips past the userinfo check (`^[^/]*@`) and the
  shape regex (host `user:p`, path `/ss@minio:9000`), is stored, and the first request fails with "Port number was not
  a decimal number". Not a valid URL to begin with and the failure does not echo the password; recorded, not claimed.
- `http://minio:9000?a@b` is refused as "credentials" rather than as a query string (the userinfo check runs first and
  `^[^/]*@` reaches the `@` in the query). Refused either way, naming p_endpoint; the message is the only thing off.
- A percent-encoded dot segment (`/%2e%2e/s3`) is accepted; whether a store resolves it is store-specific and I did not
  probe it against MinIO.
