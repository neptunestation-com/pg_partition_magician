-- V-01 (PR #1303): the remedy _disown_retirement now writes into EVERY retain_disown row, including the one
-- _retain_recall logs when retention NO LONGER REACHES the partition (the operator lengthened retain), tells the
-- operator to "drop it and delete its pgpm.part row" (spelled as statements) and that attaching it back lets
-- "retention retire it". Neither is true of a partition the current policy keeps: typed as logged, the remedy drops
-- rows retention now keeps. On the base the recall path's retain_disown named no remedy at all.
-- Contract pinned: a retain_disown remedy, typed as logged, never destroys rows the parent's retention policy keeps.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.v1r (id bigint primary key, payload text);
insert into public.v1r values (150, 'kept-after-set_retain'), (160, 'kept-after-set_retain');
call pgpm.transmute('public.v1r', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.v1r', '500');
insert into public.v1r values (350, 'new');   -- horizon 250 - 100... floor(350 - 100) = 200: [100, 200) past it
create table public.v1r_ref (rid int primary key, pid bigint references public.v1r (id));

select child_name as old from pgpm.part where parent_table = 'public.v1r'::regclass and lo = '100' \gset
select is(pgpm.retire('public.v1r', :'old'), false, 'LIVENESS: retire() took the referenced path');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.v1r'::regclass and child_name = :'old'
                   and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: its dispatch failed (no pg_cron) and the mark stands without the record of a dispatch');

-- the operator detaches it, then decides to keep a much longer history: retention no longer reaches [100, 200)
alter table public.v1r detach partition :"old";
select pgpm.set_retain('public.v1r', '1000');
select ok(pgpm._retain_boundary(c) is null or pgpm._retain_boundary(c)::bigint < 200,
  'LIVENESS: under the new policy retention no longer reaches [100, 200)')
  from pgpm.config c where c.parent_table = 'public.v1r'::regclass;
select pgpm.retain('public.v1r');
select method as m from pgpm.log
 where parent_table = 'public.v1r'::regclass and action = 'retain_disown' and lo = '100' \gset
select ok(:'m' like '%retention no longer reaches%',
  'LIVENESS: _retain_recall disowned the mark, logged retain_disown');

-- the operator types the drop remedy as the row spells it (every statement; nothing when it spells none)
select coalesce(
         (select string_agg(x[1], ' ' order by ord)
            from regexp_matches(:'m', '((?:drop table|delete from pgpm\.part)[^;]*;)', 'g') with ordinality as t(x, ord)),
         case when :'m' like '%drop the table by hand%' then format('drop table public.%I;', :'old') end,
         'select 1;')
  as remedy \gset
select ok(to_regclass(format('public.%I', :'old')) is not null, 'LIVENESS: the disowned table stands before the remedy');
:remedy

-- fixture: read the disowned table's ids only if it still exists
create function pg_temp.v1_ids(p_rel text) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  if to_regclass(p_rel) is null then return '{}'; end if;
  execute format('select coalesce(array_agg(id), ''{}'') from %s', p_rel) into v;
  return v;
end $f$;
select is((select array_agg(i order by i) from unnest(
             (select array_agg(id) from public.v1r) || pg_temp.v1_ids(format('public.%I', :'old'))) i),
  array[150, 160, 350]::bigint[],
  'rows 150 and 160, which retention keeps under the policy in force, survive the remedy the log row gives');
select ok(:'m' not like '%so retention retires it%',
  'the remedy does not promise that retention retires a partition it no longer reaches');

select * from finish();
