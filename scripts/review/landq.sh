#!/usr/bin/env bash
# landq.sh <workdir> [--batch N]
#
# The fix phase's landing loop: a queue file of PRs landed in tier order by land.sh, restarted on its
# own after a wait timeout, stopped for a human on anything else. <workdir> holds:
#
#   landq.txt   one line per PR: `<tier> <pr>`; append while the loop runs, it re-reads the file each turn
#   landq.done  written by the loop: `<pr> merged <time>` or `<pr> FAILED rc=<n> <time>`
#   landq.log   land.sh's output, prefixed by the loop's own lines (`===== landing ...`, `keeper: ...`)
#
# Each turn takes the lowest tier's lowest-numbered PRs not yet in landq.done: one at a time by default,
# or with --batch N up to N of the SAME tier at once through `land.sh --batch` (a merge-commit queue;
# the batch is a stack, see land.sh). A land.sh exit of 6 (a wait timed out) is retried, at most eight
# times per PR, with the PR's FAILED line removed; any other non-zero exit leaves the line in place,
# prints why, and exits, because a conflict outside the list files or a CI failure that is not a known
# flake needs a person: fix it, delete the FAILED line, and rerun this script. When landq.txt has
# nothing left to land the loop idles (one poll a minute) so PRs can still be appended.
#
# Pass 3's loop was this script in scratch form: 24 PRs in 17.8 hours at one at a time, six restarts,
# nine stops for a hand. Run it detached (`nohup ... >> landq.log 2>&1 &`) and tail landq.log.
set -uo pipefail
W="${1:?workdir}"; shift
BATCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --batch) BATCH=$2; shift 2;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1"; exit 2;;
  esac
done
[ "$BATCH" -ge 1 ] && [ "$BATCH" -le 5 ] || { echo "--batch takes 1 to 5"; exit 2; }
ROOT=$(git rev-parse --show-toplevel) || exit 5
cd "$ROOT" || exit 5
S="${LAND_TOOLING:-$ROOT/scripts/review}"
touch "$W/landq.txt" "$W/landq.done" "$W/landq.tries"
say() { echo "$(date -u +%H:%M:%SZ) $*"; }

next_batch() { # prints up to $BATCH PRs of the lowest unfinished tier, lowest numbers first
  local t p tier=""
  sort -k1,1n -k2,2n "$W/landq.txt" | while read -r t p; do
    [ -n "$p" ] || continue
    grep -q "^$p " "$W/landq.done" && continue
    if [ -z "$tier" ]; then tier=$t; elif [ "$t" != "$tier" ]; then break; fi
    echo "$p"
  done | head -n "$BATCH"
}

while :; do
  prs=$(next_batch | tr '\n' ' '); prs=${prs% }
  if [ -z "$prs" ]; then sleep 60; continue; fi
  # shellcheck disable=SC2086
  set -- $prs
  tier=$(awk -v p="$1" '$2 == p {print $1; exit}' "$W/landq.txt")
  if [ $# -gt 1 ]; then say "===== landing batch $prs (tier $tier) ====="; opts=(--batch)
  else say "===== landing #$1 (tier $tier) ====="; opts=(); fi
  # shellcheck disable=SC2086
  # ${opts[@]+"${opts[@]}"}: an EMPTY array is an unbound variable under `set -u` in bash 3.2 (macOS), and
  # the one-PR case (a tier with a single PR) has no --batch, so the loop died there on its first single.
  "$S/land.sh" ${opts[@]+"${opts[@]}"} $prs; rc=$?
  if [ $rc -eq 0 ]; then
    for p in "$@"; do echo "$p merged $(date -u +%H:%M:%SZ)" >> "$W/landq.done"; done
    continue
  fi
  if [ $rc -eq 6 ]; then
    n=$(grep -c "^$1\$" "$W/landq.tries"); n=$((n + 1))
    if [ "$n" -le 8 ]; then
      echo "$1" >> "$W/landq.tries"
      say "keeper: #$1 stopped on a wait timeout (try $n of 8), rerunning"
      continue
    fi
    say "keeper: STOPPED #$1 timed out 8 times, leaving it"
  fi
  for p in "$@"; do echo "$p FAILED rc=$rc $(date -u +%H:%M:%SZ)" >> "$W/landq.done"; done
  say "STOPPED: land.sh exited $rc on $prs; read the log, fix, delete the FAILED line(s) from landq.done and rerun landq.sh"
  exit "$rc"
done
