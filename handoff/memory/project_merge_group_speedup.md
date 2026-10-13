---
name: project_merge_group_speedup
description: Merge-group speed-up DONE 2026-10-07: all four options MERGED (#1042 17:34Z, #1043 18:51Z, #1044 19:14Z, #1045 19:32Z; main 5cf4fb2): channel matrix, image cache (key = hash(Dockerfile+compose)+ISO week, composite actions), 6 heavy-first discriminate shards, 4-worker pgTAP runner (PGPM_JOBS); measured before/after; the pg_stat_activity per-transaction snapshot lesson (tests/269); lost-runner jobs after a GitHub incident
metadata:
  type: project
---

After the pass-9 fix phase the user asked why a PR took 108 min to land. Answer (measured on the pr-1029 merge group): the queue's per-merge
cost is one merge group ~30 min (enqueue->merge median 32), serial because a PR stacked on a queued head is dropped; 108 is turn->merge
including a batch position's wait; the Test Suite matrix job (24 min: 80 s image build + 3 channels x 450 s) was the group's critical path,
then discriminate shard 4/4 (17 min). The user chose all four options in order.

| option | branch / PR | state 2026-10-07 15:20Z |
|---|---|---|
| 1 channel matrix (12 jobs: pg x channel) | ci/test-suite-channel-matrix, PR #1042 | all checks green; jobs 8-10 min each (was 24) |
| 2 image cache (scripts/image_build_key.sh key = hash(Dockerfile+compose)+ISO week; LABEL org.pg_partition_magician.build_key; test.sh build_image skips on match; composite actions .github/actions/test-image-restore + test-image-save; Dockerfile drops postgresql-server-dev after the builds: image 1730 -> 671 MB) | ci/test-image-cache, PR #1043 | local proof OK (build then "not rebuilding"); CI: Lint summary FAILED with an empty log during the GitHub outage (all Lint jobs green): re-run it |
| 3 discriminate: MUTATION_COST in mutate.py (22 heavy, measured), --list heaviest first, stale name refused; perf.yml 6 shards + cached pgpm_test:17 and archive images | ci/discriminate-shard-balance, PR #1044, STACKED on #1043 (rebased e1c8fb1) | force-push rejected by the outage; its first run failed only because the actions were missing (branched from main); simulated max shard 17 -> ~11 min |
| 4 parallel pgTAP files (prove_one, PGPM_JOBS default 4, ordered record, cron files serial on postgres) | test/parallel-file-runner, PR #1045 | proof: 4 workers 97/107/113/93 s vs serial 318 s, 272/272 every run; pushed after the outage |

Landing order: #1042, then #1043, then #1044 (stacked), then option 4 (independent, test.sh only; #1043 also edits test.sh in another region).
The user has NOT said to merge these; ask before enqueueing (feedback_dont_assume_standing_merge_authorization). Record PR #1041 was enqueued at
the user's request ("merge #1041") and was in its merge group when the outage began. Scratch: fix9/opt4/*.log, fix9/opt2_local_proof.log,
fix9/disc_timing.tsv (per-mutation seconds), watch_github.sh.

**2026-10-07 16:30Z measured on CI:** #1041 MERGED 16:09Z (main 7989d9d) after a hand dequeue/enqueue (its first group lost only the Perf summary job to the GitHub outage; land.sh treats a summary-only failure as unknown: a flake signature for it is a #1035-class lesson). #1042 green (matrix jobs 8-10 min). #1043 green; first run missed the cache, built under key v1-efb222249c920040-2026-W41 and saved it (next run on the key loads). #1044 green (stacked on #1043): discriminate shards 8-11 min (was 12-17), perf shards 4-6. #1045: PG15/16/17 jobs 9-11 min (was 21-24, channels still serial per job); PG18 failed tests/269's 5 s owner-gone probe under load; second commit widens it to 30 s keyed by (pid, backend_start); PG18 x4 passes locally; CI re-run pending. All four PRs await the user's word to enqueue (order: #1042, #1043, #1044, #1045).

**#1045 lesson (2026-10-07 17:00Z):** the PG18/PG16 failures were tests/269's owner-gone poll reading pg_stat_activity inside ONE function call without pg_stat_clear_snapshot(): the view is snapshotted per transaction, so the loop never saw the backend leave and burned its whole budget whenever the backend had not already exited before the first read (which four parallel files sometimes cause). Every other polling file in tests/ clears the snapshot. Fixed in commit 3 of #1045 (clear per iteration, owner = (pid, backend_start)); PG16/PG18 x4 pass locally; third CI run pending. Worth a sentence in CLAUDE.md's probe rules ("pg_stat_activity is snapshotted per transaction: clear it per poll") when the record of this work is written.

**DONE 2026-10-07 19:32Z:** all four merged in order via land.sh --batch (#1043 rebased onto #1042 by hand: both edited test.yml's job block; #1044 re-based onto the rewritten #1043). Stops: #1043's head run had five matrix jobs + lock-trace fail with NO failing step and NO log (lost runners after the GitHub incident; `gh run rerun --failed` fixed it); #1043 also left the queue once (known flake, auto re-enqueued). Measured with everything stacked: Test Suite matrix jobs 3-4 min (from 24), discriminate shards 8-11 (from 12-17), merge group enqueue->merge 18 min for #1045 (from 32). Cache proven: "Cache hit ... Cache restored", docker load, label witness, no build. Local branches deleted. Follow-ups not done: flake_check.sh signature for a summary-only failure (merge-group runs cannot be retried: dequeue + enqueue by hand instead) and for logless lost-runner jobs; CLAUDE.md probe rule about pg_stat_activity snapshots; the fix-phase skill's brief for the MinIO entrypoint and the gate.

**Decision 2026-10-07 (user):** NO reduced pull-request matrix. About 38 jobs against the 20-runner cap is correct, just blocking; every PR head keeps running everything the merge group runs. Do not propose trimming the PR-head matrix again; the per-merge time reduction (32 -> 18 min) is the accepted gain.
