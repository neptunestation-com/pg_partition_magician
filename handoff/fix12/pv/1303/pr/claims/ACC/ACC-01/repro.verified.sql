-- F4-02 (#1272), rebuilt by the claims verifier of PR #1303 to pin the CONTRACT rather than a spelling.
-- The finder's repro.sql typed the old half-remedy (`drop table` alone) whatever the log row said, and its LIVENESS 5
-- required the old wording "drop the table by hand"; a fixed remedy cannot pass it. This version reads the remedy OUT
-- OF the retain_disown row and types it AS LOGGED: every `drop table ...;` and `delete from pgpm.part ...;` statement
-- the method spells, in order; a method that spells no statement but says "drop the table by hand" (the pre-fix
-- prose) is typed as that, `drop table <the disowned table>`. Then retention must run clean: no fail_* for the
-- disowned range (fail_retain_identity), status().retain_drop_failures unchanged, and with retain_batch = 1 the first
-- retain() after the remedy reaches the next aged partition rather than spending its slot on the disowned row.
-- Fails on the base (half-remedy, row left), passes on a head whose remedy is the whole repair, fails on the mutant
-- retain_disown_remedy_keeps_row (remedy spells the DROP only).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(11);

create table public.f4r (id bigint primary key, payload text);
insert into public.f4r values (150, 'old'), (160, 'old');
call pgpm.transmute('public.f4r', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.f4r', '500');
insert into public.f4r values (250, 'aged'), (350, 'new');   -- horizon 350 - 100 = 200: [100, 200) alone is past it
create table public.f4r_ref (rid int primary key, pid bigint references public.f4r (id));

select child_name as old from pgpm.part where parent_table = 'public.f4r'::regclass and lo = '100' \gset
select ok(:'old' is not null and pgpm._retain_boundary(c) = '200', 'LIVENESS: the partition [100, 200) is past the horizon')
  from pgpm.config c where c.parent_table = 'public.f4r'::regclass;

-- retire() marks it and fails to dispatch (pg_cron is not in this database): a mark with no dispatch record
select is(pgpm.retire('public.f4r', :'old'), false, 'LIVENESS: retire() took the referenced path');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.f4r'::regclass and action = 'fail_retain_detach' and lo = '100')
          and exists (select 1 from pgpm.part where parent_table = 'public.f4r'::regclass and child_name = :'old'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: its dispatch failed and the mark stands without the record of a dispatch');

-- the operator detaches it themselves; the install pass disowns the mark
alter table public.f4r detach partition :"old";
select is(pgpm._disown_unvouched_retirements(), 1, 'LIVENESS: the install pass disowned one mark');

select method as m from pgpm.log
 where parent_table = 'public.f4r'::regclass and action = 'retain_disown' and lo = '100' \gset
-- the drop remedy exactly as the row spells it: every statement it gives, or the pre-fix prose read as its one DROP
select coalesce(
         (select string_agg(x[1], ' ' order by ord)
            from regexp_matches(:'m', '((?:drop table|delete from pgpm\.part)[^;]*;)', 'g') with ordinality as t(x, ord)),
         case when :'m' like '%drop the table by hand%' then format('drop table public.%I;', :'old') end)
  as remedy \gset
select ok(:'remedy' like 'drop table %',
  'LIVENESS: the retain_disown row names a drop remedy for the disowned table, typed below as logged');

select retain_drop_failures as fails_before from pgpm.status() where parent = 'public.f4r'::regclass \gset
-- the operator types the remedy as logged
:remedy
select is(to_regclass(format('public.%I', :'old')), null, 'LIVENESS: the remedy as typed dropped the disowned table');

-- nothing references the parent any more (fixture: the next aged partition takes the one-step path); 450 moves the
-- horizon to 300, so [200, 300) is aged too; one attempt per call
alter table public.f4r_ref drop constraint f4r_ref_pid_fkey;
insert into public.f4r values (450, 'kept');
update pgpm.config set retain_batch = 1 where parent_table = 'public.f4r'::regclass;
select child_name as aged from pgpm.part where parent_table = 'public.f4r'::regclass and lo = '200' \gset
select max(id) as before_id from pgpm.log \gset
select pgpm.retain('public.f4r');
select max(id) as mid_id from pgpm.log \gset
select pgpm.retain('public.f4r');
select ok((select count(*) from pgpm.log where parent_table = 'public.f4r'::regclass and id > :before_id) > 0,
  'LIVENESS: retention ran twice after the remedy and logged what it attempted');

select is(
  (select array_agg(distinct action) from pgpm.log
    where parent_table = 'public.f4r'::regclass and id > :before_id and lo = '100' and action like 'fail\_%'),
  null,
  'after the remedy as logged, retention logs no failure (fail_retain_identity) for [100, 200)');
select cmp_ok((select retain_drop_failures from pgpm.status() where parent = 'public.f4r'::regclass), '<=', :fails_before::bigint,
  'and status().retain_drop_failures does not climb');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.f4r'::regclass and id > :before_id and id <= :mid_id and action like 'retain\_%'),
  array['retain_drop'],
  'with retain_batch = 1 the first retain() after the remedy spends its slot on the next aged partition, which it drops');
select is((select array_agg(id order by id) from public.f4r), array[350, 450]::bigint[],
  'the parent holds exactly 350 and 450: [100, 200) dropped by the operator, [200, 300) retired');

select * from finish();
