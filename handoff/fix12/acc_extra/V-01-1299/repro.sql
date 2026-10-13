-- V-01: a retirement pgpm itself dispatched (mark AND record, _retirement_vouched true) whose concurrent detach has
-- landed, so the partition's rows are no longer visible through the parent, is still handed to the archive strategy
-- when archiving is turned on (pgpm.set_archive_fn) after the retirement began. A strategy that reads its chunk
-- through the parent, as pgpm_archive's transports do, reads none of the rows; the step records [0, 20) as covered
-- with rows_archived = 0, and retire() drops the table on that coverage. Rows 1, 2 and 15 end in neither the table
-- nor the archive, and nothing is logged as a failure. Had the same set_archive_fn come a tick before pg_cron ran the
-- detach, the partition would have been archived while still attached: the outcome depends on that timing alone.
-- Not #1259's mechanism (the mark here HAS its record); the same on the base and the head of PR #1299.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

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

call pgpm.maintain('public.v01');
call pgpm.maintain('public.v01');

select ok(exists (select 1 from public.v01_sink where id = 22),
  'LIVENESS: the archive step ran and archived the attached aged partition [20, 30) through the parent');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.v01'::regclass and lo = '0' and action = 'retain_drop'),
  'LIVENESS: retire() dropped the monolith');

select is((select array_agg(rows_archived) from pgpm.archive_ledger
            where parent_table = 'public.v01'::regclass and lo = '0' and rows_archived = 0), null::bigint[],
  'no coverage is recorded for the detached monolith from a read that saw none of its rows');
select is((select array_agg(v.id order by v.id) from (values (1::bigint), (2), (15)) v(id)
            where not exists (select 1 from public.v01 t where t.id = v.id)
              and not exists (select 1 from public.v01_sink s where s.id = v.id)),
  null::bigint[],
  'every one of rows 1, 2 and 15 is still in the table or in the archive once archiving was configured before the drop');

select * from finish();
