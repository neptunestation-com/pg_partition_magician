#!/usr/bin/env bash
# land.sh [--batch] [--merge-method merge|squash] [--min-checks N] [--rebase-only] <pr> [<pr> ...]
#
# Land fix PRs through the merge queue in the order given. For each PR:
#
#   1. check it out detached in a throwaway worktree and rebase it onto its target: origin/main, or in
#      --batch mode the previous PR's new head, so the batch is a stack the queue can build as one group;
#   2. resolve the same-spot add/add conflicts with keep_both.py, in the LIST FILES (CHANGELOG.md,
#      bench/mutations/mutate.py, test.sh, the perf, archive and lint workflows) and, since pass 4 (#713),
#      in any other file: the rebase runs under the diff3 conflict style, whose base section tells an
#      add/add hunk from one both sides edited, and only the latter stops the run with the worktree left
#      for a human;
#   3. verify the result the way CI would before spending a CI run on it: every `_q` splice marked,
#      test.sh parses with unique pgpm_perfNN guard databases (the branch's duplicate is renumbered),
#      mutate.py has unique keys and EVERY mutation still builds against its source;
#   4. push with a lease, wait for the head's own checks (a known flake is rerun, see flake_check.sh;
#      a check whose name says `(informational)` is neither waited for nor read as a failure, see
#      #765; anything else stops the run), enqueue, and wait for the queue to merge it (a PR that leaves the
#      queue unmerged on a known flake is re-enqueued; a merge is re-checked before it is read as a
#      fall-out, because the queue entry reads empty for a few seconds after the merge).
#
# Single mode (the default) does 1 to 4 per PR, serially: under a SQUASH queue nothing else works, because
# a squash commit has no ancestry link to its branch, so once PR k-1 lands, PR k conflicts with main in
# the list files and must be rebased and re-checked before it can be queued (about 28 minutes per PR,
# measured in pass 3). Under a MERGE-commit queue (this repository's since 2026-09-29) --batch takes up
# to five PRs at once: each is rebased onto the previous one's head, all heads are pushed and checked in
# parallel, then each is enqueued as soon as ITS head is green and its predecessor has merged (the queue
# drops a PR stacked on another queued PR's head, so they cannot all be queued at once; and waiting for
# the whole batch's heads first gained nothing, #713: #691 sat green for 26 minutes while #704's checks
# ran). The stack is what makes it work: PR k's branch contains PR k-1's commits, so once k-1 has merged,
# k needs no rebase and no new head checks. A batch costs one head-check round plus one merge group per
# PR, against one of each per PR one at a time. A PR that has already merged when the run starts is
# skipped, so a batch that stopped after some of its PRs had merged is rerun with the same command.
#
# Knobs, all environment: LAND_WAIT_CHECKS_MIN (60), LAND_WAIT_MERGE_MIN (60), LAND_WAIT_RUN_MIN (90),
# LAND_MERGE_METHOD (merge; must match the ruleset's merge_method), LAND_TOOLING (the scripts/review
# directory to run keep_both.py and flake_check.sh from; default this checkout's, which means a PR that
# fixes the landing tooling cannot be landed by the copy it fixes unless this points at its worktree).
#
# Exit codes: 0 every PR merged; 3 a conflict or verification needs a hand (the worktree path is printed
# and kept); 4 a CI failure that is not a known flake, or the queue refused; 5 gh/git failure; 6 a wait
# timed out (checks, a run, or the queue), an enqueue that never took after five requests (GitHub
# answered "Something went wrong" to #703's twice), or main moved under a queued PR and made it DIRTY
# (the rerun's rebase repairs it): nothing is wrong, rerun the same command.
# Run it from the repository root of a clean checkout. It never touches the checkout's own branch.
set -uo pipefail
MIN=20; REBASE_ONLY=""; BATCH=""
METHOD="${LAND_MERGE_METHOD:-merge}"
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --min-checks) MIN=$2; shift 2;;
    --rebase-only) REBASE_ONLY=1; shift;;
    --batch) BATCH=1; shift;;
    --merge-method) METHOD=$2; shift 2;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) PRS+=("$1"); shift;;
  esac
