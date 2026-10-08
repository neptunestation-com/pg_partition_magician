#!/usr/bin/env bash
# flake_check.sh <run_id> [--repo owner/name] [--attempt N]
#
# Decide whether a failed workflow run is one of the KNOWN CI flakes, so land.sh may retry it once. Exit
# 0 when every failed job of the run's latest attempt (or of --attempt N, for checking a signature against
# an old attempt) matches a signature, 1 when any failed job is something else, 2 when the run has no
# failed non-summary job and did not itself conclude failure. One line per failed job says which.
#
# The signatures are deliberately narrow, so a real regression is never retried:
#   lock_guard_probe   bench/regrain_outgoing_fk_lock.sh's probe assertion, with its liveness witness
#                      PASSED and no other FAIL line in the job (issue #556: the count of 50 ms timeouts
#                      cannot discriminate on a loaded runner; five occurrences, always exactly 20); and,
#                      since 2026-10-08, bench/restore_fk_lock.sh's identical assertion with ITS two
#                      liveness witnesses PASSED ("the probe was writing before the restore began",
#                      "attempts overlapped the restore's own window") and "the FK was actually re-added"
#                      PASSED (issue #1066: 1 of 66 overlapping writes timed out in #1063's merge group)
#   registry_quota     a third-party image pull refused with toomanyrequests / Data limit exceeded, and
#                      no test output at all (the job never ran a test)
#   regrain_perf_discriminate  a discriminate shard whose ONLY non-discriminating guard is bench/regrain_perf.sh
#                      against regrain_no_delta_analyze (issue #871: the delta scan counter is read before the
#                      statistics collector flushes it on a loaded runner, so the mutant's seq scan reads as 0)
#   runner_not_acquired  GitHub never gave the job a hosted runner: every non-success non-summary job of the
#                      attempt carries the annotation "was not acquired by Runner of type hosted" or "was not
#                      started because it repeatedly failed to be acquired", and no step of ours ran (the
#                      lever phase before pass 9, 2026-10-05, under GitHub's incident "delays in assigning
#                      GitHub-hosted runners"; tracking issue #966)
#   lost_runner        the same loss without the annotation: every non-success non-summary job of the attempt
#                      has NO steps at all (conclusion failure or cancelled with an empty step list and an
#                      empty or BlobNotFound log, or still queued with no conclusion while the run itself has
#                      concluded). Nothing of ours ran, so nothing of ours failed; `gh run rerun --failed`
#                      restarts them (2026-10-07, after GitHub's incident of that afternoon: #1043's head run
#                      had five matrix jobs and the lock-trace job fail this way, and #1044's perf run had
#                      two discriminate shards queued for good while its summary failed; issue #1048)
#   summary_only       the run concluded failure (or cancelled) while NO non-summary job of the attempt is
#                      anything other than success or skipped: the only failure is a summary job's, or
#                      GitHub recorded no failed job at all (#1041's merge group on 2026-10-07 lost its Perf
#                      summary job to the incident and concluded failure with seven green jobs; #1043's Lint
#                      run failed its summary with an empty log while every Lint job was green). Nothing of
#                      ours failed. A PR head is rerun (--failed reruns the summary); a merge group cannot be
#                      rerun, and land.sh re-enqueues it (issue #1048)
# The summary jobs (Perf summary, Test Summary, Lint summary) fail whenever a job they need failed;
# their failure is derived, so they are skipped, but at least one REAL failed job must match, except under
# summary_only, where the point is that there is none.
#
# To add a signature: a name, the condition the run must meet, and the conditions under which the match
# is NOT a flake. Then add the flake to the record of the pass that met it; a signature nobody can point
# at an issue for is a way of hiding a regression.
set -uo pipefail
RUN=${1:?run id}; shift
REPO=""; ATTEMPT=""
while [ $# -gt 0 ]; do case "$1" in --repo) REPO=$2; shift 2;; --attempt) ATTEMPT=$2; shift 2;; *) echo "unknown option $1"; exit 3;; esac; done
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

run_conclusion=$(gh api "repos/$REPO/actions/runs/$RUN" --jq '.conclusion // "null"' 2>/dev/null)
if [ -n "$ATTEMPT" ]; then
  jobs_url="repos/$REPO/actions/runs/$RUN/attempts/$ATTEMPT/jobs?per_page=100"
else
  jobs_url="repos/$REPO/actions/runs/$RUN/jobs?per_page=100"
fi
# one line per job: id, status, conclusion, step count, name (the name last: it may hold spaces)
alljobs=$(gh api "$jobs_url" --jq '.jobs[] | "\(.id)\t\(.status)\t\(.conclusion // "null")\t\(.steps | length)\t\(.name)"') || { echo "run $RUN: could not list its jobs"; exit 3; }
# the non-summary jobs that are not a completed success or skip
bad=$(awk -F'\t' 'tolower($5) !~ /summary/ && !($2 == "completed" && ($3 == "success" || $3 == "skipped"))' <<<"$alljobs")

if [ -z "$bad" ]; then
  case "$run_conclusion" in
    failure|cancelled|timed_out)
      echo "run $RUN: known flake summary_only (the run concluded $run_conclusion while every non-summary job is success or skipped; a summary job was lost or failed with nothing behind it; #1048)"
      exit 0;;
  esac
  echo "run $RUN: no failed non-summary job in the latest attempt (run conclusion $run_conclusion)"; exit 2
