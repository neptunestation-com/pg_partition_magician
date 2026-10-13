# P1 null results: PR #1301 (archive.configure endpoint canonical form)

One claim written (P1-01, Tier 3): the review tree's `archive._s3_endpoint_canonical` is `select p_endpoint`
(the identity), so nothing the body, CHANGELOG or README says about trailing slashes is kept, and the tree's own
`tests/archive/db/53` fails tests 7-9, 11, 12, 19, 21-24 there (the exact set the body lists for the mutant
`archive_endpoint_trailing_slash_kept`). Note for the coordinator: `pgpm_archive/install.sql` in the review tree
carries an mtime (13:40:32) later than every other file in the diff (12:57:25), which looks like a mutant having
been written into the tree after it was built; I reviewed the tree as given, as the brief directs. Everything
below was probed on a scratch database whose helper was replaced (in that database only, never in the tree) by
`rtrim(p_endpoint, '/')`, so the rest of the change was tested on its own merits.

## Lens: fresh surface

- `archive.configure`: the refusal runs after the null-argument, managed, part_bytes and fetch_rows checks and
  before the insert; a refused endpoint leaves an existing row untouched (on conflict never reached). Probed 25
  spellings: `minio:9000`, `ftp://minio:9000`, `http://minio:9000/?x=1`, `http://minio:9000#f`, `http:///`,
  `http://`, `HTTP://`, `Http://`, leading/trailing space, `http://minio:9000/ `, `/?`, `/#`, `/a?`, `''` all
  REFUSED naming `p_endpoint` and quoting the value as typed; `http://minio:9000//` -> `http://minio:9000`,
  `http://minio:9000/storage/v1/s3/` -> prefix kept and slash dropped, `http://minio:9000/storage//v1//` ->
  `.../storage//v1` (inner slashes kept), `https://`, no port, `[::1]`, null all TAKEN. Held.
- Both signers: canonical form applied before `v_host`, `v_uri` and `v_url` are built, so the Host header, the
  canonical request and the URL agree; a direct call spelled `http://minio:9000/` on `archive.s3_signed_request`
  and on `archive.s3_signed_request_bytea` returned 200 at the key the unslashed export wrote (repro tests 13,
  14 with the stripping helper). A row stored with the slash by hand (older install) exports through the
  signers' strip (test 53 section E with the stripping helper). Held.
- Every `cfg.endpoint` reader in `pgpm_archive/install.sql` (`_encode_upload_ndjson_single`,
  `_encode_upload_parquet`, `to_s3` x8, `to_s3_parquet`) hands it to a signer or to `_s3_abort_uploads_at`,
  which calls a signer; no reader builds a URL itself. No reader of `archive.config.endpoint` outside
  `install.sql` in `scripts/` or `bench/` (grep). The body's "every request is built by one of the two signers"
  holds.
- Prefix (PR #1298) is untouched here; `configure` still stores `p_prefix` verbatim. No coupling beyond the row.
- `bench/archive_configure_endpoint.sh`: builds fixtures, core and the install under test with each exit read,
  counts assertions, names a failed LIVENESS line, exits 1 on 0 ran; `test.sh` runs it on `pgpm_perf377`, a
  name no other guard uses. Read; nothing to reproduce.
- `tests/archive/db/53`: each stored value asserted by identity; export objects asserted by the two rows they
  hold; DELETE 204 then GET 404 before the slashed try; refusal tests pin `%p_endpoint%`, which no other
  configure error names. Run on the tree: 10 failures, all defect checks, every LIVENESS held, so the file
  discriminates the helper's identity form as the body says it does.

## Lens: operator error

- A trailing slash with a path prefix, three trailing slashes, a slash then a space (refused: the space is not
  stripped, and the message shows it quoted), uppercase scheme (refused; the signers' regexes are
  case-sensitive too, so taking it would fail at the request): all loud with the remedy in the message. Held.
- An already-configured slashed endpoint on an upgraded install: with the stripping helper the next request
  works unchanged (no re-configure needed), which is what the README says; on this tree it fails HTTP 400 as
  before (P1-01).

## Hypotheses (no reproduction)

- `http://user:pw@host:9000`, `http://host:9000:` and `http://host:9000\n` (a literal backslash-n) pass the
  refusal and fail at the first request; exotic, loud, not a defect by the rubric.
- An uppercase scheme is refused rather than lower-cased; consistent with the signers, arguably unfriendly.
