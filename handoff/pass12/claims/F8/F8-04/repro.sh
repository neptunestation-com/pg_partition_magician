#!/usr/bin/env bash
# F8-04: bench/retire_pending_detach.sh labels its UPGRADE survival check "[100, 200) still holds rows 111, 112
# and 113" and asserts count(*) = 3 over the partition: a cardinality check under an identity label, which a
# partition that lost 113 and gained a stranger also satisfies. The check is read from $TREE (the line after
# the label) and evaluated as the guard evaluates it, against such a partition.
# Present = the guard's check accepts a [100, 200) partition that does not hold row 113.
set -u
fail=0
G="$TREE/bench/retire_pending_detach.sh"
expr=$(grep -A1 -F 'still holds rows 111, 112 and 113' "$G" | tail -1)
if [ -n "$expr" ] && grep -q 'count(\*)' <<<"$expr"; then echo "ok - LIVENESS: (A) the guard's survival check was read from the tree"
else echo "not ok - LIVENESS: (A) the guard's survival check was read from the tree"; exit 1; fi

$PSQL -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
set client_min_messages = warning;
create table public.up (id bigint primary key, payload text);
insert into public.up values (111, 'u1'), (112, 'u2'), (113, 'u3');
call pgpm.transmute('public.up', 'id', 100, p_obtain => 6, p_paused => true);
SQL
# The partition loses row 113 and gains a stranger, 114: same count, not the same rows.
$PSQL -q -c "delete from public.up where id = 113; insert into public.up values (114, 'stranger')" >/dev/null 2>&1
held=$($PSQL -tAc "select string_agg(id::text, ',' order by id) from public.up
                    where tableoid = (select child_oid from pgpm.part where parent_table = 'public.up'::regclass and lo = '100')" 2>&1)
if [ "$held" = "111,112,114" ]; then echo "ok - LIVENESS: (B) [100, 200) holds 111, 112 and 114, not 113"
else echo "not ok - LIVENESS: (B) [100, 200) holds 111, 112 and 114, not 113 (got: $held)"; fail=1; fi

# The guard's own helpers, pointed at this database.
v() { $PSQL -tAq -c "$2" 2>&1 | tail -1; }
udb="$DB"
eval "set -- $expr"
got="$1"; want="${2:-}"
if [ -n "$got" ] && [ -n "$want" ] && ! grep -qi 'error' <<<"$got"; then echo "ok - LIVENESS: (C) the guard's check evaluated here (got $got, want $want)"
else echo "not ok - LIVENESS: (C) the guard's check evaluated here (got '$got', want '$want')"; fail=1; fi
if [ "$got" = "$want" ]; then
  echo "not ok - the check labelled 'still holds rows 111, 112 and 113' refuses a partition without 113 (it passes: $got = $want)"
  fail=1
else
  echo "ok - the check labelled 'still holds rows 111, 112 and 113' refuses a partition without 113"
fi
exit "$fail"
