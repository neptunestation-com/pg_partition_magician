---
name: project-test-per-file-db-isolation-mothballed
description: "The test/per-file-database-isolation branch was mothballed -- cost/time tradeoff, not abandoned for a technical flaw"
metadata: 
  node_type: memory
  type: project
  originSessionId: c67c06b5-62f4-4da1-93f9-11b179177c83
  modified: 2026-08-25T17:08:30.517Z
---

The `test/per-file-database-isolation` branch (visible in `git branch -vv`, last commit around 7162cb2)
was an earlier Claude session's work, per the user (2026-08-25), giving each pgTAP test file its own
fully isolated database rather than sharing `postgres` for the pg_cron-dependent tests (31, 78). The
user's recollection: it was mothballed as a toss-up, not a failure -- full per-file isolation is nicer
to reason about, but burns wall-clock time spinning up too many containers/databases during the test
run. Current `test.sh` deliberately keeps tests 31 and 78 running against the shared `postgres`
database instead, because pg_cron can only create its extension in the database named by
`cron.database_name`.

**Why this matters**: that shared-database design is the root cause of a class of benign noise --
e.g., the standing `pgpm_detach` cron job (retire()'s dispatch mechanism, issue #268) can fire
asynchronously against a stale target after a later test/channel run has dropped and recreated a
fixture table (`messages`) fresh, producing a real `ERROR: relation ... is not a partition` in the
Postgres server log that never propagates to `test.sh`'s exit code (cron failures are logged, not
surfaced to the dispatching script). Observed directly in a `./test.sh ci` run's container logs,
confirmed non-blocking (`ci: PASS` in the same run).

**How to apply**: don't re-propose full per-file database isolation as a fix for this or similar
cron/shared-state noise without weighing the wall-clock cost against the reasoning benefit -- that
tradeoff was already made once. If this noise needs root-causing for real (not just plausibly
explained), the way in is `cron.job_run_details` timing correlated against `test.sh`'s per-channel
sequencing, not a redesign of test isolation.
