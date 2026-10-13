#!/usr/bin/env bash
# F14-02: tests/260's "LIVENESS: (A) and those are every row the fixture wrote, so the comparison above was
# over something" compares count(public.ny) with count(ny_before), a copy of public.ny taken before the
# regrain. It is implied by the identity check it follows and holds when both are EMPTY, so it cannot tell a
# fixture that wrote nothing from one that wrote every row: the premise it names is not witnessed.
# The assertion is read from $TREE, not pasted, and evaluated over an empty fixture.
set -u
F="$TREE/tests/260_regrain_calendar_clamped_name_test.sql"
n=$(grep -n "LIVENESS: (A) and those are every row the fixture wrote" "$F" | head -1 | cut -d: -f1)
if [ -z "$n" ]; then echo "not ok - GUARD: the LIVENESS line is not in tests/260 (the defect is absent or moved)"; exit 0; fi
start=$(awk -v n="$n" 'NR<=n && /^select is\(/ {s=NR} END{print s}' "$F")
stmt=$(sed -n "${start},${n}p" "$F")
out=$($PSQL -tA <<SQL 2>&1
create extension if not exists pgtap;
create table public.ny (id text primary key, body text);
create temp table ny_before as select id from public.ny;
select plan(2);
select ok((select count(*) = 0 from public.ny) and (select count(*) = 0 from ny_before),
  'LIVENESS: the fixture wrote nothing: public.ny and ny_before are both empty');
$stmt
select * from finish();
SQL
)
echo "$out" | grep -E "^(not )?ok" | sed 's/^/# tests\/260 under an empty fixture: /'
if ! echo "$out" | grep -q "^ok 1 - LIVENESS: the fixture wrote nothing"; then
  echo "not ok - LIVENESS: the empty-fixture state was not reached"; exit 1
fi
echo "ok - LIVENESS: the empty-fixture state was reached"
if echo "$out" | grep -q "^ok 2 - LIVENESS: (A) and those are every row"; then
  echo "not ok - tests/260's LIVENESS premise passes over a fixture that wrote no row, so it witnesses nothing"
  exit 1
fi
echo "ok - tests/260's LIVENESS premise refuses an empty fixture"
