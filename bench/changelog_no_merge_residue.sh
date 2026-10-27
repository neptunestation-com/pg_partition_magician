#!/usr/bin/env bash
# Prove that CHANGELOG.md carries no merge residue, judged by the real check
# (scripts/check_changelog_residue.py, check 7 of scripts/check_living_docs.sh), and that the check sees it.
#
# WHY THIS GUARD EXISTS (issue #1277, F17-07 and F12r-01). CHANGELOG.md is a list file every fix PR adds a
# bullet to, and a conflict in it is resolved by keeping both sides. When both sides were versions of the
# same bullet, keeping both left it twice, or left the older version's tail glued after the newer one: review
# pass 12 found five Unreleased bullets present twice word for word, and #1161's bullet carrying a stale
# second tail that said `set_regrain` refuses a run past the lock budget, where the code warns, logs
# `warn_regrain_lock_budget` and stores the target, as the bullet's own first half says. Nothing failed.
#
# HOW. The check runs over the changelog given (the tree's by default). It refuses a bullet whose whole text
# is another's, a bullet that repeats an 8-word run of its own text (a stale tail), and a bullet whose
# parentheses do not balance outside code spans (a fragment that opened mid-parenthesis).
#   LIVENESS  the check read the changelog's bullets (at least 100 of the tree's, so a parser that stopped
#             seeing them is a failure, not a clean sweep), and the changelog has an `[Unreleased]` section;
#   CONTROL   the check's own self-test: a clean sample passes, and each of seven re-breaks of it fails.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   changelog_1161_stale_tail -- CHANGELOG.md's #1161 bullet with its pre-#1277 stale second tail put back
#
# Usage: changelog_no_merge_residue.sh <container> <db> [CHANGELOG.md]
# With no third argument it reads this checkout's CHANGELOG.md; with one it reads THAT file, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Needs python3 on
# the host and nothing else; <container> and <db> are accepted so discriminate.sh can call it the way it calls
# every guard, and are not used (no database is created, so its name in test.sh's list collides with none).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CL="${3:-$ROOT/CHANGELOG.md}"
CL="${CL/#\/repo\//$ROOT/}"
fail=0
say() { printf '%s  %-66s %s\n' "$1" "$2" "$3"; }

if [ ! -f "$CL" ]; then say FAIL "fixture: the changelog to read exists" "$CL"; exit 1; fi

if out=$(python3 "$ROOT/scripts/check_changelog_residue.py" --selftest 2>&1); then
  say PASS "CONTROL: the check fails each of its re-breaks and passes the clean sample" "$(grep -c '^selftest: ok' <<<"$out") ok"
else
  say FAIL "CONTROL: the check fails each of its re-breaks and passes the clean sample" ""
  printf '%s\n' "$out" | sed 's/^/        /'
  fail=1
fi

if grep -q '^## \[Unreleased\]' "$CL"; then
  say PASS "LIVENESS: the changelog has an [Unreleased] section" "$(grep -n '^## \[Unreleased\]' "$CL" | cut -d: -f1 | head -1)"
else
  say FAIL "LIVENESS: the changelog has an [Unreleased] section" "none in $CL"; fail=1
fi

out=$(python3 "$ROOT/scripts/check_changelog_residue.py" "$CL" 2>&1); rc=$?
n=$(sed -nE 's/^PASS  .*: ([0-9]+) bullets, .*/\1/p' <<<"$out")
if [ "$rc" = 0 ]; then
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 100 ]; then
    say PASS "LIVENESS: the check read the changelog's bullets" "$n bullets"
    say PASS "the changelog carries no bullet twice and no stale tail" "$n bullets"
  else
    say FAIL "LIVENESS: the check read the changelog's bullets" "got: ${n:-none}, want >= 100"; fail=1
  fi
else
  grep '^FAIL' <<<"$out" | while IFS= read -r line; do
    say FAIL "the changelog carries no bullet twice and no stale tail" "${line#FAIL  }"
  done
  fail=1
fi
exit "$fail"
