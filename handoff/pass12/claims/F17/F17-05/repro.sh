#!/bin/bash
# F17-05: scripts/archive_partition_whole.sql hands a partition the operator DETACHed by hand to the archive
# strategy. docs/reference.md (the archive step's contract check: "A table the operator detached by hand is
# not one of its candidates either ... the call goes to the next eligible partition") and CHANGELOG #1159
# promise it asks pgpm._part_detached_by_hand; its candidate query (whose comment still says so) does not.
# A strategy reading the range through the parent, as pgpm_archive's do, finds none of the table's rows,
# the script records [lo, hi) as covered, and once the operator attaches the table back retain() drops rows
# nothing archived. The script is read from $TREE.
set -u
fail=0
ok()   { echo "ok - $1"; }
nok()  { echo "not ok - $1"; fail=1; }
q()    { $PSQL -tAq -c "$1" 2>&1; }

$PSQL -q >/dev/null 2>&1 <<'SQL'
create table public.t (id bigint primary key, v text not null);
insert into public.t select g, 'm' || g from generate_series(1, 50) g;
call pgpm.transmute('public.t', 'id', 100::bigint, p_obtain => 5, p_retain => 150::bigint);
insert into public.t select g, 'f' || g from generate_series(100, 450) g;
-- a strategy that cannot make progress yet: the tick write-blocks, archives nothing, drops nothing
create function public.arch_raise(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$ begin raise exception 'bucket not reachable yet'; end $f$;
-- a strategy that reads its range THROUGH THE PARENT, as pgpm_archive's transports do
create function public.arch_read(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$
declare n bigint;
begin
  execute format('select count(*) from %s where id >= %L::bigint and id < %L::bigint', p_parent, p_lo, p_hi) into n;
  return (p_hi, n, null, null)::pgpm.archive_result;
end $f$;
select pgpm.set_archive_fn('public.t', 'public.arch_raise(regclass,name,text,text)'::regprocedure);
select pgpm.resume('public.t');
SQL
$PSQL -q -c "call pgpm.maintain('public.t')" >/dev/null 2>&1
P=$(q "select child_name from pgpm.part where parent_table = 'public.t'::regclass and lo = '0'")
N=$(q "select child_name from pgpm.part where parent_table = 'public.t'::regclass and lo = '100'")
blk=$(q "select count(*) from pg_trigger where tgname = 'pgpm_write_block' and tgrelid in ('public.$P'::regclass, 'public.$N'::regclass) and tgenabled = 'A'")
[ "$blk" = "2" ] && ok "LIVENESS: maintain write-blocked $P [0, 100) and $N [100, 200), archiving nothing" \
                 || { echo "not ok - LIVENESS: both oldest partitions write-blocked (got $blk)"; exit 1; }
cov=$(q "select count(*) from pgpm.archive_ledger where parent_table = 'public.t'::regclass")
[ "$cov" = "0" ] && ok "fixture: nothing is archived yet" || { echo "not ok - fixture: ledger empty (got $cov)"; exit 1; }

# The operator keeps [0, 100) by detaching it by hand; then a working strategy is configured.
q "alter table public.t detach partition public.$P" >/dev/null
q "select pgpm.set_archive_fn('public.t', 'public.arch_read(regclass,name,text,text)'::regprocedure)" >/dev/null
det=$(q "select count(*) from pg_inherits where inhrelid = 'public.$P'::regclass")
[ "$det" = "0" ] && ok "LIVENESS: $P is detached by hand and still carries pgpm's write block" \
                 || { echo "not ok - LIVENESS: $P detached by hand"; exit 1; }

# The operator utility, as the reference documents it: define it, then call it once.
$PSQL -q -f - < "$TREE/scripts/archive_partition_whole.sql" >/dev/null 2>&1
res=$(q "select pgpm_archive_next_partition_whole('public.t'::regclass)")
echo "# the script returned: $res"
led=$(q "select count(*) from pgpm.archive_ledger where parent_table = 'public.t'::regclass and child_name = '$P'")
[ "$led" = "0" ] && ok "no coverage is recorded for the hand-detached $P" \
                 || nok "no coverage is recorded for the hand-detached $P (the ledger holds $(q "select string_agg(format('[%s, %s) rows %s', lo, hi, rows_archived), '; ') from pgpm.archive_ledger where child_name = '$P'"))"
nxt=$(q "select count(*) from pgpm.archive_ledger where parent_table = 'public.t'::regclass and child_name = '$N' and lo = '100' and hi = '200' and rows_archived = 100")
[ "$nxt" = "1" ] && ok "the call archived the next eligible partition $N [100, 200), its 100 rows" \
                 || nok "the call archived the next eligible partition $N [100, 200), its 100 rows"

# The operator attaches the table back; retention runs.
q "alter table public.t attach partition public.$P for values from (0) to (100)" >/dev/null
q "select pgpm.retain('public.t')" >/dev/null
rows=$(q "select coalesce((select string_agg(id::text, ',') from (select id from public.t where id in (1, 25, 50) order by id) s), 'none')")
[ "$rows" = "1,25,50" ] && ok "rows 1, 25 and 50, never archived, survive retention after the table is attached back" \
                        || nok "rows 1, 25 and 50, never archived, survive retention after the table is attached back (got: $rows)"
exit $fail
