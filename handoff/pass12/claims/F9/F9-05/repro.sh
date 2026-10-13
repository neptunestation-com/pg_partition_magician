#!/bin/bash
# F9-05: scripts/archive_partition_whole.sql hands a table the operator DETACHed by hand to the strategy and records
# coverage for it: its candidate query has no _part_detached_by_hand filter and it never calls _archive_hold_partition,
# though its header and comments say both (#705, #1159). A strategy reading through the parent sees none of the rows,
# the range is recorded covered, and once the table is attached back retire() drops rows nothing archived.
set -u
fail=0
check() {
  local v; v=$($PSQL -tAc "$2" 2>&1)
  if [ "$v" = "t" ]; then echo "ok - $1"; else echo "not ok - $1 (got: $v)"; fail=1; fi
}
$PSQL -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null || { echo "not ok - fixture: setup failed"; exit 1; }
create table public.f9w (id bigint primary key, v text);
insert into public.f9w select g, 'mono' from generate_series(1, 50) g;
call pgpm.transmute('public.f9w', 'id', 100, p_obtain => 2, p_retain => 200);
select pgpm.extend_to('public.f9w', '450');
insert into public.f9w values (450, 'frontier');     -- horizon 200: [0, 100) and [100, 200) retire-eligible
create table public.f9_seen (id bigint);
-- a strategy that reads its range THROUGH THE PARENT, as pgpm_archive's transports do
create function public.f9_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$
declare r pgpm.archive_result;
begin
  insert into public.f9_seen select id from public.f9w where id >= p_lo::bigint and id < p_hi::bigint;
  r.covered_hi := p_hi;
  r.rows_archived := (select count(*) from public.f9w where id >= p_lo::bigint and id < p_hi::bigint);
  return r;
end $f$;
select pgpm.set_archive_fn('public.f9w', 'public.f9_strategy(regclass, name, text, text)'::regprocedure);
select pgpm._enforce_write_blocks('public.f9w');      -- the write block retention puts on [0, 100) and [100, 200)
-- the operator detaches the oldest partition by hand, to keep it (it keeps pgpm's write block)
alter table public.f9w detach partition public.f9w_p0000000000000000000;
SQL
check "LIVENESS: the hand-detached table carries pgpm's write block and its 50 rows" \
  "select pgpm._is_write_blocked('public.f9w', 'f9w_p0000000000000000000')
      and (select count(*) from public.f9w_p0000000000000000000) = 50
      and not exists (select 1 from pg_inherits where inhrelid = 'public.f9w_p0000000000000000000'::regclass)"
check "LIVENESS: pgpm reads it as detached by hand" \
  "select pgpm._part_detached_by_hand('public.f9w', p.child_oid, p.retiring_at) from pgpm.part p
    where p.parent_table = 'public.f9w'::regclass and p.child_name = 'f9w_p0000000000000000000'"
# the operator's one-partition archiver, loaded from the tree and called once
$PSQL -v ON_ERROR_STOP=1 -q < "$TREE/scripts/archive_partition_whole.sql" >/dev/null 2>&1 || { echo "not ok - fixture: script failed to load"; exit 1; }
out=$($PSQL -tAc "select pgpm_archive_next_partition_whole('public.f9w')" 2>&1); echo "# call returned: $out"
check "LIVENESS: the call archived something (a partition of the table was eligible)" \
  "select exists (select 1 from pgpm.archive_ledger where parent_table = 'public.f9w'::regclass)"
check "no coverage is recorded for the table the operator detached by hand" \
  "select not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.f9w'::regclass
                        and child_name = 'f9w_p0000000000000000000' and retired_at is null)"
# the operator attaches it back on its bounds; retention retires it
$PSQL -tAc "alter table public.f9w attach partition public.f9w_p0000000000000000000 for values from (0) to (100)" >/dev/null 2>&1
check "LIVENESS: the table is attached back" \
  "select exists (select 1 from pg_inherits where inhrelid = to_regclass('public.f9w_p0000000000000000000'))"
$PSQL -tAc "select pgpm.retire('public.f9w', 'f9w_p0000000000000000000')" >/dev/null 2>&1
check "rows 1..50 are not dropped unarchived (each still exists, or the strategy was handed it)" \
  "select not exists (select g from generate_series(1, 50) g except select id from public.f9w except select id from public.f9_seen)"
exit $fail
