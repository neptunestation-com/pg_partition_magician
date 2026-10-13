#!/usr/bin/env bash
# tests/timescale/db/66's "LIVENESS: and no scratch record is left for any" asks pgpm.scratch for parent_oid IN
# ('public.d66'::regclass::oid, 't66', 'e66') AFTER all three migrations, when those names resolve to the NEW
# partitioned tables, never the hypertables' oids the records are keyed by. So it cannot see a record the swap
# left behind. This runs the file from $TREE against a copy of pgpm.from_hypertable_cutover (built from the
# installed tree's own definition) without its `delete from pgpm.scratch where parent_oid = p_hypertable::oid`,
# and requires the assertion to catch that copy.
set -u
fail=0
$PSQL -q -v ON_ERROR_STOP=1 -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# the broken copy: the swap's scratch delete removed, the rest of the installed procedure as it is
$PSQL -q -v ON_ERROR_STOP=1 -f - >/dev/null <<'SQL'
do $$
declare r record; v text; n int := 0;
begin
  for r in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'pgpm' and p.proname = 'from_hypertable_cutover' loop
    v := pg_get_functiondef(r.oid);
    if position('delete from pgpm.scratch where parent_oid = p_hypertable::oid;' in v) > 0 then
      v := replace(v, 'delete from pgpm.scratch where parent_oid = p_hypertable::oid;', 'null;');
      execute v;
      n := n + 1;
    end if;
  end loop;
  create table public.f10_mutated (n int);
  insert into public.f10_mutated values (n);
end $$;
SQL
m=$($PSQL -tAc "select n from public.f10_mutated")
if [ "$m" = "1" ]; then echo "ok - LIVENESS: the broken copy of from_hypertable_cutover is installed (its scratch delete removed)"; else echo "not ok - LIVENESS: the broken copy of from_hypertable_cutover is installed (got: $m)"; fail=1; fi

# the hypertables' oids, which the scratch records are keyed by, are learnt from the file's own run below:
# every scratch row whose parent no longer exists is one the swap left behind
out=$($PSQL -tA -v ON_ERROR_STOP=0 -f - < "$TREE/tests/timescale/db/66_from_hypertable_column_unit_rules_test.sql" 2>&1)
echo "$out" | grep -E '^(not )?ok ' | sed 's/^/  66: /'

left=$($PSQL -tAc "select count(*) from pgpm.scratch s where not exists (select 1 from pg_class c where c.oid = s.parent_oid)")
cut=$($PSQL -tAc "select count(*) from pg_class where oid in (to_regclass('public.d66'), to_regclass('public.t66'), to_regclass('public.e66')) and relkind = 'p'")
if [ "$cut" = "3" ]; then echo "ok - LIVENESS: all three hypertables were migrated by the broken copy"; else echo "not ok - LIVENESS: all three hypertables were migrated (got $cut)"; fail=1; fi
if [ "${left:-0}" -gt 0 ]; then echo "ok - LIVENESS: the broken copy left $left pgpm.scratch rows keyed by the dropped hypertables' oids"; else echo "not ok - LIVENESS: the broken copy left scratch rows behind (got ${left:-none})"; fail=1; fi

line=$(echo "$out" | grep -E '^(not )?ok [0-9]+ - LIVENESS: and no scratch record is left for any' | head -1)
if [ -z "$line" ]; then
  echo "not ok - GUARD: tests/66's 'and no scratch record is left for any' assertion ran"; fail=1
elif echo "$line" | grep -q '^ok '; then
  echo "not ok - tests/66 reports '$line' with $left scratch rows of the cut-over hypertables left behind: the assertion asks the new tables' oids and cannot see them"
  fail=1
else
  echo "ok - tests/66's scratch assertion catches the records the broken swap left behind"
fi
exit $fail
