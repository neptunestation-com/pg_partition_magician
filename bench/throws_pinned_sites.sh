#!/usr/bin/env bash
# Prove that bench/throws_pinned.sh judges every throws_* assertion a test file writes, whatever statement it
# wraps and however that statement is written, by running it over planted test files and reading which lines it
# judges; and that a run of it with nothing to judge is refused by bench/discriminate.sh as a starved fixture.
#
# WHY THIS GUARD EXISTS. throws_pinned.sh used to call a statement a site only when its text matched
# `call\s+pgpm\.` (#1182, F8-10): a throws_ok($$ call "pgpm".transmute(...) $$, NULL, desc) names the same
# committing procedure, and its NULL accepts the same 2D000 a transmute that did not refuse dies with inside
# pgTAP, but the quoted schema made it no site at all: the guard probed the file's pinned neighbour, printed
# "1 pinned of 1" and exited 0. #1182 taught it to read the name the CALL spells, and that reading was the next
# gap (#1235): a test's own helper procedure that calls pgpm.transmute (the pg_temp.mk and mk_archive_table
# shape), a helper FUNCTION that does (a committing procedure called from a function dies with the same
# 2D000), a statement held in a psql variable, one built by || concatenation, and a U&"..." name with a UESCAPE
# clause were all no site, each passed on its pinned neighbour. Any statement can reach a COMMIT, so
# throws_pinned.sh no longer reads the statement: every throws_* is a site. Two more spellings decided
# "not a site" by text, and are held here too: a `--` inside a literal earlier on the line read as a comment
# around the assertion, and a double-quoted assertion name ("throws_ok") was not read as one.
# And (#1235, B06-02) its closing summary restated any failure as an unprefixed FAIL, so a run whose only
# failure was its LIVENESS: zero-site premise, which its own comment calls "not evidence", read to
# discriminate.sh's starved() as a catch.
#
# WHAT IT ASSERTS, each planted file holding a pinned throws_ok in the plain spelling on line 3:
#   for each STATEMENT below, an unpinned throws_ok(<statement>, NULL, desc) on line 4 FAILS the guard, and the
#   failure names THAT line as accepting 2D000 (identity, not an exit code: a guard that failed for any other
#   reason names no line); the same for each whole LINE below, an unpinned assertion spelled so a reading by
#   text would skip it;
#   every statement at once, each PINNED, is a site the guard judges: it passes the file with all of them
#   counted as pinned;
#   a file with no throws_* at all fails the guard on its zero-site premise, and starved(), read out of
#   bench/discriminate.sh, refuses that run: it is not a catch.
#   LIVENESS: the guard under test ran its controls (the substituted statement raised 2D000 inside the
#   wrapper and NULL accepted it), so a failure above is about the site and not a broken instrument; it
#   PASSES a file whose one throws_* is pinned, so it does not fail every file it is given, which would satisfy
#   every check above without reading anything; and starved() certifies the run of the first planted file,
#   which failed a site, so a starved() that refuses everything cannot pass the zero-site check.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   throws_pinned_site_by_spelling   -- throws_pinned.sh deciding a site with the pre-#1182 `call\s+pgpm\.`
#                                       search again
#   throws_pinned_site_by_name       -- throws_pinned.sh skipping a statement that does not name pgpm, the
#                                       pre-#1235 reading by the name a CALL spells: a helper, a psql variable or
#                                       a UESCAPE name is no site again
#   throws_pinned_comment_by_spelling -- a `--` anywhere before the assertion on its line read as a comment again
#   throws_pinned_quoted_form        -- the assertion's name read unquoted only again
#   throws_pinned_summary_not_restated -- throws_pinned.sh's closing FAIL summary without its restated
#                                       `N ran, M failed` tail, the pre-#1235 verdict starved() certified
#
# Usage: throws_pinned_sites.sh <container> <db> [throws_pinned.sh]
# <db> names the nested runs' databases (<db>_1, <db>_2, ...). With a third argument it judges THAT script in
# place of bench/throws_pinned.sh; a /repo/... path is mapped to this checkout, which is how
# bench/discriminate.sh points it at a mutant. Runs on the plain core image, as throws_pinned.sh does.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${3:-$ROOT/bench/throws_pinned.sh}"
G="${G/#\/repo\//$ROOT/}"
fail=0; checks=0; failed=0
ok()  { printf 'PASS  %-70s %s\n' "$1" "$2"; checks=$((checks + 1)); }
bad() { printf 'FAIL  %-70s %s\n' "$1" "$2"; fail=1; checks=$((checks + 1)); failed=$((failed + 1)); }
if [ ! -f "$G" ]; then bad "GUARD: the throws_pinned.sh under test exists" "$G"; exit 1; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Each statement as a test file writes it: the first argument of the throws_ok, verbatim.
STATEMENTS=(
  "\$\$ call \"pgpm\".transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ CALL PGPM . \"transmute\"('public.t1182', 'id', 10) \$\$"
  "\$\$ call /* the maintenance tick */ pgpm./* of t1182 */maintain('public.t1182') \$\$"
  "\$\$ call
       \"pgpm\"
       .transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ call transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ call U&\"\\0070gpm\".U&\"m\\0061intain\"('public.t1182') \$\$"
  "format('call %I.transmute(%L, %L, 10)', 'pgpm', 'public.t1182', 'id')"
  "\$\$ call pg_temp.mk('public.t1182') \$\$"
  "\$\$ select pg_temp.mk_fn('public.t1182') \$\$"
  ":'stmt'"
  "'call ' || quote_ident('pgpm') || '.transmute(''public.t1182'', ''id'', 10)'"
  "\$\$ call U&\"!0070gpm\" UESCAPE '!' . U&\"tr!0061nsmute\" UESCAPE '!' ('public.t1182', 'id', 10) \$\$"
)
# Each whole line 4: an unpinned assertion whose site a reading by text would skip.
LINES=(
  "select is(1, 1, 'a -- b'); select throws_ok(\$\$ call pgpm.transmute('public.t1182', 'id', 10) \$\$, NULL, 'unpinned, after a literal holding --');"
  "select \"throws_ok\"(\$\$ call pgpm.transmute('public.t1182', 'id', 10) \$\$, NULL, 'unpinned, the assertion name quoted');"
)
PINNED="select throws_ok(\$\$ call pgpm.transmute('public.t1182', 'id', 10) \$\$, 'P0001', NULL, 'pinned, the plain spelling');"