done
[ ${#PRS[@]} -gt 0 ] || { echo "usage: land.sh [--batch] [--merge-method merge|squash] [--min-checks N] [--rebase-only] <pr> [<pr> ...]"; exit 2; }
case "$METHOD" in merge|squash) ;; *) echo "merge method must be merge or squash (got $METHOD)"; exit 2;; esac
[ -z "$BATCH" ] || [ ${#PRS[@]} -le 5 ] || { echo "a batch is at most 5 PRs (the queue's max_entries_to_build)"; exit 2; }
[ -z "$BATCH" ] || [ "$METHOD" = merge ] || { echo "--batch needs a merge-commit queue (--merge-method merge)"; exit 2; }
ROOT=$(git rev-parse --show-toplevel) || exit 5
cd "$ROOT" || exit 5
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 5
S="${LAND_TOOLING:-$ROOT/scripts/review}"
LIST_FILES="CHANGELOG.md bench/mutations/mutate.py test.sh .github/workflows/perf.yml .github/workflows/archive.yml .github/workflows/lint.yml"
WAIT_CHECKS=$(( ${LAND_WAIT_CHECKS_MIN:-60} * 2 ))   # polls of 30 s
WAIT_MERGE=$(( ${LAND_WAIT_MERGE_MIN:-60} * 2 ))
WAIT_RUN=$(( ${LAND_WAIT_RUN_MIN:-90} * 2 ))

say() { echo "$(date -u +%H:%M:%SZ) $*"; }

verify_tree() { # in the worktree: the checks CI would fail on, cheaply, before any push
  python3 scripts/check_quoted_splices.py >/dev/null || { echo "    check_quoted_splices FAILS"; return 1; }
  bash -n test.sh || { echo "    test.sh does not parse"; return 1; }
  python3 - <<'PY' || return 1
import re, sys, ast, subprocess, tempfile, os
s = open("test.sh").read()
names = re.findall(r"pgpm_perf[0-9]+\b", s)
dups = sorted({n for n in names if names.count(n) > 1})
if dups:
    # two PRs each took "the next free" database; the branch's line is the LAST occurrence
    nxt = max(int(n[9:]) for n in names) + 1
    for d in dups:
        i = s.rfind(d); s = s[:i] + f"pgpm_perf{nxt}" + s[i + len(d):]
        print(f"    renumbered the second {d} to pgpm_perf{nxt}"); nxt += 1
    open("test.sh", "w").write(s)
src = open("bench/mutations/mutate.py").read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "MUTATIONS" for t in node.targets):
        keys = [k.value for k in node.value.keys if isinstance(k, ast.Constant)]
        d = sorted({k for k in keys if keys.count(k) > 1})
        if d: print("    duplicate mutation keys:", d); sys.exit(1)
sys.path.insert(0, "bench/mutations"); import mutate
bad = []
for name in mutate.MUTATIONS:
    srcf = mutate.MUTATION_SRC.get(name, "pgpm_core/install.sql")
    with tempfile.NamedTemporaryFile(suffix=".sql", delete=False) as tf: out = tf.name
    r = subprocess.run([sys.executable, "bench/mutations/mutate.py", name, srcf, out], capture_output=True, text=True)
    os.unlink(out)
    if r.returncode != 0: bad.append(name)
if bad: print("    mutations that no longer build:", bad); sys.exit(1)
print(f"    verified: {len(mutate.MUTATIONS)} mutations build, guard databases unique, splices marked")
PY
}

rebase_pr() { # <worktree> <target>: rebase detached HEAD onto <target>, resolving list files; 0 ok, 3 needs a hand
  local wt=$1 target=$2
  ( cd "$wt" || exit 5
    git fetch -q origin main || exit 5
    if git merge-base --is-ancestor "$target" HEAD; then say "  already contains $target"; exit 0; fi
    say "  rebasing onto $target ($(git rev-parse --short "$target"))"
    # The diff3 conflict style, whatever the user's git config says: its base section is what lets
    # keep_both.py resolve a same-spot add/add hunk in ANY file (empty base) while refusing one both sides
    # edited (base not empty), which under the two-way style look the same. Pass 4 used the two-way style
    # and resolved the list files alone; six of its nine hand stops were add/add hunks elsewhere (#713).
    if ! git -c merge.conflictstyle=diff3 -c rerere.enabled=false rebase "$target" >/dev/null 2>&1; then
      while git status | grep -q "rebase in progress"; do
        for f in $(git diff --name-only --diff-filter=U); do
          if python3 "$S/keep_both.py" "$f"; then
            git add "$f"
            case " $LIST_FILES " in
              *" $f "*) say "  auto-resolved $f (kept both sides)";;
              *) say "  auto-resolved $f (not a list file: same-spot add/add, both sides kept, main's first; the head checks are the proof)";;
            esac
          else
            echo "  MANUAL: $f (keep_both refused it: both sides edited the same lines, or a hunk it does not know); resolve it in $wt and rerun"
            exit 3
          fi
        done
        GIT_EDITOR=true git -c rerere.enabled=false rebase --continue >/dev/null 2>&1 || true
      done
    fi
    verify_tree || { echo "  MANUAL: verification failed in $wt"; exit 3; }
    if [ -n "$(git status --porcelain)" ]; then   # verify_tree renumbered a guard database
      git add test.sh && git commit -q --amend --no-edit
    fi
    say "  rebased: $(git log --oneline -1)"
  )
}

