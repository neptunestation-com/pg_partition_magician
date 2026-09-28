#!/usr/bin/env bash
# Prove scripts/review/keep_both.py resolves the conflict hunks git ACTUALLY writes under each of its
# conflict styles, and refuses a hunk it cannot resolve, rather than exiting 0 with a marker left in.
#
# WHY THIS GUARD EXISTS (issue #598). keep_both.py resolves the add/add conflicts every fix PR's rebase
# produces in the list files, and land.sh `git add`s whatever it writes. Its hunk pattern knew only the
# default two-way shape (<<<<<<< / ======= / >>>>>>>). Under git's diff3 or zdiff3 conflict style (a common
# global setting) a hunk also carries a `||||||| <base>` section: the pattern folded it into "ours", the
# marker check looked only for <<<<<<< and >>>>>>>, and the script exited 0 with the `|||||||` line, and any
# base lines, left in CHANGELOG.md. Its self-test could not see this, because it only ever fed the script
# hunks written by hand in the shape the author expected; this guard has git write them.
#
# HOW. For each conflict style (merge, diff3, zdiff3) it builds a repository in which main and a branch
# each add a bullet at the top of CHANGELOG.md's Unreleased section, merges, and checks, in order:
#   LIVENESS  git left a conflict of the style's own shape (a `|||||||` section under diff3 and zdiff3,
#             none under merge), so the case under test really is the one git writes;
#   then      keep_both exits 0 and the file is EXACTLY both bullets, the branch's first, with no
#             marker line of any kind (identity, not "both bullets are somewhere in it").
# And for diff3 and zdiff3, a hunk whose base section is NOT empty (both sides reworded the same bullet,
# which is not an add/add conflict and has no "keep both" answer): keep_both must exit non-zero and leave
# the file as git wrote it. Its LIVENESS is that the base section really holds the original line.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   keep_both_two_way_only -- keep_both's hunk pattern and marker check put back to the two-way shape
#
# Usage: keep_both_diff3.sh <container> <db> [keep_both.py]
# Needs git (2.35 or later, for zdiff3) and python3 on the host and nothing else. <container> and <db>
# are accepted so bench/discriminate.sh can call it the way it calls every guard, and are not used. A
# /repo/... path is mapped to this checkout, which is how discriminate.sh points it at a mutant.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KB="${3:-$ROOT/scripts/review/keep_both.py}"
KB="${KB/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-58s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-58s %s\n' "$1" "$2"; fail=1; }

if [ ! -f "$KB" ]; then bad "the resolver under test exists" "$KB"; exit 1; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# conflict <dir> <style> <main's CHANGELOG> <branch's CHANGELOG>: base commit, a branch, main, merge.
conflict() {
  local d="$1" style="$2"
  g() { git -C "$d" -c user.email=g@example.invalid -c user.name=g -c init.defaultBranch=main \
          -c merge.conflictstyle="$style" "$@"; }
  mkdir -p "$d"; g init -q
  printf '# Changelog\n\n## Unreleased\n\n- an older bullet\n' > "$d/CHANGELOG.md"
  g add CHANGELOG.md && g commit -qm base
  g checkout -qb fix
  printf '%b' "$4" > "$d/CHANGELOG.md"; g commit -qam branch
  g checkout -q main
  printf '%b' "$3" > "$d/CHANGELOG.md"; g commit -qam main
  g merge fix >/dev/null 2>&1
  return 0
}
markers() { grep -cE '^(<{7}|>{7}|\|{7})( |$)|^={7}$' "$1"; }

want=$'# Changelog\n\n## Unreleased\n\n- the branch bullet\n- the main bullet\n- an older bullet'
for style in merge diff3 zdiff3; do
  d="$work/add_$style"
  conflict "$d" "$style" '# Changelog\n\n## Unreleased\n\n- the main bullet\n- an older bullet\n' \
                         '# Changelog\n\n## Unreleased\n\n- the branch bullet\n- an older bullet\n'
  f="$d/CHANGELOG.md"
  has_base=$(grep -c '^|||||||' "$f"); want_base=1
  [ "$style" = merge ] && want_base=0
  if grep -q '^<<<<<<< ' "$f" && [ "$has_base" = "$want_base" ]; then
    ok "LIVENESS: git wrote a $style add/add conflict" "base sections: $has_base"
  else
    bad "LIVENESS: git wrote a $style add/add conflict" "base sections: $has_base"; sed 's/^/      /' "$f"; continue
  fi
  python3 "$KB" "$f" >"$work/kb.out" 2>&1; rc=$?
  got=$(cat "$f")
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [ "$(markers "$f")" = 0 ]; then
    ok "$style: both bullets kept, branch first, no marker left" "exit 0"
  else
    bad "$style: both bullets kept, branch first, no marker left" "exit $rc, $(markers "$f") marker line(s)"
    sed 's/^/      /' "$f" "$work/kb.out"
  fi
done

for style in diff3 zdiff3; do
  d="$work/mod_$style"
  conflict "$d" "$style" '# Changelog\n\n## Unreleased\n\n- an older bullet, reworded on main\n' \
                         '# Changelog\n\n## Unreleased\n\n- an older bullet, reworded on the branch\n'
  f="$d/CHANGELOG.md"
  before=$(cat "$f")
  if awk '/^\|\|\|\|\|\|\|/ {b=1; next} /^=======$/ {b=0} b && /^- an older bullet$/ {n++} END {exit !(n==1)}' "$f"; then
    ok "LIVENESS: git wrote a $style hunk whose base is not empty" "the original bullet"
  else
    bad "LIVENESS: git wrote a $style hunk whose base is not empty" "no base line"; sed 's/^/      /' "$f"; continue
  fi
  python3 "$KB" "$f" >"$work/kb.out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && [ "$(cat "$f")" = "$before" ]; then
    ok "$style: a two-sided edit is refused and the file left alone" "exit $rc"
  else
    bad "$style: a two-sided edit is refused and the file left alone" "exit $rc"
    sed 's/^/      /' "$f" "$work/kb.out"
  fi
done
exit "$fail"
