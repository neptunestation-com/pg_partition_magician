-- P1-01: retain_disown's logged remedy still spells the DROP alone; the DELETE of the pgpm.part row the PR body,
-- docs/reference.md (retire entry and the log-action table) and tests/339 all say it spells is not there.
-- pgpm._disown_retirement computes v_parent_q and never uses it; its method ends "or drop it: drop table X; (the DROP
-- alone leaves the row ... fail_retain_identity ...)". An operator who types the remedy as logged drops the table and
-- leaves the pgpm.part row attached and anchored to a dropped oid: every later retain()/retire() logs
-- fail_retain_identity for that range, status().retain_drop_failures climbs for good, and the row takes a
-- retain_batch slot every tick (#1272, the very wedge the PR says it ends).
-- Parent in a non-public schema with a quoted name, so the statements as logged are also checked for validity there.
-- Rows: 150, 160 in the disowned partition; 250 in the next aged one; 350, 450 survive (asymmetric).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(12);

create schema p1s;
create table p1s."Ev T" (id bigint primary key, payload text);
insert into p1s."Ev T" values (150, 'old'), (160, 'old');
call pgpm.transmute('p1s."Ev T"', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('p1s."Ev T"', '500');
insert into p1s."Ev T" values (250, 'aged'), (350, 'kept');   -- horizon floor(350 - 100) = 200: [100, 200) alone
create table p1s.ref (rid int primary key, pid bigint references p1s."Ev T" (id));

select child_name as old from pgpm.part where parent_table = 'p1s."Ev T"'::regclass and lo = '100' \gset
select ok(:'old' is not null and pgpm._retain_boundary(c) = '200',
  'LIVENESS: the partition [100, 200) is past the horizon and [200, 300) is not')
  from pgpm.config c where c.parent_table = 'p1s."Ev T"'::regclass;

-- retire() marks it and its dispatch fails (pg_cron is not installed here): a mark without the record of a dispatch
select is(pgpm.retire('p1s."Ev T"', :'old'), false, 'LIVENESS: retire() took the referenced path');
select ok(exists (select 1 from pgpm.log where parent_table = 'p1s."Ev T"'::regclass
                   and action = 'fail_retain_detach' and lo = '100')
          and exists (select 1 from pgpm.part where parent_table = 'p1s."Ev T"'::regclass and child_name = :'old'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: its dispatch failed, and the mark stands without the record of a dispatch');

-- the operator detaches it; the pass every install.sql run makes disowns the mark, logging the remedy
alter table p1s."Ev T" detach partition p1s.:"old";
select is(pgpm._disown_unvouched_retirements(), 1, 'LIVENESS: the install pass disowned one mark');
select method as m from pgpm.log
 where parent_table = 'p1s."Ev T"'::regclass and action = 'retain_disown' and lo = '100' \gset
select is((regexp_match(:'m', 'drop table ([^;]+);'))[1], format('p1s.%I', :'old'),
  'LIVENESS: the remedy spells a DROP of the disowned table, schema-qualified and quoted');

-- THE DEFECT: the remedy does not spell the DELETE of the pgpm.part row beside the DROP
select is((regexp_match(:'m', 'drop table [^;]+; (delete from pgpm\.part where [^;]+;)'))[1],
  format('delete from pgpm.part where parent_table = %L::regclass and child_name = %L;', 'p1s."Ev T"', :'old'),
  'the remedy spells the DELETE of the pgpm.part row beside the DROP, naming the parent schema-qualified and the row by its child_name');

-- the operator types the remedy exactly as the log row spells it: its DROP, and its DELETE when it spells one
select coalesce((regexp_match(:'m', '(drop table [^;]+;(?: delete from pgpm\.part where [^;]+;)?)'))[1], 'select 1;')
  as remedy \gset
:remedy

select is(to_regclass(format('p1s.%I', :'old')), null, 'the DROP as logged is valid SQL for the quoted name: the table is gone');

alter table p1s.ref drop constraint ref_pid_fkey;
insert into p1s."Ev T" values (450, 'kept');   -- horizon 300: [200, 300) is aged too
select max(id) as before from pgpm.log \gset
select pgpm.retain('p1s."Ev T"');
select pgpm.retain('p1s."Ev T"');

select ok(exists (select 1 from pgpm.log where parent_table = 'p1s."Ev T"'::regclass and id > :before
                   and action = 'retain_drop' and lo = '200'),
  'LIVENESS: retention ran twice after the remedy and reached the next aged partition, [200, 300)');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'p1s."Ev T"'::regclass and id > :before and lo = '100'),
  null, 'after the remedy as logged, retention logs nothing for [100, 200) on later calls');
select is((select retain_drop_failures from pgpm.status() where parent = 'p1s."Ev T"'::regclass), 0::bigint,
  'and status().retain_drop_failures does not climb');
select is((select array_agg(child_name::text order by lo::bigint) from pgpm.part
            where parent_table = 'p1s."Ev T"'::regclass and lo::bigint < 400),
  array[(select child_name::text from pgpm.part where parent_table = 'p1s."Ev T"'::regclass and lo = '300')],
  'pgpm.part keeps no row for the table the operator dropped as told, nor for the retired one, and keeps [300, 400)');
select is((select array_agg(id order by id) from p1s."Ev T"), array[350, 450]::bigint[],
  'the parent holds exactly 350 and 450 (150, 160 dropped by the operator, 250 retired)');

select * from finish();