wait_run() { # <run_id>: until the run's latest attempt completes; 1 on timeout
  local i
  for i in $(seq 1 "$WAIT_RUN"); do
    [ "$(gh run view "$1" --repo "$REPO" --json status --jq .status 2>/dev/null)" = "completed" ] && return 0
    sleep 30
  done
  echo "  run $1 did not complete in ${LAND_WAIT_RUN_MIN:-90} min"; return 1
}

wait_checks() { # <pr>: 0 green, 5 a check failed (prints the failing run id to $FAILED_RUN), 1 timeout
  local pr=$1 json s n i
  for i in $(seq 1 "$WAIT_CHECKS"); do
    # a check whose name says "(informational)" is dropped before anything is read from the list: the
    # dbdev package size job (#765) is red on purpose while the package is over database.dev's column,
    # and it is in no summary's `needs`, so the queue merges past it; this waiter must too
    json=$(gh pr checks "$pr" --repo "$REPO" --json bucket,link,name 2>/dev/null \
           | jq '[.[] | select(.name | test("\\(informational\\)") | not)]') || json="[]"
    n=$(jq 'length' <<<"$json")
    s=$(jq -r 'map(.bucket) | group_by(.) | map("\(.[0]):\(length)") | join(" ")' <<<"$json")
    say "  #$pr checks n=$n $s"
    if jq -e 'any(.bucket == "fail")' <<<"$json" >/dev/null; then
      FAILED_RUN=$(jq -r '.[] | select(.bucket=="fail") | .link' <<<"$json" | sed -E 's#.*/runs/([0-9]+)/.*#\1#' | sort -u | head -1)
      return 5
    fi
    if [ "$n" -ge "$MIN" ] && ! jq -e 'any(.bucket == "pending")' <<<"$json" >/dev/null; then return 0; fi
    sleep 30
  done
  return 1
}

in_queue() { gh api graphql -f query="{repository(owner:\"${REPO%/*}\",name:\"${REPO#*/}\"){pullRequest(number:$1){state mergeQueueEntry{state}}}}" \
             --jq '.data.repository.pullRequest | "\(.state) \(.mergeQueueEntry.state // "none")"' 2>/dev/null || echo "query-failed"; }