fi

# runner_not_acquired: every bad job carries the not-acquired annotation
all_runner=1
while IFS=$'\t' read -r j _status _concl _steps _name; do
  ann=$(gh api "repos/$REPO/check-runs/$j/annotations" --jq '.[].message' 2>/dev/null)
  grep -qE "was not acquired by Runner of type hosted|not started because it repeatedly failed to be acquired" <<<"$ann" || { all_runner=0; break; }
done <<<"$bad"
if [ "$all_runner" = 1 ]; then
  echo "run $RUN: known flake runner_not_acquired (GitHub assigned no hosted runner to $(wc -l <<<"$bad" | tr -d ' ') job(s); nothing of ours ran)"
  exit 0
fi

# lost_runner: every bad job has no steps at all
if ! awk -F'\t' '$4 != 0 { found = 1 } END { exit found ? 1 : 0 }' <<<"$bad"; then
  :
else
  echo "run $RUN: known flake lost_runner ($(wc -l <<<"$bad" | tr -d ' ') job(s) with no step run at all: $(awk -F'\t' '{printf "%s%s [%s/%s]", (NR>1?", ":""), $5, $2, $3}' <<<"$bad"); nothing of ours ran; #1048)"
  exit 0
fi

# anything else: a job that ran and failed must match a log signature; one that ran and was cancelled, or
# that never ran beside one that did, is not a flake this script knows
rc=0
while IFS=$'\t' read -r j status concl steps name; do
  if [ "$concl" != failure ] || [ "$steps" = 0 ]; then
    echo "job $j ($name): $status/$concl with $steps step(s) beside a job that ran; not a flake this script knows; do not retry"
    rc=1; continue
  fi
  log=$(gh api "repos/$REPO/actions/jobs/$j/logs" 2>/dev/null | sed 's/^[^ ]* //')
  other_fails=$(grep -E "^FAIL " <<<"$log" | grep -vc "writes to the MANAGED PARENT are not blocked")
  if grep -qE "^FAIL +writes to the MANAGED PARENT are not blocked +got [0-9]+, want 0" <<<"$log" \
     && [ "$other_fails" = "0" ] \
     && grep -qE "^PASS +the probe overlapped a running swap" <<<"$log"; then
    echo "job $j: known flake lock_guard_probe (regrain_outgoing_fk_lock's probe timed out under load; liveness passed; #556)"
  elif grep -qE "^FAIL +writes to the MANAGED PARENT are not blocked +got [0-9]+, want 0" <<<"$log" \
     && [ "$other_fails" = "0" ] \
     && grep -qE "^PASS +LIVENESS: the probe was writing before the restore began" <<<"$log" \
     && grep -qE "^PASS +LIVENESS: attempts overlapped the restore's own window" <<<"$log" \
     && grep -qE "^PASS +the FK was actually re-added" <<<"$log"; then
    echo "job $j: known flake lock_guard_probe (restore_fk_lock's probe timed out under load; both liveness witnesses and the re-add passed; #1066)"
  elif grep -qE "toomanyrequests|Data limit exceeded" <<<"$log" && ! grep -qE "^FAIL |not ok" <<<"$log"; then
    echo "job $j: known flake registry_quota (third-party image pull refused; no test ran)"
  elif [ "$(grep -cE '^FAIL +bench/[^ ]+ PASSED against its own defect' <<<"$log")" = "1" ] \
     && grep -qE '^FAIL +bench/regrain_perf\.sh PASSED against its own defect' <<<"$log" \
     && grep -qE '^--- regrain_no_delta_analyze$' <<<"$log"; then
    echo "job $j: known flake regrain_perf_discriminate (regrain_perf.sh's scan counter read before the collector flushed; the only non-discriminating guard in the shard; #871)"
  else
    echo "job $j ($name): UNKNOWN failure, not a flake this script knows; do not retry"
    rc=1
  fi
done <<<"$bad"
exit $rc
