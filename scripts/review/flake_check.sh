#!/usr/bin/env bash
# flake_check.sh <run_id> [--repo owner/name]
#
# Decide whether a failed workflow run is one of the KNOWN CI flakes, so land.sh may retry it once. Exit
# 0 when every failed job of the run's latest attempt matches a signature, 1 when any failed job is
# something else, 2 when the run has no failed non-summary job. One line per failed job says which.
#
# The signatures are deliberately narrow, so a real regression is never retried:
#   lock_guard_probe   bench/regrain_outgoing_fk_lock.sh's probe assertion, with its liveness witness
#                      PASSED and no other FAIL line in the job (issue #556: the count of 50 ms timeouts
#                      cannot discriminate on a loaded runner; five occurrences, always exactly 20)
#   registry_quota     a third-party image pull refused with toomanyrequests / Data limit exceeded, and
#                      no test output at all (the job never ran a test)
#   regrain_perf_discriminate  a discriminate shard whose ONLY non-discriminating guard is bench/regrain_perf.sh
#                      against regrain_no_delta_analyze (issue #871: the delta scan counter is read before the
#                      statistics collector flushes it on a loaded runner, so the mutant's seq scan reads as 0)
# The summary jobs (Perf summary, Test Summary, Lint summary) fail whenever a job they need failed;
# their failure is derived, so they are skipped, but at least one REAL failed job must match.
#
# To add a signature: a name, a regex the job log must match, and the conditions under which the match
# is NOT a flake. Then add the flake to the record of the pass that met it; a signature nobody can point
# at an issue for is a way of hiding a regression.
set -uo pipefail
RUN=${1:?run id}; shift
REPO=""
while [ $# -gt 0 ]; do case "$1" in --repo) REPO=$2; shift 2;; *) echo "unknown option $1"; exit 3;; esac; done
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# runner_not_acquired: GitHub never gave the job a hosted runner ("The job was not acquired by Runner of
# type hosted even after multiple attempts" in the job's annotations; the job is cancelled or failed with
# no step run at all). Every non-success job of the latest attempt must carry that annotation, the
# summary jobs included when they are the only ones: nothing of ours ran, so nothing of ours failed.
# Met on 2026-10-05 during the lever phase before pass 9 (tracking issue #966) under GitHub's incident
# "delays in assigning GitHub-hosted runners"; the record of that phase names it.
# A summary job's failure is derived from the jobs it needs, so it is judged only when it is the sole
# non-success job of the attempt (the perf summary itself can be the starved one).
nonsuccess=$(gh run view "$RUN" --repo "$REPO" --json jobs \
        --jq '.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped") | select(.name | test("summary"; "i") | not) | .databaseId')
[ -n "$nonsuccess" ] || nonsuccess=$(gh run view "$RUN" --repo "$REPO" --json jobs \
        --jq '.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped") | .databaseId')
if [ -n "$nonsuccess" ]; then
  all_runner=1
  for j in $nonsuccess; do
    ann=$(gh api "repos/$REPO/check-runs/$j/annotations" --jq '.[].message' 2>/dev/null)
    grep -q "was not acquired by Runner of type hosted" <<<"$ann" || { all_runner=0; break; }
  done
  if [ "$all_runner" = 1 ]; then
    echo "run $RUN: known flake runner_not_acquired (GitHub assigned no hosted runner to $(wc -w <<<"$nonsuccess" | tr -d ' ') job(s); nothing of ours ran)"
    exit 0
  fi
fi

jobs=$(gh run view "$RUN" --repo "$REPO" --json jobs \
        --jq '.jobs[] | select(.conclusion=="failure") | select(.name | test("summary"; "i") | not) | .databaseId')
[ -n "$jobs" ] || { echo "run $RUN: no failed non-summary job in the latest attempt"; exit 2; }
rc=0
for j in $jobs; do
  log=$(gh api "repos/$REPO/actions/jobs/$j/logs" 2>/dev/null | sed 's/^[^ ]* //')
  other_fails=$(grep -E "^FAIL " <<<"$log" | grep -vc "writes to the MANAGED PARENT are not blocked")
  if grep -qE "^FAIL +writes to the MANAGED PARENT are not blocked +got [0-9]+, want 0" <<<"$log" \
     && [ "$other_fails" = "0" ] \
     && grep -qE "^PASS +the probe overlapped a running swap" <<<"$log"; then
    echo "job $j: known flake lock_guard_probe (regrain_outgoing_fk_lock's probe timed out under load; liveness passed; #556)"
  elif grep -qE "toomanyrequests|Data limit exceeded" <<<"$log" && ! grep -qE "^FAIL |not ok" <<<"$log"; then
    echo "job $j: known flake registry_quota (third-party image pull refused; no test ran)"
  elif [ "$(grep -cE '^FAIL +bench/[^ ]+ PASSED against its own defect' <<<"$log")" = "1" ] \
     && grep -qE '^FAIL +bench/regrain_perf\.sh PASSED against its own defect' <<<"$log" \
     && grep -qE '^--- regrain_no_delta_analyze$' <<<"$log"; then
    echo "job $j: known flake regrain_perf_discriminate (regrain_perf.sh's scan counter read before the collector flushed; the only non-discriminating guard in the shard; #871)"
  else
    echo "job $j: UNKNOWN failure, not a flake this script knows; do not retry"
    rc=1
  fi
done
exit $rc
