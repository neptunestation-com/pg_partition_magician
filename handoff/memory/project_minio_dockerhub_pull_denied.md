---
name: minio-dockerhub-pull-denied
description: "minio/minio AND minio/mc: Docker Hub pull denied 2026-09-13 (moved to quay.io, PR #373); quay.io ALSO closed to anonymous pulls 2026-09-24 (issue #436, unfixed). Local archive runs pass only from the image cache"
metadata: 
  node_type: memory
  type: project
  originSessionId: e50e8cc1-f284-4544-aaec-cc7bc866c442
  modified: 2026-09-24T23:51:34.500Z
---

Two separate references broke the same way on 2026-09-13, Docker Hub returning `pull access
denied, repository does not exist or may require 'docker login'` for an unauthenticated pull, not
a per-runner rate limit (reproduced locally with plain `docker pull`, and on fresh CI runners
across reruns):

- `docker-compose.yml`'s `minio` service (`image: minio/minio`, the `archive` profile's S3
  stand-in).
- `test.sh:364`'s one-off `docker run ... minio/mc` (bucket setup, no compose service of its own).

The second one was caught only after the first fix (`minio/minio` -> `quay.io/minio/minio`) landed
and PR #373 itself hit a FRESH CI runner: local verification of the first fix had passed only
because `minio/mc` was already cached locally, masking that it was equally broken.

**Fix:** both switched to `quay.io/minio/*` (MinIO's own maintained mirror, pulls anonymously
fine). PR #373 (`fix/minio-quay-registry` -> `main`), MERGED 2026-09-13. Verified on fresh CI
runners: `pgpm_archive against MinIO / PG17` and `data-coupled lock and work guards / PG17`
(which also runs `./test.sh discriminate`, exercising the archive memory-blowup guards) both green.

**UPDATE 2026-09-24: quay.io closed too.** The archive job on PR #435 failed twice on
`minio Error unauthorized: access to the requested resource is not authorized`. quay.io's public API
returns 401 "Requires authentication" for `repository/minio/minio` and its tags, `docker manifest
inspect quay.io/minio/minio:latest` says `no such manifest`, and Docker Hub's `minio/minio` tag API
is 404. So no anonymous registry serves MinIO any more. Filed as issue #436 with three options
(pin a public mirror by digest, vendor the MinIO binary into `pgpm_test:17-archive`, or authenticate
the pull). Fix PR #437 MERGED 2026-09-24 (9f26d7d), #436 CLOSED: `bitnamilegacy/minio:2025.7.23-debian-12-r5`
pinned by multi-arch index digest, no `command:` (its entrypoint starts the server), and the `mc`
step replaced by `curlimages/curl --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin -X PUT`
plus a GET read-back that must be 200 (404 = missing bucket, so it is a witness). Local
`./test.sh archive` and `./test.sh discriminate` PASS against it. Caveat learned on the way: on this
Mac `docker manifest inspect` fails for EVERY image (alpine included), so never use it as evidence;
check registries with an anonymous bearer token via curl instead.

**Second lesson from #437 (2026-09-24): the Bitnami entrypoint must be BYPASSED.** With the image
alone, the archive job failed twice on CI (tests/archive/db/08: 0 ledger rows) while passing locally
three times. Reason, found only after adding a `pgpm.log skip_*/fail_*` dump to `run_archive` on
failure: `HTTP 503 XMinioServerNotInitialized`. Bitnami's setup.sh starts a TEMPORARY MinIO server
to provision `mc`, stops it, then execs the real one; every readiness signal (and test 04's uploads)
was served by the temporary server on the slow runner, and test 08 hit the real one mid-init. Fix:
`entrypoint: ["minio"]`, `command: server /bitnami/minio/data --address :9000` (image uid 1001, its
declared volume), and poll `/minio/health/cluster` (readiness; 503 until initialized) rather than
`/minio/health/live`. General rule for third-party test images: a handover inside an entrypoint makes
every health check a witness of the wrong process; run the binary directly.

**How to apply:** if a `minio/*` pull fails in CI, check #436 first; it is a registry break, not the
diff, and a rerun will not clear it. If an archive test fails on CI with a `503 XMinioServerNotInitialized`
in the track's `pgpm.log` dump, the server is mid-handover: check that the entrypoint bypass is still in
place before suspecting the diff. Before the fix lands, expect the archive check red on any PR
touching `pgpm_core/install.sql`, `pgpm_archive/` or the archive tests. And when verifying a registry
swap locally, treat a locally-cached image as unverified for that specific image until confirmed
on a clean CI runner -- this is exactly how the `minio/mc` half of this break was missed initially.
See [[project_restore_fk_lock_flaky]] for a genuinely-flaky (vs. this genuinely-broken) `perf`-track
failure found the same day -- similar symptom ("perf/archive job failed"), opposite fix (rerun vs.
an actual code change).
