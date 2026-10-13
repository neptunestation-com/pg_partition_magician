-- F4-02: retain_disown's remedy, typed as written, wedges retention for good.
-- A retirement mark without the record of pgpm's dispatch (here: its dispatch failed, no pg_cron in this database)
-- on a referenced partition that is then detached is disowned by the pass every install.sql run makes
-- (pgpm._disown_unvouched_retirements, called here directly, as the install calls it), logged retain_disown with
-- the remedy "once its detach is finished drop the table by hand, or attach it back to the parent on its bounds"
-- (docs/reference.md, retire, says the same, "its pgpm.part row is kept"). Dropping it by hand leaves the
-- pgpm.part row attached with child_oid pointing at nothing, so every later retire()/retain() logs
-- fail_retain_identity for it, status().retain_drop_failures climbs for good, and the row takes a retain_batch slot
-- every tick. The documented remedy should end the matter (the table is gone, which is what retention wanted).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(8);

create table public.f4r (id bigint primary key, payload text);
insert into public.f4r values (150, 'old');
call pgpm.transmute('public.f4r', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.f4r', '400');
insert into public.f4r values (350, 'new');   -- horizon floor(350 - 100) = 200: [100, 200) alone is past it
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

-- the operator detaches it themselves (nothing references its rows)
alter table public.f4r detach partition :"old";
select is(pgpm._disown_unvouched_retirements(), 1, 'LIVENESS: the install pass disowned one mark');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.f4r'::regclass and action = 'retain_disown' and lo = '100'
                   and method like '%drop the table by hand%'),
  'LIVENESS: the mark was disowned, logged retain_disown naming the remedy "drop the table by hand"');

select retain_drop_failures as fails_before from pgpm.status() where parent = 'public.f4r'::regclass \gset
-- the operator types the remedy
drop table public.:"old";
select max(id) as before_id from pgpm.log \gset
select pgpm.retain('public.f4r');
select pgpm.retain('public.f4r');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.f4r'::regclass and action = 'retain_drop')
          or (select count(*) from pgpm.log where parent_table = 'public.f4r'::regclass and id > :before_id) > 0,
  'LIVENESS: retention ran twice after the remedy');

select is(
  (select array_agg(distinct action) from pgpm.log
    where parent_table = 'public.f4r'::regclass and id > :before_id and lo = '100' and action like 'fail\_%'),
  null,
  'after the documented remedy, retention logs no failure for [100, 200) on later calls');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.f4r'::regclass), :fails_before::bigint,
  'and status().retain_drop_failures does not climb for the partition the operator dropped as told');

select * from finish();
