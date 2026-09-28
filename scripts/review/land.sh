#!/usr/bin/env bash
# land.sh [--min-checks N] [--rebase-only] <pr> [<pr> ...]
#
# Land fix PRs through the squash merge queue, one at a time, in the order given. For each PR:
#
#   1. check it out detached in a throwaway worktree and rebase it onto origin/main;
#   2. resolve the add/add conflicts in the LIST FILES (CHANGELOG.md, bench/mutations/mutate.py,
#      test.sh, the perf and archive workflows) with keep_both.py; any other conflict stops the run and
#      leaves the worktree for a human;
#   3. verify the result the way CI would before spending a CI run on it: every `_q` splice marked,
#      test.sh parses with unique pgpm_perfNN guard databases (the branch's duplicate is renumbered),
#      mutate.py has unique keys and EVERY mutation still builds against its source;
#   4. push with a lease, wait for the head's own checks (a known flake is rerun once, see
#      flake_check.sh; anything else stops the run), enqueue, and wait for the queue to merge it (a PR
#      that leaves the queue unmerged on a known flake is re-enqueued once).
#
# Why one at a time. A squash commit has no ancestry link to its branch, so once PR k-1 lands, the
# queue's three-way merge of PR k sees both sides adding adjacent lines in the list files and reports
# a conflict; PR k has to be rebased onto the new main first, and its head checks re-run before it can
# be queued. That is one head-check run plus one merge group per PR (about 24 minutes measured in
# pass 2's fix phase) and it cannot be pipelined under squash. Stacking the PRs on each other does not
# help, for the same reason. A merge-commit queue would allow batches; that is a repository setting,
# not something this script decides.
#
# Exit codes: 0 every PR merged; 3 a conflict or verification needs a hand (the worktree path is
# printed and kept); 4 a CI failure that is not a known flake, or the queue refused; 5 gh/git failure.
# Run it from the repository root of a clean checkout. It never touches the checkout's own branch.
set -uo pipefail
MIN=20; REBASE_ONLY=""
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --min-checks) MIN=$2; shift 2;;
    --rebase-only) REBASE_ONLY=1; shift;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) PRS+=("$1"); shift;;
  esac
done
[ ${#PRS[@]} -gt 0 ] || { echo "usage: land.sh [--min-checks N] [--rebase-only] <pr> [<pr> ...]"; exit 2; }
ROOT=$(git rev-parse --show-toplevel) || exit 5
cd "$ROOT" || exit 5
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 5
S="$ROOT/scripts/review"
LIST_FILES="CHANGELOG.md bench/mutations/mutate.py test.sh .github/workflows/perf.yml .github/workflows/archive.yml .github/workflows/lint.yml"

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

rebase_pr() { # <worktree>: rebase detached HEAD onto origin/main, resolving list files; 0 ok, 3 needs a hand
  local wt=$1
  ( cd "$wt" || exit 5
    git fetch -q origin main || exit 5
    if git merge-base --is-ancestor origin/main HEAD; then say "  already contains origin/main"; exit 0; fi
    say "  rebasing onto origin/main ($(git rev-parse --short origin/main))"
    if ! git rebase origin/main >/dev/null 2>&1; then
      while git status | grep -q "rebase in progress"; do
        for f in $(git diff --name-only --diff-filter=U); do
          case " $LIST_FILES " in
            *" $f "*) python3 "$S/keep_both.py" "$f" || { echo "  MANUAL: $f (keep_both could not make it whole)"; exit 3; }
                      git add "$f"; say "  auto-resolved $f (kept both sides)";;
            *) echo "  MANUAL: $f is not a list file; resolve it in $wt and rerun"; exit 3;;
          esac
        done
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
      done
    fi
    verify_tree || { echo "  MANUAL: verification failed in $wt"; exit 3; }
    if [ -n "$(git status --porcelain)" ]; then   # verify_tree renumbered a guard database
      git add test.sh && git commit -q --amend --no-edit
    fi
    say "  rebased: $(git log --oneline -1)"
  )
}

wait_run() { # <run_id>: until the run's latest attempt completes (90 min)
  for _ in $(seq 1 180); do
    [ "$(gh run view "$1" --repo "$REPO" --json status --jq .status 2>/dev/null)" = "completed" ] && return 0
    sleep 30
  done
  echo "  run $1 did not complete in 90 min"; return 1
}