wait_merge() { # <pr>: 0 merged, 6 fell out of the queue, 8 dirty (main moved under it), 1 timeout
  local pr=$1 s i
  for i in $(seq 1 "$WAIT_MERGE"); do
    s=$(in_queue "$pr")
    case "$s" in
      MERGED*) return 0;;
      "OPEN none")
        if [ "$i" -gt 3 ]; then
          # the entry reads empty for a few seconds after the merge too (#609 in pass 3): look again
          sleep 15; s=$(in_queue "$pr")
          case "$s" in MERGED*) return 0;; esac
          # DIRTY before "fell out": a PR the queue dropped because another merge made it conflict with
          # main is not a flake to re-enqueue (the request is refused five times over), it needs the
          # rebase a rerun does (#719: #722 merged under it while it waited, 2026-10-01)
          [ "$(gh pr view "$pr" --repo "$REPO" --json mergeStateStatus --jq .mergeStateStatus)" = "DIRTY" ] && return 8
          say "  #$pr left the queue unmerged"; return 6
        fi;;
    esac
    [ "$(gh pr view "$pr" --repo "$REPO" --json mergeStateStatus --jq .mergeStateStatus)" = "DIRTY" ] && return 8
    sleep 30
  done
  return 1
}

prepare_pr() { # <pr> <target>: worktree, rebase onto <target>, push; sets HEAD_SHA; 0 ok, or exits 3/4/5
  local PR=$1 target=$2 br wt rc
  say "===== PR #$PR ====="
  br=$(gh pr view "$PR" --repo "$REPO" --json headRefName,state --jq 'select(.state=="OPEN") | .headRefName')
  [ -n "$br" ] || { echo "  #$PR is not an open PR"; exit 4; }
  git fetch -q origin "$br" || exit 5
  wt=$(mktemp -d "${TMPDIR:-/tmp}/land-$PR-XXXX")
  git worktree add -q --detach "$wt" "origin/$br" || exit 5
  rebase_pr "$wt" "$target"; rc=$?
  [ $rc -eq 0 ] || { echo "STOPPED at #$PR: needs a hand in $wt (then \`git push --force-with-lease origin HEAD:$br\` and rerun)"; exit 3; }
  if [ "$(git -C "$wt" rev-parse HEAD)" != "$(git rev-parse "origin/$br")" ]; then
    git -C "$wt" push -q --force-with-lease="$br:$(git rev-parse "origin/$br")" origin "HEAD:refs/heads/$br" || { echo "STOPPED: push of $br refused (lease)"; exit 5; }
    say "  pushed $(git -C "$wt" rev-parse --short HEAD) to $br"
    PUSHED=1
  fi
  HEAD_SHA=$(git -C "$wt" rev-parse HEAD)
  git worktree remove --force "$wt"
}

ensure_green() { # <pr>: wait for the head's checks, rerunning a known flake; exits 4 or 6 otherwise
  local PR=$1 retries=0 rc
  while :; do
    wait_checks "$PR"; rc=$?
    if [ $rc -eq 5 ]; then
      retries=$((retries + 1)); [ $retries -le 2 ] || { echo "STOPPED at #$PR: checks still failing after retries"; exit 4; }
      wait_run "$FAILED_RUN" || exit 6
      "$S/flake_check.sh" "$FAILED_RUN" --repo "$REPO" || { echo "STOPPED at #$PR: run $FAILED_RUN is not a known flake"; exit 4; }
      say "  rerunning the failed jobs of run $FAILED_RUN (known flake, retry $retries)"
      gh run rerun "$FAILED_RUN" --repo "$REPO" --failed || { echo "STOPPED at #$PR: rerun refused"; exit 4; }
      sleep 90; continue
    fi
    [ $rc -eq 0 ] || { echo "STOPPED at #$PR: checks did not complete in ${LAND_WAIT_CHECKS_MIN:-60} min (rerun)"; exit 6; }
    return 0
  done
}

enqueue() { # <pr>: request the enqueue and confirm the entry exists; up to five requests, with a growing
            # pause, because a request can be dropped without a word (the first live batch, #647) or answered
            # "Something went wrong" (a GraphQL error: #703 got two in a row and sat unqueued, #713)
  local i s out
  for i in 1 2 3 4 5; do
    say "  enqueueing #$1 (request $i of 5)"
    out=$(gh pr merge "$1" --repo "$REPO" "--$METHOD" 2>&1) || true
    grep -v "merge strategy" <<<"$out" | grep -v '^$' || true
    sleep $((10 + 10 * i))
    s=$(in_queue "$1")
    case "$s" in
      "OPEN none"|query-failed) say "  #$1 is not in the queue after the request ($s)";;
      *) return 0;;
    esac
  done
  return 1
}

