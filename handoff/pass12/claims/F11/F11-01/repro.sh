#!/usr/bin/env bash
# F11-01: bench/retire_pending_detach.sh's UPGRADE phase labels its data-survival check "[100, 200) still holds
# rows 111, 112 and 113" but asserts count(*) = 3, so it accepts a partition whose rows are NOT those three (a
# row lost and another appearing cancel). The check is read out of $TREE and evaluated, with the guard's own
# v() semantics, against a planted [100, 200) holding 111, 112 and 150. Present: the guard's check prints PASS.
set -uo pipefail
: "${PSQL:?}" "${TREE:?}"
G="$TREE/bench/retire_pending_detach.sh"
fail=0
say() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "not ok - $2"; fail=1; fi; }

# fixture: public.up managed on id with step 100; [100, 200) holds 111, 112 and 150 (not 113)
$PSQL -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
set client_min_messages = warning;
create table public.up (id bigint primary key, payload text);
insert into public.up values (111, 'u1'), (112, 'u2'), (150, 'stranger');
call pgpm.transmute('public.up', 'id', 100, p_obtain => 3);
SQL
say $? "fixture: public.up transmuted"

ids=$($PSQL -tAq -c "select string_agg(id::text, ',' order by id) from public.up where id >= 100 and id < 200")
child=$($PSQL -tAq -c "select child_name from pgpm.part where parent_table = 'public.up'::regclass and lo = '100'")
[ -n "$child" ] && [ "$ids" = "111,112,150" ]
say $? "LIVENESS: [100, 200) is a recorded partition ($child) holding 111,112,150, not 111,112,113 (got $ids)"

# the guard's check, as written in the tree
src=$(grep -n 'still holds rows 111, 112 and 113' -A1 "$G")
[ -n "$src" ]
say $? "LIVENESS: the guard still carries its 'still holds rows 111, 112 and 113' check"
stmt=$(grep 'still holds rows 111, 112 and 113' -A1 "$G")

# the guard's helpers, pointed at this database: v() as the guard defines it, check() recording the verdict
v() { $PSQL -tAq -c "$2" 2>&1 | tail -1; }
verdict=""
check() { if [ "$2" = "$3" ]; then verdict="PASS ($2)"; else verdict="FAIL (got $2, want $3)"; fi; }
kind=pre; udb=unused
eval "$stmt"
[ -n "$verdict" ]
say $? "LIVENESS: the extracted check ran and gave a verdict ($verdict)"

# defect check: a partition holding 111, 112 and 150 is not one holding 111, 112 and 113
[[ "$verdict" == FAIL* ]]
say $? "the guard's 'still holds rows 111, 112 and 113' check refuses a partition holding 111, 112 and 150 (it said $verdict)"
exit "$fail"
