#!/usr/bin/env bash
# scripts/archive_partition_whole.sql's candidate query lacks pgpm._part_detached_by_hand: a table the operator
# detached by hand is handed to the strategy, which reads none of its rows through the parent; [lo, hi) is recorded
# covered with 0 rows, and once attached back retain() drops ids nothing archived.
# Reads the script from $TREE; the pgTAP body is the heredoc below.
set -u
SQLF="$(mktemp)"; trap 'rm -f "$SQLF"' EXIT
cat > "$SQLF" <<'SQL'
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create schema f1201;
create table f1201.calls (n serial primary key, p_child name, p_lo text, p_hi text, seen text);
-- reads [lo, hi) through the PARENT, as pgpm_archive's transports do, and records which ids it saw
create function f1201.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_seen text; v_n bigint;
begin
  execute format('select string_agg(id::text, '','' order by id), count(*) from %s where id >= %L::bigint and id < %L::bigint',
                 p_parent, p_lo, p_hi) into v_seen, v_n;
  insert into f1201.calls (p_child, p_lo, p_hi, seen) values (p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
  v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 'f1201/' || p_lo;
  return v;
end $$;

create table public.f1201_ev (id bigint primary key, payload text);
insert into public.f1201_ev values (7, 'a'), (42, 'b'), (88, 'c');
call pgpm.transmute('public.f1201_ev', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false);
insert into public.f1201_ev values (150, 'd'), (160, 'e'), (500, 'frontier');
select pgpm._enforce_write_blocks('public.f1201_ev');
select pgpm.set_archive_fn('public.f1201_ev', 'f1201.via_parent(regclass,name,text,text)'::regprocedure);
select child_name as p0 from pgpm.part where parent_table = 'public.f1201_ev'::regclass and lo = '0' \gset

-- the operator detaches the OLDEST write-blocked partition by hand
select format('alter table public.f1201_ev detach partition public.%I', :'p0') as detach_sql \gset
:detach_sql;

select ok((select p.attached and pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
             from pgpm.part p where p.parent_table = 'public.f1201_ev'::regclass and p.child_name = :'p0')
          and pgpm._is_write_blocked('public.f1201_ev', :'p0'),
  'LIVENESS: [0, 100) is detached by hand, keeps its attached pgpm.part row and the write block');
select format('select string_agg(id::text, '','' order by id) as p0_ids from public.%I', :'p0') as p0_ids_sql \gset
:p0_ids_sql \gset
select is(:'p0_ids'::text, '7,42,88', 'LIVENESS: the detached table holds ids 7, 42 and 88');

-- the operator script (docs/reference.md: "A table the operator detached by hand is not one of its candidates")
select pgpm_archive_next_partition_whole('public.f1201_ev'::regclass) as msg \gset
select diag('call: ' || :'msg');

select is_empty(format($$ select 1 from f1201.calls where p_child = %L $$, :'p0'),
  'the hand-detached table is never handed to the strategy');
select is_empty(format($$ select 1 from pgpm.archive_ledger where parent_table = 'public.f1201_ev'::regclass and child_name = %L $$, :'p0'),
  'no coverage is recorded for the hand-detached table');

-- the documented remedy for a hand detach: attach it back; then retention runs
select format('alter table public.f1201_ev attach partition public.%I for values from (0) to (100)', :'p0') as attach_sql \gset
:attach_sql;
select ok(exists (select 1 from pg_inherits where inhparent = 'public.f1201_ev'::regclass
                    and inhrelid = (select child_oid from pgpm.part where parent_table = 'public.f1201_ev'::regclass and child_name = :'p0')),
  'LIVENESS: the table is attached back, its rows visible through the parent again');
select is((select string_agg(id::text, ',' order by id) from public.f1201_ev where id < 100), '7,42,88',
  'LIVENESS: ids 7, 42 and 88 are readable through the parent before retain');
select pgpm.retain('public.f1201_ev');
select is((select string_agg(id::text, ',' order by id) from public.f1201_ev where id < 100), '7,42,88',
  'retain() keeps ids 7, 42 and 88: nothing archived them');
select * from finish();
SQL
out="$(cat "$TREE/scripts/archive_partition_whole.sql" "$SQLF" | $PSQL -X -q -tA -v ON_ERROR_STOP=1 -f - 2>&1)"
rc=$?
echo "$out"
[ $rc -ne 0 ] && exit 1
echo "$out" | grep -q '^not ok' && exit 1
exit 0