n=0
# run <file>: the guard under test over <file> alone, its output in $out and its exit status in $rc.
run() {
  n=$((n + 1))
  out=$(bash "$G" "$C" "${DB}_$n" "$1" 2>&1 </dev/null); rc=$?
}
# planted <file> <line 4>: a file with the pinned plain spelling on line 3 and <line 4> beside it.
planted() {
  { echo "create extension if not exists pgtap;"; echo "select plan(2);"; echo "$PINNED"; echo "$2"
    echo "select * from finish();"; } > "$1"
}

# LIVENESS: the guard under test runs, and does not fail a file it has no reason to fail.
f="$work/only_pinned.sql"
{ echo "create extension if not exists pgtap;"; echo "select plan(1);"; echo "$PINNED"
  echo "select * from finish();"; } > "$f"
run "$f"
if grep -q '^PASS  LIVENESS: control: 2D000 is raised inside the wrapper and NULL accepts it' <<<"$out"; then
  ok "LIVENESS: the guard under test ran its controls" "2D000 raised, NULL accepts it"
else
  bad "LIVENESS: the guard under test ran its controls" "$(grep -m1 -E '^FAIL' <<<"$out")"
fi
if [ "$rc" = 0 ] && grep -qE '^PASS  every throws_\* .* 1 pinned, 0 by an expression, of 1$' <<<"$out"; then
  ok "LIVENESS: it passes a file whose one throws_* is pinned" "1 pinned of 1"
else
  bad "LIVENESS: it passes a file whose one throws_* is pinned" \
      "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
fi