wait_checks() { # <pr>: 0 green, 5 a check failed (prints the failing run id to $FAILED_RUN), 1 timeout
  local pr=$1 json s n
  for _ in $(seq 1 120); do
    json=$(gh pr checks "$pr" --repo "$REPO" --json bucket,link 2>/dev/null) || json="[]"
    n=$(jq 'length' <<<"$json")
    s=$(jq -r 'map(.bucket) | group_by(.) | map("\(.[0]):\(length)") | join(" ")' <<<"$json")
    say "  checks n=$n $s"
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

wait_merge() { # <pr>: 0 merged, 6 fell out of the queue, 8 dirty (needs rebase), 1 timeout
  local pr=$1 s i
  for i in $(seq 1 120); do
    s=$(in_queue "$pr")
    case "$s" in
      MERGED*) return 0;;
      "OPEN none") [ "$i" -gt 3 ] && { say "  #$pr left the queue unmerged"; return 6; };;
    esac
    [ "$(gh pr view "$pr" --repo "$REPO" --json mergeStateStatus --jq .mergeStateStatus)" = "DIRTY" ] && return 8
    sleep 30
  done
  return 1
}

for PR in "${PRS[@]}"; do
  say "===== PR #$PR ====="
  br=$(gh pr view "$PR" --repo "$REPO" --json headRefName,state --jq 'select(.state=="OPEN") | .headRefName')
  [ -n "$br" ] || { echo "  #$PR is not an open PR"; exit 4; }
  git fetch -q origin "$br" || exit 5
  wt=$(mktemp -d "${TMPDIR:-/tmp}/land-$PR-XXXX")
  git worktree add -q --detach "$wt" "origin/$br" || exit 5
  rebase_pr "$wt"; rc=$?
  [ $rc -eq 0 ] || { echo "STOPPED at #$PR: needs a hand in $wt (then \`git push --force-with-lease origin HEAD:$br\` and rerun)"; exit 3; }
  if [ "$(git -C "$wt" rev-parse HEAD)" != "$(git rev-parse "origin/$br")" ]; then
    git -C "$wt" push -q --force-with-lease="$br:$(git rev-parse "origin/$br")" origin "HEAD:refs/heads/$br" || { echo "STOPPED: push of $br refused (lease)"; exit 5; }
    say "  pushed $(git -C "$wt" rev-parse --short HEAD) to $br"
    sleep 30   # let GitHub register the new head before the check waiter reads an empty list
  fi
  git worktree remove --force "$wt"
  [ -n "$REBASE_ONLY" ] && continue
  retries=0
  while :; do
    wait_checks "$PR"; rc=$?
    if [ $rc -eq 5 ]; then
      retries=$((retries + 1)); [ $retries -le 2 ] || { echo "STOPPED at #$PR: checks still failing after retries"; exit 4; }
      wait_run "$FAILED_RUN" || exit 4
      "$S/flake_check.sh" "$FAILED_RUN" --repo "$REPO" || { echo "STOPPED at #$PR: run $FAILED_RUN is not a known flake"; exit 4; }
      say "  rerunning the failed jobs of run $FAILED_RUN (known flake, retry $retries)"
      gh run rerun "$FAILED_RUN" --repo "$REPO" --failed || { echo "STOPPED at #$PR: rerun refused"; exit 4; }
      sleep 90; continue
    fi
    [ $rc -eq 0 ] || { echo "STOPPED at #$PR: checks did not complete"; exit 4; }
    say "  enqueueing #$PR"
    gh pr merge "$PR" --repo "$REPO" --squash 2>&1 | grep -v "merge strategy" || true
    wait_merge "$PR"; rc=$?
    case $rc in
      0) say "  MERGED #$PR"; break;;
      6) run=$(gh run list --repo "$REPO" --event merge_group --limit 30 --json databaseId,headBranch,conclusion \
                 --jq ".[] | select(.headBranch | test(\"pr-$PR-\")) | select(.conclusion==\"failure\") | .databaseId" | head -1)
         retries=$((retries + 1)); [ $retries -le 2 ] || { echo "STOPPED at #$PR: fell out of the queue twice"; exit 4; }
         if [ -n "$run" ]; then "$S/flake_check.sh" "$run" --repo "$REPO" || { echo "STOPPED at #$PR: merge group $run is not a known flake"; exit 4; }; fi
         say "  re-enqueueing #$PR (known flake, retry $retries)"; continue;;
      8) echo "STOPPED at #$PR: main moved under it (DIRTY); rerun land.sh $PR"; exit 3;;
      *) echo "STOPPED at #$PR: queue wait timed out"; exit 4;;
    esac
  done
done
say "ALL LANDED: ${PRS[*]}"
