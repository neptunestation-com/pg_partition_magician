#!/usr/bin/env bash
# Prove the timescale and observe tracks call a pgTAP file failed whenever pg_prove would, by reading each
# track's verdict condition out of test.sh and holding it to real pgTAP output.
#
# WHY THIS GUARD EXISTS (issue #601). Those two tracks do not run pg_prove: they run each file with
# `psql -tAq` and call it failed when the output matches a grep. The grep knew a failed assertion
# (`not ok`, "# Looks like you failed ...") and an error, but not pgTAP's report of a file that ran FEWER
# assertions than it planned ("# Looks like you planned 3 tests but ran 2"). So a file whose assertion
# silently never ran (a `select ok(...) from t` over zero rows, an assertion deleted without lowering
# plan()) was PASSED by both tracks, while pg_prove, the matrix and archive tracks' runner, fails it.
#
# AND A LOST SESSION (issue #819, F9-01). The same two verdicts never read psql's exit status, so a file
# whose session died part-way (FATAL, a lost connection, no ERROR:) never reached finish() to print the
# shortfall line, and the verdict PASSED it after 1 of 3 planned assertions (the #795 shape the timescale
# wrappers were cured of). In the track as run, `set -e` then ended test.sh at that psql call, so the
# track failed with no verdict, no teardown and the rest of its files unrun: a crash, not a check. The
# psql call now keeps its exit status, and the verdict fails any file psql did not run to its end.
#
# HOW. Each track's verdict REGION is read out of its run_<track>() body in test.sh, as written: from the
# line that runs the file (`out=$(... -tAq ...)`, the exit-status capture included) to the `fi` that ends
# its verdict. It is evaluated with the track's psql prefix pointed at a stand-in that replays what psql
# -tAq printed for each of these pgTAP files run in <container>, and exits as psql did:
#   clean            plan(2), two passing assertions                          -> the track must PASS it
#   failed           plan(2), one failing assertion                            -> FAIL
#   shortfall        plan(3), the third assertion over an empty table          -> FAIL (#601)
#   error            plan(2), a statement that errors between assertions       -> FAIL
#   lost_midfile     plan(3), the session terminated after the first (#819)    -> FAIL (psql exits 2)
#   lost_after_plan  plan(1), one passing assertion, finish(), then terminated -> FAIL (psql exits 2)
# LIVENESS: each region was found; each fixture really has its shape (pgTAP printed the shortfall line and
# psql exited 0 there, the lost ones printed no such line and psql exited non-zero); pg_prove, the
# reference, PASSES the clean file and FAILS every other one; and each evaluation ran the region's psql
# call exactly once and reached a verdict, so "the track agrees with pg_prove" is not satisfied by a
# verdict that fails everything, by fixtures that never ran, or by a region that died before it judged.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   tap_verdict_misses_plan_shortfall -- both tracks' pattern put back to one without the plan line
#   tap_verdict_ignores_psql_exit     -- both tracks back to the pre-#819 shape: psql's exit neither
#                                        captured nor read by the verdict
#
# Usage: tap_verdict.sh <container> <db> [test.sh]
# The container needs pgtap and pg_prove (the plain core image has both). A /repo/... path is mapped to
# this checkout, which is how bench/discriminate.sh points it at a mutant.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="${3:-$ROOT/test.sh}"
TS="${TS/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-58s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-58s %s\n' "$1" "$2"; fail=1; }
q() { docker exec -i "$C" psql -U postgres "$@"; }

if [ ! -f "$TS" ]; then bad "the test.sh under test exists" "$TS"; exit 1; fi
body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}/ {exit}' "$TS"; }
# The verdict region: from the line that runs the file through psql -tAq to the `fi` closing its verdict.
region() {
  body "$1" | awk '!g && /out=\$\(/ && /-tAq/ {g=1} g {print} g && /(^|[;[:space:]])fi[[:space:]]*$/ {exit}'
}
# The track's psql prefix, pointed here: it replays the fixture named by $CUR as psql printed it and exits
# as psql did, and counts its calls, so an evaluation that never ran the file cannot read as a verdict.
tv_psql() { echo x >> "$work/calls"; cat "$work/$CUR.out"; return "$(cat "$work/$CUR.rc")"; }
# judge <region> <fixture>: the region evaluated as written, in a subshell; prints the track's fail flag,
# or nothing when the region died before it judged (an unbound variable under set -u, say).
judge() {
  : > "$work/calls"
  # shellcheck disable=SC2034  # CUR, DC, px, db, f and tag are read by the evaluated region (test.sh's text)
  ( CUR="$2"; DC=""; px=(tv_psql); db="$DB"; f="tap_verdict_$2.sql"; tag=probe; fail=0
    eval "$1" >/dev/null 2>&1 </dev/null; echo "$fail" )
}