# Each statement, unpinned on line 4, beside the pinned plain spelling on line 3.
k=0; first_site_log=""
for s in "${STATEMENTS[@]}"; do
  k=$((k + 1))
  f="$work/spelling_$k.sql"
  planted "$f" "select throws_ok($s, NULL, 'unpinned, spelling $k');"
  run "$f"
  if [ "$k" = 1 ]; then first_site_log="$work/spelling_1.log"; printf '%s\n' "$out" > "$first_site_log"; fi
  shown=$(printf '%s' "$s" | tr -s ' \n' ' ')
  if [ "$rc" != 0 ] && grep -qF "FAIL  $f:4 accepts 2D000" <<<"$out"; then
    ok "an unpinned throws_ok around $shown fails, naming its line" "spelling_$k.sql:4"
  else
    bad "an unpinned throws_ok around $shown fails, naming its line" \
        "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
  fi
done
# Each whole line 4, likewise.
j=0
for l in "${LINES[@]}"; do
  j=$((j + 1))
  f="$work/line_$j.sql"
  planted "$f" "$l"
  run "$f"
  if [ "$rc" != 0 ] && grep -qF "FAIL  $f:4 accepts 2D000" <<<"$out"; then
    ok "an unpinned assertion is a site on the line: ${l:0:48}..." "line_$j.sql:4"
  else
    bad "an unpinned assertion is a site on the line: ${l:0:48}..." \
        "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
  fi
done

# Every statement at once, each pinned: all of them sites, all of them judged pinned, and the file passes.
f="$work/all_pinned.sql"
{ echo "create extension if not exists pgtap;"; echo "select no_plan();"; echo "$PINNED"
  for s in "${STATEMENTS[@]}"; do echo "select throws_ok($s, 'P0001', NULL, 'pinned');"; done
  echo "select * from finish();"; } > "$f"
run "$f"
want=$(( ${#STATEMENTS[@]} + 1 ))
if [ "$rc" = 0 ] && grep -qE "^PASS  every throws_\* .* $want pinned, 0 by an expression, of $want\$" <<<"$out"; then
  ok "every statement, pinned, is a site the guard judges pinned" "$want pinned of $want"
else
  bad "every statement, pinned, is a site the guard judges pinned" \
      "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
fi

# A file with nothing to judge: the guard fails on its zero-site premise, and that run is no catch. starved() is
# read out of bench/discriminate.sh, not restated, and first shown to certify a run that failed a site.
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$ROOT/bench/discriminate.sh")
if [ -n "$starved_fn" ] && eval "$starved_fn" && [ -n "$first_site_log" ] \
   && grep -q ' accepts 2D000' "$first_site_log" && ! starved "$first_site_log"; then
  ok "LIVENESS: starved() certifies the run that failed a site" "spelling_1.sql"
else
  bad "LIVENESS: starved() certifies the run that failed a site" "${starved_fn:+read, }not certified"
fi
f="$work/no_site.sql"
{ echo "create extension if not exists pgtap;"; echo "select plan(1);"; echo "select ok(true, 'nothing to probe');"
  echo "select * from finish();"; } > "$f"
run "$f"
printf '%s\n' "$out" > "$work/no_site.log"
if [ "$rc" != 0 ] && grep -qE '^FAIL  LIVENESS: the probe found at least one throws_\*' <<<"$out"; then
  ok "LIVENESS: a file with no throws_* fails the guard on its premise" "exit $rc"
else
  bad "LIVENESS: a file with no throws_* fails the guard on its premise" \
      "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
fi
if [ -n "$starved_fn" ] && starved "$work/no_site.log"; then
  ok "a run that failed only its zero-site premise is refused as starved" "starved"
else
  bad "a run that failed only its zero-site premise is refused as starved" \
      "certified as a catch: $(grep -E '^FAIL' "$work/no_site.log" | grep -vE '^FAIL  (LIVENESS|GUARD|fixture):' | tr '\n' ' ')"
fi

# The closing verdict restates the checks above (`N ran, M failed`), the shape starved() does not count.
if [ "$fail" = 0 ]; then
  ok "throws_pinned.sh judges every throws_* however it is written" "$checks ran"
else
  bad "throws_pinned.sh judges every throws_* however it is written" "$((checks + 1)) ran, $((failed + 1)) failed"
fi
exit "$fail"
