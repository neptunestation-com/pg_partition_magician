## Defect (#1269)

`archive.configure` stored `p_endpoint` exactly as given, and both signers (`archive.s3_signed_request`,
`archive.s3_signed_request_bytea`) address an object as `p_endpoint || '/' || bucket || '/' || key` (and sign
the same path). An endpoint spelled with a trailing slash (`http://minio:9000/`) therefore addressed
`//<bucket>/<key>`, MinIO answered HTTP 400 to every PUT, and every export and every tick's chunk through it
failed after the read. Loud, nothing lost. `configure` checked nothing about the endpoint, although it refuses a
`p_part_bytes` or `p_fetch_rows` that cannot work (#594, #636).

## Fix

One helper, `archive._s3_endpoint_canonical(text)`: the endpoint without its trailing slashes (null stays
null). It is used at every site an endpoint enters a URL or is stored:

- `archive.configure` stores the endpoint through it, so `archive.config.endpoint` never ends in `/` for a row
  configure writes.
- Both signers pass the `p_endpoint` they are handed through it before building the host, the canonical URI and
  the URL. Every request the module sends is built by one of the two signers (every `cfg.endpoint` reader in
  `pgpm_archive/install.sql` hands it to a signer or to `archive._s3_abort_uploads_at`, which calls a signer), so
  a row stored with a slash before this release, or by hand, and a direct signer call spelled with one, address
  the same object as the endpoint spelled without.

And `archive.configure` refuses, naming `p_endpoint`, before it writes anything, an endpoint whose canonical
form is not `^https?://<host>[/<path>]` with no query string, fragment or whitespace: no scheme, a scheme other
than http/https, no host, `?...` or `#...`. Those were stored and found out only at the first request, since the
signers take the host from `http(s)://` up to the first `/`.

What it deliberately does not do: refuse an endpoint with a path. The brief suggested that, but a path prefix is
a documented, tested shape (Supabase Storage's `https://<ref>.supabase.co/storage/v1/s3`, the signers' own "the
endpoint may carry a path prefix", CHANGELOG's Storage run), so the path is kept and only its trailing slash
dropped. A null endpoint (AWS S3, virtual-hosted) is unchanged. A row stored by an older install with an
endpoint the new refusal would reject (no scheme, a query string) is not rewritten and stays loud at the store,
as before.

## Acceptance

- The issue's reproduction (F19-02's `repro.verified.sql`, archive harness): fails 2/6 on the base (tests 5 and
  6: HTTP 400 at `//archive-test-bucket/...`, no object), passes 6/6 on this head, and fails 5 and 6 again
  against the mutant `archive_endpoint_trailing_slash_kept`. On this head the reproduction's GUARD line reads
  `configured`: the fix takes the slashed endpoint (normalised), which the rebuilt reproduction admits.
- `tests/archive/db/53_configure_endpoint_canonical_test.sql` (25 assertions): the stored endpoint by value
  (one slash, three slashes, a path prefix with a slash, null), an export through the slashed endpoint landing
  both rows at the key (by identity), five refusals by name (no scheme, `ftp://`, a query string, a fragment, no
  host) with the stored row unchanged afterwards, and a row stored with a slash by hand plus a direct call to
  each signer spelled with a slash reaching the key. Each key cleared and witnessed absent first.
- Guard `bench/archive_configure_endpoint.sh` (run by `run_archive`, database `pgpm_perf377`) runs test 53
  against an arbitrary archive install; mutations:
  - `archive_endpoint_trailing_slash_kept` (the helper returns its input): the guard fails tests 7-9, 11, 12,
    19, 21-24, no LIVENESS line.
  - `archive_endpoint_unrefused` (configure's refusal becomes `if false`): the guard fails tests 14-19, no
    LIVENESS line.

Local proof: `./test.sh archive` PASS (gated, test 53 and the guard included), `./test.sh 15 --channel=psql`
PASS (gated); `check_quoted_splices.py` (and `--selftest`), `check_archive_object_keys.py`,
`check_archive_child_by_oid.py`, `check_track_filters.py`, `check_living_docs.sh` PASS; every mutation builds;
`bash -n test.sh`; shellcheck 0.11.0 clean on the new guard; markdownlint 0.13.0 clean on CHANGELOG.md and
pgpm_archive/README.md (which now documents the endpoint's spelling).

Closes #1269

🤖 Generated with [Claude Code](https://claude.com/claude-code)