work=$(mktemp -d); trap 'rm -rf "$work"; q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1' EXIT
cat > "$work/clean.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select ok(true, 'two');
select * from finish();
SQL
cat > "$work/failed.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select ok(false, 'two fails');
select * from finish();
SQL
cat > "$work/shortfall.sql" <<'SQL'
create extension if not exists pgtap;
create temp table tap_verdict_rows (x int);
select plan(3);
select ok(true, 'one');
select ok(true, 'two');
select ok(x > 0, 'three: over the rows of an empty table, so it never runs') from tap_verdict_rows;
select * from finish();
SQL
cat > "$work/lost_midfile.sql" <<'SQL'
create extension if not exists pgtap;
select plan(3);
select ok(true, 'one');
select pg_terminate_backend(pg_backend_pid());
select ok(true, 'two');
select ok(true, 'three');
select * from finish();
SQL
cat > "$work/lost_after_plan.sql" <<'SQL'
create extension if not exists pgtap;
select plan(1);
select ok(true, 'one');
select * from finish();
select pg_terminate_backend(pg_backend_pid());
SQL
cat > "$work/error.sql" <<'SQL'
create extension if not exists pgtap;
select plan(2);
select ok(true, 'one');
select 1 / 0;
select ok(true, 'two');
select * from finish();
SQL

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
FIXTURES="clean failed shortfall error lost_midfile lost_after_plan"
for f in $FIXTURES; do
  # exactly how the tracks run a file: -tAq, no ON_ERROR_STOP, stderr folded in, the exit status kept
  q -d "$DB" -tAq -f - < "$work/$f.sql" > "$work/$f.out" 2>&1
  echo $? > "$work/$f.rc"
done

rc_of() { cat "$work/$1.rc"; }
if grep -q '^# Looks like you planned 3 tests but ran 2' "$work/shortfall.out" && [ "$(rc_of shortfall)" = 0 ]; then
  ok "LIVENESS: pgTAP reported the plan shortfall, psql exited 0" "planned 3, ran 2"
else
  bad "LIVENESS: pgTAP reported the plan shortfall, psql exited 0" \
    "rc=$(rc_of shortfall) $(tr '\n' ' ' < "$work/shortfall.out" | cut -c1-80)"
fi
lost_shape() { # <fixture> <plan> <oks>: psql exited non-zero after that plan line and that many ok, silently
  local o="$work/$1.out"
  [ "$(rc_of "$1")" != 0 ] && grep -qx "1\.\.$2" "$o" && [ "$(grep -cE '^ok [0-9]+' "$o")" = "$3" ] \
    && ! grep -qE '^# Looks like|^not ok|ERROR:' "$o"
}
for spec in "lost_midfile 3 1 runs 1 of 3, prints no not ok, ERROR: or finish() line" \
            "lost_after_plan 1 1 runs its plan and finish(), then loses its session"; do
  read -r f p n what <<<"$spec"
  if lost_shape "$f" "$p" "$n"; then ok "LIVENESS: the $f file $what" "psql exit $(rc_of "$f")"
  else bad "LIVENESS: the $f file $what" "rc=$(rc_of "$f") $(tr '\n' ' ' < "$work/$f.out" | cut -c1-80)"; fi
done
ref() {  # pg_prove's exit status for one fixture
  docker exec -i "$C" sh -c "cat > /tmp/tap_verdict_$DB.sql" < "$work/$1.sql"
  docker exec "$C" pg_prove -U postgres -d "$DB" "/tmp/tap_verdict_$DB.sql" >/dev/null 2>&1; local rc=$?
  docker exec "$C" rm -f "/tmp/tap_verdict_$DB.sql"
  return "$rc"
}
for f in $FIXTURES; do
  if [ "$f" = clean ]; then
    if ref clean; then ok "LIVENESS: pg_prove passes the clean file" "exit 0"
    else bad "LIVENESS: pg_prove passes the clean file" "it failed"; fi
  elif ref "$f"; then bad "LIVENESS: pg_prove fails the $f file" "it passed"
  else ok "LIVENESS: pg_prove fails the $f file" "non-zero"; fi
done

for track in run_timescale run_observe; do
  r=$(region "$track")
  # shellcheck disable=SC2016  # the literal text "$out", as test.sh spells it
  if [ -z "$r" ] || ! grep -qF '"$out"' <<<"$r"; then bad "LIVENESS: found $track's verdict region" "none"; continue; fi
  ok "LIVENESS: found $track's verdict region" "$(wc -l <<<"$r" | tr -d ' ') lines"
  for f in $FIXTURES; do
    want=FAIL; [ "$f" = clean ] && want=PASS
    v=$(judge "$r" "$f"); calls=$(wc -l < "$work/calls" | tr -d ' ')
    if [ "$calls" != 1 ] || { [ "$v" != 0 ] && [ "$v" != 1 ]; }; then
      bad "$track: its verdict region ran the $f file once and reached a verdict" "$calls call(s), fail='$v'"
      continue
    fi
    if [ "$v" = 1 ]; then got=FAIL; else got=PASS; fi
    if [ "$got" = "$want" ]; then ok "$track calls the $f file $want" "$got"
    else bad "$track calls the $f file $want" "$got"; fi
  done
done
exit "$fail"
