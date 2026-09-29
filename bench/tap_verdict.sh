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
# HOW. The `if ... "$out" ...; then` line that decides each track's verdict is read out of its
# run_<track>() body in test.sh, as written, and evaluated with $out set to what psql -tAq printed for
# four pgTAP files run in <container>:
#   clean      plan(2), two passing assertions                      -> the track must PASS it
#   failed     plan(2), one failing assertion                        -> FAIL
#   shortfall  plan(3), the third assertion over an empty table      -> FAIL (the case #601 is about)
#   error      plan(2), a statement that errors between assertions   -> FAIL
# LIVENESS: each verdict line was found; pgTAP really printed the shortfall line; and pg_prove, the
# reference, PASSES the clean file and FAILS the shortfall one, so "the track agrees with pg_prove" is
# not satisfied by a verdict that fails everything or by fixtures that never ran.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   tap_verdict_misses_plan_shortfall -- both tracks' pattern put back to one without the plan line
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
cond() { body "$1" | grep -m1 -E '^[[:space:]]*if .*"\$out".*; then' | sed -E 's/^[[:space:]]*if (.*); then.*$/\1/'; }
# The condition is evaluated as written; exit 0 means the track would call the file FAILED.
# shellcheck disable=SC2034  # $out is read by the evaluated condition, which is test.sh's own text
track_fails() { local out="$2"; eval "$1"; }

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
for f in clean failed shortfall error; do
  # exactly how the tracks run a file: -tAq, no ON_ERROR_STOP, stderr folded in
  q -d "$DB" -tAq -f - < "$work/$f.sql" > "$work/$f.out" 2>&1
done

if grep -q '^# Looks like you planned 3 tests but ran 2' "$work/shortfall.out"; then
  ok "LIVENESS: pgTAP reported the plan shortfall" "planned 3, ran 2"
else
  bad "LIVENESS: pgTAP reported the plan shortfall" "$(tr '\n' ' ' < "$work/shortfall.out" | cut -c1-80)"
fi
ref() {  # pg_prove's exit status for one fixture
  docker exec -i "$C" sh -c "cat > /tmp/tap_verdict_$DB.sql" < "$work/$1.sql"
  docker exec "$C" pg_prove -U postgres -d "$DB" "/tmp/tap_verdict_$DB.sql" >/dev/null 2>&1; local rc=$?
  docker exec "$C" rm -f "/tmp/tap_verdict_$DB.sql"
  return "$rc"
}
if ref clean; then ok "LIVENESS: pg_prove passes the clean file" "exit 0"
else bad "LIVENESS: pg_prove passes the clean file" "it failed"; fi
if ref shortfall; then bad "LIVENESS: pg_prove fails the shortfall file" "it passed"
else ok "LIVENESS: pg_prove fails the shortfall file" "non-zero"; fi

for track in run_timescale run_observe; do
  c=$(cond "$track")
  if [ -z "$c" ]; then bad "LIVENESS: found $track's verdict condition" "none"; continue; fi
  ok "LIVENESS: found $track's verdict condition" "${c:0:40}..."
  for f in clean failed shortfall error; do
    want=FAIL; [ "$f" = clean ] && want=PASS
    if track_fails "$c" "$(cat "$work/$f.out")"; then got=FAIL; else got=PASS; fi
    if [ "$got" = "$want" ]; then ok "$track calls the $f file $want" "$got"
    else bad "$track calls the $f file $want" "$got"; fi
  done
done
exit "$fail"