await_merge() { # <pr>: wait for the merge, re-enqueueing after a known flake; exits 3, 4 or 6 otherwise
  local PR=$1 retries=0 rc run
  while :; do
    wait_merge "$PR"; rc=$?
    case $rc in
      0) say "  MERGED #$PR"; return 0;;
      6) run=$(gh run list --repo "$REPO" --event merge_group --limit 30 --json databaseId,headBranch,conclusion \
                 --jq ".[] | select(.headBranch | test(\"pr-$PR-\")) | select(.conclusion==\"failure\") | .databaseId" | head -1)
         retries=$((retries + 1)); [ $retries -le 2 ] || { echo "STOPPED at #$PR: fell out of the queue twice"; exit 4; }
         if [ -n "$run" ]; then "$S/flake_check.sh" "$run" --repo "$REPO" || { echo "STOPPED at #$PR: merge group $run is not a known flake"; exit 4; }; fi
         say "  re-enqueueing #$PR (known flake, retry $retries)"
         enqueue "$PR" || { echo "STOPPED at #$PR: the re-enqueue never took after five requests (rerun)"; exit 6; }
         continue;;
      8) echo "STOPPED at #$PR: main moved under it while it waited (DIRTY); nothing is wrong, the rerun rebases it"; exit 6;;
      *) echo "STOPPED at #$PR: queue wait timed out after ${LAND_WAIT_MERGE_MIN:-60} min (rerun)"; exit 6;;
    esac
  done
}

git fetch -q origin main || exit 5
# A PR that merged already (a batch rerun after a stop, #713: #685 and #697 each stopped their rerun with
# "is not an open PR") is skipped; one closed without merging is a mistake in the list and stops the run.
open_prs=()
for PR in "${PRS[@]}"; do
  st=$(gh pr view "$PR" --repo "$REPO" --json state --jq .state) || exit 5
  case "$st" in
    OPEN) open_prs+=("$PR");;
    MERGED) say "skipping #$PR: already merged";;
    *) echo "#$PR is $st (closed without merging); take it off the list"; exit 4;;
  esac
done
PRS=(${open_prs[@]+"${open_prs[@]}"})
[ ${#PRS[@]} -gt 0 ] || { say "ALL LANDED: every PR given had already merged"; exit 0; }
if [ -z "$BATCH" ]; then
  for PR in "${PRS[@]}"; do
    PUSHED=""; prepare_pr "$PR" origin/main
    [ -n "$PUSHED" ] && sleep 30   # let GitHub register the new head before the check waiter reads an empty list
    [ -n "$REBASE_ONLY" ] && continue
    ensure_green "$PR"
    enqueue "$PR" || { echo "STOPPED at #$PR: the enqueue never took after five requests (rerun)"; exit 6; }
    await_merge "$PR"
  done
else
  # a stack: each PR rebased onto the previous one's new head, then everything in parallel
  target=origin/main; PUSHED=""
  for PR in "${PRS[@]}"; do
    prepare_pr "$PR" "$target"; target=$HEAD_SHA
  done
  [ -n "$PUSHED" ] && sleep 30
  [ -n "$REBASE_ONLY" ] && { say "REBASED (stack): ${PRS[*]}"; exit 0; }
  # In turn, not all at once: GitHub removes a queued PR whose head sits on another queued PR's head
  # (2026-09-29, the first live batch: #647 was added and removed 12 s later, twice, with no group built,
  # while #646 was AWAITING_CHECKS). Each PR is enqueued as soon as ITS head is green and its predecessor
  # has merged, while the later heads go on checking (pass 4 waited for every head first, and #691 sat
  # green for 26 minutes behind #704's checks, #713). A PR's branch already contains its predecessor, so
  # no rebase and no new head checks are needed. What the batch saves is the rebase and the head-check
  # round per PR; each PR still gets its own merge group.
  for PR in "${PRS[@]}"; do
    ensure_green "$PR"
    enqueue "$PR" || { echo "STOPPED at #$PR: the enqueue never took after five requests (rerun)"; exit 6; }
    await_merge "$PR"
  done
fi
say "ALL LANDED: ${PRS[*]}"
