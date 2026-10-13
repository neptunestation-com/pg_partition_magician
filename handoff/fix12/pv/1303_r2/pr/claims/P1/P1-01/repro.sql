-- P1-01: the reached remedy a retain_disown row spells names the DROP without the DELETE of the pgpm.part row.
-- docs/reference.md (retire, "The remedy for a disowned table ...") and the PR body say `method` spells all three
-- statements for a partition retention reaches: the ATTACH, or the DROP together with the DELETE of its pgpm.part
-- row, because the DROP alone leaves the row anchored to a dropped oid, refused fail_retain_identity on every call
-- (#1038), so status().retain_drop_failures climbs for good (#1272). pgpm._disown_retirement's reached branch
-- spells `drop table <child>;` and then only SAYS the DROP alone is refused: it never spells the DELETE. Typed
-- exactly as logged, the remedy is the wedge the issue describes.
-- Fixture (asymmetric): [100, 200) holds 150 and 160 (the disowned partition), [200, 300) holds 250 (aged next,
-- retired after the remedy), 350 and 450 are kept. No pg_cron in this database: retire()'s dispatch of a referenced
-- partition's detach fails, which is the mark without a record the install pass disowns.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(11);

create table public.p1r (id bigint primary key, payload text);
insert into public.p1r values (150, 'old'), (160, 'old');
call pgpm.transmute('public.p1r', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.p1r', '500');
insert into public.p1r values (250, 'aged'), (350, 'kept');   -- horizon floor(350 - 100) = 200: [100, 200) alone
create table public.p1r_ref (rid int primary key, pid bigint references public.p1r (id));

select child_name as old from pgpm.part where parent_table = 'public.p1r'::regclass and lo = '100' \gset
select ok(:'old' is not null and pgpm._retain_boundary(c) = '200',
  'LIVENESS: [100, 200) is past the horizon and [200, 300) is not')
  from pgpm.config c where c.parent_table = 'public.p1r'::regclass;
select is(pgpm.retire('public.p1r', :'old'), false, 'LIVENESS: retire() took the referenced path');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.p1r'::regclass and action = 'fail_retain_detach' and lo = '100')
          and exists (select 1 from pgpm.part where parent_table = 'public.p1r'::regclass and child_name = :'old'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: its dispatch failed, and the mark stands without the record of a dispatch');

alter table public.p1r detach partition :"old";
select is(pgpm._disown_unvouched_retirements(), 1, 'LIVENESS: the install pass disowned one mark');
select method as m from pgpm.log where parent_table = 'public.p1r'::regclass and action = 'retain_disown' and lo = '100' \gset
select ok(:'m' like '%Retention reaches its range%' and :'m' like '%drop table public.%',
  'LIVENESS: the row judged the range reached and spells a DROP of the table');

-- defect check 1: the DROP is spelled together with the DELETE of the row (the exact statements, by name)
select is((regexp_match(:'m', 'drop table [^;]+; delete from pgpm\.part where [^;]+;'))[1],
  format('drop table public.%I; delete from pgpm.part where parent_table = %L::regclass and child_name = %L;',
         :'old', 'public.p1r', :'old'),
  'the reached remedy spells the DROP of the table AND the DELETE of its pgpm.part row');

-- the operator types the remedy exactly as the row spells it: its DROP, and its DELETE only when it spells one
select coalesce((regexp_match(:'m', '(drop table [^;]+;(?: delete from pgpm\.part where [^;]+;)?)'))[1], 'select 1;') as remedy \gset
:remedy

alter table public.p1r_ref drop constraint p1r_ref_pid_fkey;
insert into public.p1r values (450, 'kept');   -- horizon 300: [200, 300) is aged too
select max(id) as before from pgpm.log \gset
select pgpm.retain('public.p1r');
select pgpm.retain('public.p1r');
select ok((select count(*) from pgpm.log where parent_table = 'public.p1r'::regclass and id > :before) > 0,
  'LIVENESS: retention ran twice after the typed remedy and logged something for the parent');

-- defect checks 2 to 4: typed as logged, the remedy ends the matter
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.p1r'::regclass and id > :before and lo = '100'),
  null, 'after the typed remedy, retention logs nothing for [100, 200) on later calls');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.p1r'::regclass), 0::bigint,
  'and status().retain_drop_failures does not climb');
select is((select array_agg(child_name::text order by lo::bigint) from pgpm.part
            where parent_table = 'public.p1r'::regclass and lo::bigint < 400),
  array[(select child_name::text from pgpm.part where parent_table = 'public.p1r'::regclass and lo = '300')],
  'pgpm.part keeps no row for the dropped table nor for the retired [200, 300), and keeps [300, 400)');
select is((select array_agg(id order by id) from public.p1r), array[350, 450]::bigint[],
  'the parent holds exactly 350 and 450 (150 and 160 dropped by the operator, 250 retired)');

select * from finish();
