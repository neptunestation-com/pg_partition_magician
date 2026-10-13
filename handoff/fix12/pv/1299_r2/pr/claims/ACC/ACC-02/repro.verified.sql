-- ACC-02 rebuilt by the claims verifier (round 2 of PR #1299): V-01, pinned to the contract rather than to the drop.
-- A retirement pgpm itself dispatched (mark AND record) whose concurrent detach has landed, with archiving switched
-- on only after the mark was stamped. The original asserted LIVENESS "retire() dropped the monolith" and looked for
-- rows 1, 2 and 15 only in the parent and the sink; on the fixed head the table is kept (premise_removed: the fix
-- refuses the hand-off instead of dropping), so this version pins the contract: no coverage is recorded for the
-- detached table from a read that saw none of its rows, rows 1, 2 and 15 still exist in the detached table or the
-- archive, the outcome is logged skip_archive with a remedy, and the remedy as typed archives the rows before the
-- drop.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create table public.v01 (id bigint primary key, payload text);
insert into public.v01 values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.v01', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.v01', '60');
insert into public.v01 values (22, 'aged'), (55, 'frontier');
create table public.v01_ref (id bigint primary key, p_id bigint references public.v01 (id));
insert into public.v01_ref values (1, 55);   -- referenced parent: retire() takes the concurrent-detach path
select child_name as mono, child_oid as mono_oid from pgpm.part
 where parent_table = 'public.v01'::regclass and lo = '0' \gset

-- no archive strategy yet: retention may retire the aged monolith; retire() stamps the mark and dispatches the detach
call pgpm.maintain('public.v01');

-- fixture: this harness has no pg_cron, so _dispatch_detach fails here; on a database with pg_cron it succeeds and
-- retire() writes this record in the same transaction (install.sql, retire: "update pgpm.part set
-- detach_dispatched_oid = v_child::oid"). Written as retire() writes it.
update pgpm.part set detach_dispatched_oid = child_oid
 where parent_table = 'public.v01'::regclass and lo = '0' and retiring_at is not null;
select ok((select pgpm._detach_dispatched(parent_table, child_name, child_oid) from pgpm.part
            where parent_table = 'public.v01'::regclass and lo = '0'),
  'LIVENESS: the monolith carries pgpm''s retirement mark with the record of its dispatch');

-- fixture: pg_cron's pgpm_detach job runs the dispatched command (_detach_cmd): the detach lands
select format('alter table public.v01 detach partition public.%I concurrently', :'mono') \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :mono_oid)
          and exists (select 1 from pg_class where oid = :mono_oid),
  'LIVENESS: pgpm''s dispatched detach landed; the table stands outside the parent awaiting retire()''s drop');

-- the operator turns archiving on, with a strategy that reads its chunk through the parent as pgpm_archive's do
create table public.v01_sink (id bigint, payload text, chunk_lo text, chunk_hi text);
create table public.v01_calls (child name, lo text, hi text);
create function public.v01_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare r pgpm.archive_result; v_n bigint;
begin
  insert into public.v01_calls values (p_child, p_lo, p_hi);
  insert into public.v01_sink select id, payload, p_lo, p_hi from public.v01
   where id >= p_lo::bigint and id < p_hi::bigint;
  get diagnostics v_n = row_count;
  r.covered_hi := p_hi; r.rows_archived := v_n;
  return r;
end $$;
select pgpm.set_archive_fn('public.v01', 'public.v01_strategy(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.v01'::regclass;
select ok((select archive_fn is not null from pgpm.config where parent_table = 'public.v01'::regclass),
  'LIVENESS: archiving is configured before the drop');

create temporary table v01_mark as select coalesce(max(id), 0) as id from pgpm.log;

call pgpm.maintain('public.v01');
call pgpm.maintain('public.v01');

select ok(exists (select 1 from public.v01_sink where id = 22),
  'LIVENESS: the archive step ran and archived the attached aged partition [20, 30) through the parent');

select is((select array_agg(lo || '-' || hi || ':' || coalesce(rows_archived::text, 'null')) from pgpm.archive_ledger
            where parent_table = 'public.v01'::regclass and child_name = :'mono'), null::text[],
  'no coverage is recorded for the detached monolith, which no strategy read');

-- rows 1, 2 and 15: in the detached table (looked up by its oid; gone means none) or in the archive
select case when exists (select 1 from pg_class where oid = :mono_oid)
            then format('select coalesce(string_agg(id::text, '','' order by id), '''') as kept from %s', (:mono_oid)::regclass)
            else 'select ''''::text as kept' end as kept_sql \gset
:kept_sql \gset
select is((select array_agg(v.id order by v.id) from (values (1::bigint), (2), (15)) v(id)
            where v.id::text <> all (string_to_array(:'kept', ','))
              and not exists (select 1 from public.v01_sink s where s.id = v.id)),
  null::bigint[],
  'every one of rows 1, 2 and 15 is still in the detached table or in the archive');
select is((select array_agg(distinct l.lo || '-' || l.hi) from pgpm.log l
            where l.parent_table = 'public.v01'::regclass and l.action = 'skip_archive'
              and l.id > (select id from v01_mark) and l.method like '%ATTACH PARTITION%'),
  array['0-20'],
  'the archive step logs skip_archive over [0, 20) with the remedy');

-- the remedy as the log row types it (no such row: a statement that does nothing, so the LIVENESS below fails)
drop table public.v01_ref;
select coalesce((select substring(l.method from 'ALTER TABLE .* FOR VALUES FROM \(''[^'']*''\) TO \(''[^'']*''\)')
                   from pgpm.log l
                  where l.parent_table = 'public.v01'::regclass and l.action = 'skip_archive' and l.lo = '0'
                  order by l.id desc limit 1), 'select 1') as remedy \gset
:remedy;
select ok(exists (select 1 from pg_inherits where inhrelid = :mono_oid and inhparent = 'public.v01'::regclass),
  'LIVENESS: the remedy as typed attached the table back to the parent');

call pgpm.maintain('public.v01');
call pgpm.maintain('public.v01');

select is((select array_agg(distinct s.id order by s.id) from public.v01_sink s where s.id in (1, 2, 15)),
  array[1, 2, 15]::bigint[],
  'after the remedy, rows 1, 2 and 15 are in the archive');

select * from finish();
