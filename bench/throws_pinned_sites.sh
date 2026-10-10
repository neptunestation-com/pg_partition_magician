#!/usr/bin/env bash
# Prove that bench/throws_pinned.sh finds a throws_* assertion around a CALL of a pgpm procedure however that
# procedure is named, by running it over planted test files and reading which lines it judges.
#
# WHY THIS GUARD EXISTS (issue #1182, F8-10). throws_pinned.sh used to call a statement a site only when its
# text matched `call\s+pgpm\.`. A throws_ok($$ call "pgpm".transmute(...) $$, NULL, desc) names the same
# committing procedure, and its NULL accepts the same 2D000 a transmute that did not refuse dies with inside
# pgTAP, but the quoted schema made it no site at all: the guard probed the file's pinned neighbour, printed
# "1 pinned of 1" and exited 0. throws_pinned.sh now reads the procedure the statement calls (its calls_pgpm),
# and this guard holds it to that from the outside, on whole files, the way the perf track runs it.
#
# WHAT IT ASSERTS, each planted file holding a pinned throws_ok in the plain spelling on line 3 beside it:
#   for each SPELLING below (quoted schema, case and whitespace around the dot, a comment inside the name, a
#   name split over lines, an unqualified call, a U&"..." schema, a statement built by format() with the schema
#   as %I), an unpinned throws_ok(<statement>, NULL, desc) on line 4 FAILS the guard, and the failure names THAT line
#   as accepting 2D000 (identity, not an exit code: a guard that failed for any other reason names no line);
#   every spelling at once, each PINNED, is a site the guard judges: it passes the file with all of them
#   counted as pinned.
#   LIVENESS: the guard under test ran its controls (the substituted statement raised 2D000 inside the
#   wrapper and NULL accepted it), so a failure above is about the site and not a broken instrument; and it
#   PASSES a file whose only unpinned throws_ok calls another schema's procedure (pg_temp.mk), so it does not
#   fail every file it is given, which would satisfy every check above without reading a name.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   throws_pinned_site_by_spelling -- throws_pinned.sh deciding a site with the pre-#1182 `call\s+pgpm\.`
#                                     search again. Its own self-check still passes (it exercises calls_pgpm,
#                                     which the mutant leaves intact but no longer consults), which is why the
#                                     recogniser is held here, on files, as well.
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
fail=0
ok()  { printf 'PASS  %-70s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-70s %s\n' "$1" "$2"; fail=1; }
if [ ! -f "$G" ]; then bad "the throws_pinned.sh under test exists" "$G"; exit 1; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Each statement as a test file writes it: the first argument of the throws_ok, verbatim.
SPELLINGS=(
  "\$\$ call \"pgpm\".transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ CALL PGPM . \"transmute\"('public.t1182', 'id', 10) \$\$"
  "\$\$ call /* the maintenance tick */ pgpm./* of t1182 */maintain('public.t1182') \$\$"
  "\$\$ call
       \"pgpm\"
       .transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ call transmute('public.t1182', 'id', 10) \$\$"
  "\$\$ call U&\"\\0070gpm\".U&\"m\\0061intain\"('public.t1182') \$\$"
  "format('call %I.transmute(%L, %L, 10)', 'pgpm', 'public.t1182', 'id')"
)
PINNED="select throws_ok(\$\$ call pgpm.transmute('public.t1182', 'id', 10) \$\$, 'P0001', NULL, 'pinned, the plain spelling');"

n=0
# run <file>: the guard under test over <file> alone, its output in $out and its exit status in $rc.
run() {
  n=$((n + 1))
  out=$(bash "$G" "$C" "${DB}_$n" "$1" 2>&1 </dev/null); rc=$?
}

# LIVENESS: the guard under test runs, and does not fail a file it has no reason to fail.
f="$work/other_schema.sql"
{ echo "create extension if not exists pgtap;"; echo "select plan(2);"; echo "$PINNED"
  echo "select throws_ok(\$\$ call pg_temp.mk('public.t1182') \$\$, NULL, 'unpinned, but no pgpm procedure');"
  echo "select * from finish();"; } > "$f"
run "$f"
if grep -q '^PASS  control: 2D000 is raised inside the wrapper and NULL accepts it' <<<"$out"; then
  ok "LIVENESS: the guard under test ran its controls" "2D000 raised, NULL accepts it"
else
  bad "LIVENESS: the guard under test ran its controls" "$(grep -m1 -E '^FAIL' <<<"$out")"
fi
if [ "$rc" = 0 ] && grep -qE '^PASS  every throws_\* .* 1 pinned, 0 by an expression, of 1$' <<<"$out"; then
  ok "LIVENESS: it passes a file whose unpinned throws_ok calls no pgpm procedure" "1 pinned of 1"
else
  bad "LIVENESS: it passes a file whose unpinned throws_ok calls no pgpm procedure" \
      "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
fi

# Each spelling, unpinned on line 4, beside the pinned plain spelling on line 3.
k=0
for s in "${SPELLINGS[@]}"; do
  k=$((k + 1))
  f="$work/spelling_$k.sql"
  { echo "create extension if not exists pgtap;"; echo "select plan(2);"; echo "$PINNED"
    echo "select throws_ok($s, NULL, 'unpinned, spelling $k');"
    echo "select * from finish();"; } > "$f"
  run "$f"
  shown=$(printf '%s' "$s" | tr -s ' \n' ' ')
  if [ "$rc" != 0 ] && grep -qF "FAIL  $f:4 accepts 2D000" <<<"$out"; then
    ok "an unpinned throws_ok around $shown fails, naming its line" "spelling_$k.sql:4"
  else
    bad "an unpinned throws_ok around $shown fails, naming its line" \
        "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
  fi
done

# Every spelling at once, each pinned: all of them sites, all of them judged pinned, and the file passes.
f="$work/all_pinned.sql"
{ echo "create extension if not exists pgtap;"; echo "select no_plan();"; echo "$PINNED"
  for s in "${SPELLINGS[@]}"; do echo "select throws_ok($s, 'P0001', NULL, 'pinned');"; done
  echo "select * from finish();"; } > "$f"
run "$f"
want=$(( ${#SPELLINGS[@]} + 1 ))
if [ "$rc" = 0 ] && grep -qE "^PASS  every throws_\* .* $want pinned, 0 by an expression, of $want\$" <<<"$out"; then
  ok "every spelling, pinned, is a site the guard judges pinned" "$want pinned of $want"
else
  bad "every spelling, pinned, is a site the guard judges pinned" \
      "exit $rc: $(grep -E '^(FAIL|PASS  every)' <<<"$out" | tr '\n' ' ')"
fi

if [ "$fail" = 0 ]; then
  ok "throws_pinned.sh finds a pgpm call however it is spelled" "$k spellings"
else
  bad "throws_pinned.sh finds a pgpm call however it is spelled" "see above"
fi
exit "$fail"
