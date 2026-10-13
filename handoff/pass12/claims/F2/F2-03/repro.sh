#!/usr/bin/env bash
# F2-03: the upgrade block's warn_grid_off_unit (and the reference's warn_grid_off_unit row) says of a date grid
# an older install anchored at 12:00 UTC that "every partition obtain mints is attached at other bounds than
# pgpm.part records for it". For a MONTH step that is false: _grid_floor's calendar branch uses only the
# anchor's month, so every bound is midnight UTC and pgpm.part and the catalog agree. The warning sends the
# operator to a reconversion (copy every row into a new table) for a grid whose bounds are right.
set -u
fail=0
q() { $PSQL -v ON_ERROR_STOP=1 -tAc "$1"; }
$PSQL -v ON_ERROR_STOP=1 -q >/dev/null <<'SQL'
set client_min_messages = warning; set timezone = 'UTC';
create table public.dn (id bigint, dt date not null, primary key (id, dt));
insert into public.dn select g, current_date - (g % 40) from generate_series(1, 80) g;
call pgpm.transmute('public.dn', 'dt', interval '1 month', p_obtain => 1);
-- the older install's registration (tests/324's d324 fixture): a date grid anchored at noon
update pgpm.config set partition_anchor = '2000-01-01 12:00:00+00' where parent_table = 'public.dn'::regclass;
select pgpm.extend_to('public.dn', (current_date + 200)::text);
SQL
anchor=$(q "set timezone='UTC'; select partition_anchor || '/' || partition_step from pgpm.config where parent_table = 'public.dn'::regclass" | tail -1)
if [ "$anchor" = "2000-01-01 12:00:00+00/1 mon" ]; then echo "ok - LIVENESS: dn is registered as a monthly date grid anchored at 12:00 UTC"; else echo "not ok - LIVENESS: dn is registered as a monthly date grid anchored at 12:00 UTC (got $anchor)"; fail=1; fi
minted=$(q "select count(*) from pgpm.part p where p.parent_table = 'public.dn'::regclass and p.lo::timestamptz > now()")
if [ "$minted" -ge 5 ]; then echo "ok - LIVENESS: partitions were minted after the anchor was planted ($minted)"; else echo "not ok - LIVENESS: partitions were minted after the anchor was planted ($minted)"; fail=1; fi
mism=$(q "set timezone='UTC'; select count(*) from pgpm.part p join pg_class c on c.oid = p.child_oid
           where p.parent_table = 'public.dn'::regclass
             and pg_get_expr(c.relpartbound, c.oid) is distinct from format('FOR VALUES FROM (%L) TO (%L)',
                   ((p.lo::timestamptz) at time zone 'UTC')::date, ((p.hi::timestamptz) at time zone 'UTC')::date)
              or ((p.lo::timestamptz) at time zone 'UTC')::time <> '00:00' or ((p.hi::timestamptz) at time zone 'UTC')::time <> '00:00'" | tail -1)
if [ "$mism" = "0" ]; then echo "ok - LIVENESS: every partition's recorded bounds are the catalog's (midnight UTC, the date the catalog holds)"; else echo "not ok - LIVENESS: every partition's recorded bounds are the catalog's ($mism differ)"; fail=1; fi
# the upgrade
$PSQL -v ON_ERROR_STOP=1 -q -f - < "$TREE/pgpm_core/install.sql" >/dev/null 2>&1 || { echo "not ok - fixture: re-running install.sql"; exit 1; }
bad=$(q "select count(*) from pgpm.log where parent_table = 'public.dn'::regclass and action = 'warn_grid_off_unit'
          and method like '%every partition obtain mints is attached at other bounds than pgpm.part records for it%'")
if [ "$bad" = "0" ]; then echo "ok - the upgrade does not tell the operator dn's partitions are attached at other bounds than pgpm.part records"
else echo "not ok - the upgrade logs warn_grid_off_unit for dn claiming every minted partition is attached at other bounds than pgpm.part records, while every one agrees"; fail=1; fi
exit $fail
