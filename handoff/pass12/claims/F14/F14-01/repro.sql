-- F14-01: the archive step hands a table the operator DETACHed by hand to the archive strategy, and records
-- coverage for it, when the table carries a retirement mark pgpm recorded no dispatch for. retire() and the
-- install treat such a mark as the operator's (#705: retain_disown), but _part_detached_by_hand and
-- _archive_hold_partition still vouch for any mark by retiring_at alone, so within the same tick the archive
-- step treats the operator's table as pgpm's own retirement in flight.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.f14a (id bigint primary key, payload text);
insert into public.f14a values (1, 'a'), (2, 'b'), (15, 'c');
call pgpm.transmute('public.f14a', 'id', 10::bigint, p_retain => 20, p_paused => false);
select pgpm.extend_to('public.f14a', '60');
insert into public.f14a values (22, 'aged'), (55, 'frontier');
create table public.f14a_ref (id bigint primary key, p_id bigint references public.f14a (id));
insert into public.f14a_ref values (1, 55);   -- referenced parent, nothing in the doomed partition is referenced
select child_name as mono, child_oid as mono_oid from pgpm.part
 where parent_table = 'public.f14a'::regclass and lo = '0' \gset

-- this database has no pg_cron, so retire()'s dispatch of the concurrent detach fails after the mark is stamped
call pgpm.maintain('public.f14a');

select ok(exists (select 1 from pgpm.part where parent_table = 'public.f14a'::regclass and lo = '0'
                   and retiring_at is not null and detach_dispatched_oid is null)
          and exists (select 1 from pgpm.log where parent_table = 'public.f14a'::regclass and lo = '0'
                       and action = 'fail_retain_detach'),
  'LIVENESS: the monolith carries a retirement mark with no dispatch record (the dispatch failed)');
select ok(pgpm._is_write_blocked('public.f14a', :'mono'),
  'LIVENESS: the aged monolith is write-blocked, so it is an archive candidate by every other test');

-- the operator detaches it by hand (a finished, plain DETACH: pgpm issued none)
select format('alter table public.f14a detach partition public.%I', :'mono') \gexec
select ok(not exists (select 1 from pg_inherits where inhrelid = :mono_oid)
          and exists (select 1 from pg_class where oid = :mono_oid),
  'LIVENESS: the table is detached by hand and still exists');

create table public.f14a_calls (child name, lo text, hi text);
create function public.f14a_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare r pgpm.archive_result;
begin
  insert into public.f14a_calls values (p_child, p_lo, p_hi);
  r.covered_hi := p_hi; r.rows_archived := 0;
  return r;
end $$;
select pgpm.set_archive_fn('public.f14a', 'public.f14a_strategy(regclass,name,text,text)'::regprocedure);
update pgpm.config set archive_batch = 5 where parent_table = 'public.f14a'::regclass;   -- every candidate gets a turn

call pgpm.maintain('public.f14a');

select ok(exists (select 1 from public.f14a_calls where lo = '20'),
  'LIVENESS: the archive step ran this tick and handed the strategy the attached aged partition [20, 30)');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.f14a'::regclass and lo = '0'
                   and action = 'retain_disown'),
  'LIVENESS: in the same tick retire() judged the detach the operator''s (retain_disown)');

select is((select array_agg(lo || '-' || hi) from public.f14a_calls where child = :'mono'), null::text[],
  'the archive step does not hand the strategy a table the operator detached by hand');
select is((select array_agg(lo || '-' || hi) from pgpm.archive_ledger
            where parent_table = 'public.f14a'::regclass and child_name = :'mono'), null::text[],
  'and records no archive coverage for it');

select * from finish();
