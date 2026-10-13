#!/usr/bin/env bash
# F8-07: a pg_prove wrapper (here bench/obtain_walk_reads_rows_once.sh, the shape ~130 wrappers share) whose test
# file passes its LIVENESS: premise and then RAISES at a later fixture statement prints only
# `FAIL  <label>  1 ran`, a restated verdict, with no `not ok` line. bench/discriminate.sh's starved() sets the
# restated verdict aside, finds nothing left, and so does NOT read the run as starved: discriminate counts it as
# the guard catching its mutant although no defect check ran, let alone failed (#1177 refused this only for a
# file that raised before its FIRST assertion). The wrapper and starved() are run as written, from $TREE.
# Present = starved() reads "premise passed, then the fixture raised" as a catch.
set -u
fail=0
W=$(mktemp -d); CD="/tmp/f8_r2_${DB}"
trap 'rm -rf "$W"; docker exec "$CONTAINER" rm -rf "$CD" >/dev/null 2>&1; for d in ${DB}_w1 ${DB}_w2; do docker exec "$CONTAINER" psql -U postgres -qc "drop database if exists $d" >/dev/null 2>&1; done' EXIT
fn=$(sed -n '/^starved() {/,/^}/p' "$TREE/bench/discriminate.sh")
[ -n "$fn" ] || { echo "not ok - GUARD: starved() read from discriminate.sh"; exit 1; }
eval "$fn"
cat > "$W/late.sql" <<'SQL'
create extension if not exists pgtap;
begin;
select plan(3);
select ok(true, 'LIVENESS: the fixture reached the state the defect needs');
select 1 / 0;   -- a later fixture statement the mutant breaks
select ok(true, 'the property under test holds');
select ok(true, 'and its second check');
select * from finish();
rollback;
SQL
cat > "$W/early.sql" <<'SQL'
create extension if not exists pgtap;
begin;
select plan(2);
select 1 / 0;
select ok(true, 'LIVENESS: the fixture reached the state the defect needs');
select ok(true, 'the property under test holds');
select * from finish();
rollback;
SQL
docker exec "$CONTAINER" mkdir -p "$CD"
for f in late early; do docker exec -i "$CONTAINER" sh -c "cat > $CD/$f.sql" < "$W/$f.sql"; done
docker exec -i "$CONTAINER" sh -c "cat > $CD/install.sql" < "$TREE/pgpm_core/install.sql"
TAP_GUARD_TEST_FILE="$CD/late.sql" bash "$TREE/bench/obtain_walk_reads_rows_once.sh" "$CONTAINER" "${DB}_w1" "$CD/install.sql" > "$W/late.log" 2>&1 </dev/null; rl=$?
TAP_GUARD_TEST_FILE="$CD/early.sql" bash "$TREE/bench/obtain_walk_reads_rows_once.sh" "$CONTAINER" "${DB}_w2" "$CD/install.sql" > "$W/early.log" 2>&1 </dev/null; re=$?
if [ "$rl" != 0 ] && grep -qE '^FAIL .*[[:space:]]1 ran$' "$W/late.log" && ! grep -q 'module under test installed' "$W/late.log"; then
  echo "ok - LIVENESS: (A) the wrapper installed, ran the file, reached its one premise and failed (1 ran)"
else echo "not ok - LIVENESS: (A) the wrapper installed, ran the file, reached its one premise and failed (exit $rl)"; sed 's/^/    /' "$W/late.log" | head -5; fail=1; fi
if [ "$re" != 0 ] && starved "$W/early.log"; then
  echo "ok - LIVENESS: (B) the rule works: a file raising before its first assertion is read as starved"
else echo "not ok - LIVENESS: (B) the rule works: a file raising before its first assertion is read as starved"; fail=1; fi
if starved "$W/late.log"; then
  echo "ok - a run that passed only its premise and then raised is read as starved, not as a catch"
else
  echo "not ok - a run that passed only its premise and then raised is read as starved, not as a catch (starved() calls it a catch: $(grep '^FAIL' "$W/late.log" | tr -s ' ' | head -1))"
  fail=1
fi
exit "$fail"
