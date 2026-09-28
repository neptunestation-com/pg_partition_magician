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
  else
    echo "job $j: UNKNOWN failure, not a flake this script knows; do not retry"
    rc=1
  fi
done
exit $rc
