-- V-01 (claims verifier, round 2 of PR #1299): an UNANCHORED pgpm.part row (child_oid null, the state an upgrade
-- from before #421 leaves for a partition that was not attached when its backfill ran) with NO retirement mark,
-- whose table the operator had DETACHed by hand, is still held by _archive_hold_partition (p_child_oid is null ->
-- true) and handed to the strategy. A strategy reading through the parent reads none of its rows, and the range is
-- recorded as covered. PR #1299's body: "Neither archive path ... hands a strategy a table that is not a partition
-- of its parent as of the hold's lock, whatever its mark"; the head asks the name's relation only when the row
-- carries a mark (coalesce(r.child_oid, case when r.retiring_at is not null then v_now::oid end)).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.v2u (id bigint primary key, payload text);
insert into public.v2u values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.v2u', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.v2u', '60');
insert into public.v2u values (22, 'aged'), (55, 'frontier');
select child_name as mono, child_oid as mono_oid from pgpm.part
 where parent_table = 'public.v2u'::regclass and lo = '0' \gset

create table public.v2u_sink (id bigint, payload text, chunk_lo text, chunk_hi text);
create table public.v2u_calls (child name, lo text, hi text);
create table public.v2u_gate (open boolean);
insert into public.v2u_gate values (false);
create function public.v2u_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare r pgpm.archive_result; v_n bigint;
begin
  if not (select open from public.v2u_gate) then raise exception 'v2u: transport not ready yet'; end if;
  insert into public.v2u_calls values (p_child, p_lo, p_hi);
  insert into public.v2u_sink select id, payload, p_lo, p_hi from public.v2u
   where id >= p_lo::bigint and id < p_hi::bigint;
  get diagnostics v_n = row_count;
  r.covered_hi := p_hi; r.rows_archived := v_n;
  return r;
end $$;
select pgpm.set_archive_fn('public.v2u', 'public.v2u_strategy(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.v2u'::regclass;

-- the write block goes on; archiving defers (the strategy raises), so retire() keeps everything
call pgpm.maintain('public.v2u');
select ok(pgpm._is_write_blocked('public.v2u', :'mono') and exists (select 1 from pg_class where oid = :mono_oid),
  'LIVENESS: the aged monolith is write-blocked and kept (its range is uncovered)');

-- the operator detaches it by hand, and (fixture) the row is unanchored as an upgrade from before #421 leaves a
-- partition that was not attached when the backfill ran
select format('alter table public.v2u detach partition public.%I', :'mono') \gexec
update pgpm.part set child_oid = null where parent_table = 'public.v2u'::regclass and lo = '0';
select ok(not exists (select 1 from pg_inherits where inhrelid = :mono_oid)
          and exists (select 1 from pgpm.part where parent_table = 'public.v2u'::regclass and lo = '0'
                       and child_oid is null and retiring_at is null),
  'LIVENESS: fixture: the table is detached by hand, its row unanchored and unmarked');

update public.v2u_gate set open = true;
call pgpm.maintain('public.v2u');

select ok(exists (select 1 from public.v2u_sink where id = 22),
  'LIVENESS: the archive step ran and archived the attached aged partition [20, 30) through the parent');
select is((select array_agg(lo || '-' || hi) from public.v2u_calls where child = :'mono'), null::text[],
  'the archive step does not hand the strategy a table that is not a partition of its parent');
select is((select array_agg(lo || '-' || hi || ':' || coalesce(rows_archived::text, 'null')) from pgpm.archive_ledger
            where parent_table = 'public.v2u'::regclass and child_name = :'mono'), null::text[],
  'and records no coverage for it');

call pgpm.maintain('public.v2u');
-- the remedy docs/reference.md gives for a table detached by hand: attach it back so retention retires it
select format('alter table public.v2u attach partition public.%I for values from (0) to (20)', :'mono') \gexec
select ok(exists (select 1 from pg_inherits where inhrelid = :mono_oid and inhparent = 'public.v2u'::regclass),
  'LIVENESS: the operator attached the table back to the parent on its bounds');
call pgpm.maintain('public.v2u');
call pgpm.maintain('public.v2u');
select case when exists (select 1 from pg_class where oid = :mono_oid)
            then format('select coalesce(string_agg(id::text, '',''), '''') as kept from %s', (:mono_oid)::regclass)
            else 'select ''''::text as kept' end as kept_sql \gset
:kept_sql \gset
select is((select array_agg(v.id order by v.id) from (values (1::bigint), (2), (15)) v(id)
            where v.id::text <> all (string_to_array(:'kept', ','))
              and not exists (select 1 from public.v2u t where t.id = v.id)
              and not exists (select 1 from public.v2u_sink s where s.id = v.id)),
  null::bigint[],
  'every one of rows 1, 2 and 15 is still in a table or in the archive');
select * from finish();
