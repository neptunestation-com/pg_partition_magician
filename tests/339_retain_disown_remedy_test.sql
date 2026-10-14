-- retain_disown's remedy, typed as logged, ends the matter (issue #1272).
--
-- THE BUG. A retirement mark without the record of pgpm's own dispatch (#705: its dispatch failed, or a pgpm older
-- than the record stamped it) on a partition that is then pending or detached is disowned: the mark is cleared and
-- retain_disown is logged with a remedy for the operator. That remedy (the install pass's method, and
-- docs/reference.md's retire entry) said "once its detach is finished, drop the table by hand, or attach it back to
-- the parent on its bounds", and the reference added "its pgpm.part row is kept". Typed as written, it left that row
-- attached and anchored to the oid of a table that no longer exists, which retire() refuses as fail_retain_identity
-- on every call, by design (#1038: a partition dropped under its row is a wedge an operator has to look at). So the
-- remedy never ended anything: every retain() logged a failure for the range, status().retain_drop_failures climbed
-- for good, and the row took a retain_batch slot on every tick.
--
-- THE CONTRACT. Every retain_disown row's method names the repair the partition's state calls for, by the relation it
-- is about, spelled as statements to run. When the retention policy in force reaches the range: attach the table
-- back on its bounds, or drop it AND delete its pgpm.part row. When it does not (no policy, or set_retain lengthened
-- it, which is when _retain_recall disowns): attach it back, and never a DROP, since its rows are rows the policy
-- keeps (a first cut of this fix spelled the DROP there too, and typed as logged it destroyed them). The remedy
-- lives in pgpm._disown_retirement, the one writer of retain_disown, so every path that disowns a mark carries it:
-- the pass every install.sql run makes (PART A), retire() (PART B), _retain_recall (PART C) and _detach_reap (the
-- same function, not exercised here). Each part reads the statements OUT OF THE LOG ROW and runs them as typed. A and
-- B then show retention runs clean over the range: nothing logged for the disowned range, retain_drop_failures not
-- climbing, and retention reaching the next aged partition, which a row stuck at the head of the backlog would have
-- stood in front of. C shows the kept rows are served again, under the very relation the row records.
--
-- ASYMMETRIC FIXTURES. Parts A and B's parents hold two rows (150, 160) in the partition that is disowned, one (250)
-- in the next aged partition, which retention drops after the remedy, and two (350, 450) that survive; PART B's
-- parent lives in a schema of its own, so a remedy that names the wrong schema drops nothing and fails. PART C's holds
-- the two kept rows (150, 160) and one (350), so a remedy that loses them cannot pass for one that serves them.
--
-- No pg_cron in this database: retire()'s dispatch of a referenced partition's detach fails (fail_retain_detach),
-- which is the mark without a record the parts need. Each part's mark is cleared (disowned) before the part ends.
-- bench/retain_disown_remedy.sh runs this file against the mutations that put each defect back.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(34);

-- ============================ PART A: the pass every install.sql run makes ============================
create table public.rd339a (id bigint primary key, payload text);
insert into public.rd339a values (150, 'old'), (160, 'old');
call pgpm.transmute('public.rd339a', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.rd339a', '500');
insert into public.rd339a values (250, 'aged'), (350, 'kept');   -- horizon floor(350 - 100) = 200: [100, 200) alone
create table public.rd339a_ref (rid int primary key, pid bigint references public.rd339a (id));

select child_name as a_old from pgpm.part where parent_table = 'public.rd339a'::regclass and lo = '100' \gset
select child_name as a_aged from pgpm.part where parent_table = 'public.rd339a'::regclass and lo = '200' \gset
select ok(:'a_old' is not null and pgpm._retain_boundary(c) = '200',
  'LIVENESS: A: the partition [100, 200) is past the horizon and [200, 300) is not')
  from pgpm.config c where c.parent_table = 'public.rd339a'::regclass;

select is(pgpm.retire('public.rd339a', :'a_old'), false, 'LIVENESS: A: retire() took the referenced path');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rd339a'::regclass
                   and action = 'fail_retain_detach' and lo = '100')
          and exists (select 1 from pgpm.part where parent_table = 'public.rd339a'::regclass and child_name = :'a_old'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: A: its dispatch failed, and the mark stands without the record of a dispatch');

alter table public.rd339a detach partition :"a_old";
select is(pgpm._disown_unvouched_retirements(), 1, 'LIVENESS: A: the install pass disowned one mark');

select method as a_method from pgpm.log
 where parent_table = 'public.rd339a'::regclass and action = 'retain_disown' and lo = '100' \gset
select is((regexp_match(:'a_method', 'drop table [^;]+; delete from pgpm\.part where [^;]+;'))[1],
  format('drop table public.%I; delete from pgpm.part where parent_table = %L::regclass and child_name = %L;',
         :'a_old', 'public.rd339a', :'a_old'),
  'A: the remedy names the table to drop AND the pgpm.part row to delete with it, both by name');
select ok(:'a_method' like '%attach it back to the parent on its bounds%',
  'A: and still names the other way out, attaching it back');

-- the operator types the drop remedy exactly as the log row spells it: its DROP, and its DELETE when it spells one
-- (a remedy that names the DROP alone is typed as that, and the checks below show what it leaves; 'select 1' when it
-- spells no DROP at all, so the file goes on)
select coalesce((regexp_match(:'a_method', '(drop table [^;]+;(?: delete from pgpm\.part where [^;]+;)?)'))[1], 'select 1;')
  as a_remedy \gset
:a_remedy

select is(to_regclass(format('public.%I', :'a_old')), null, 'A: the disowned table is gone');

-- nothing references the parent any more, so retention's next drop takes the one-step path; 450 moves the horizon
-- to 300, so [200, 300) is aged too
alter table public.rd339a_ref drop constraint rd339a_ref_pid_fkey;
insert into public.rd339a values (450, 'kept');
select max(id) as a_before from pgpm.log \gset
select pgpm.retain('public.rd339a');
select pgpm.retain('public.rd339a');

select ok(exists (select 1 from pgpm.log where parent_table = 'public.rd339a'::regclass and id > :a_before
                   and action = 'retain_drop' and lo = '200'),
  'LIVENESS: A: retention ran after the remedy and reached the next aged partition, [200, 300)');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.rd339a'::regclass and id > :a_before and lo = '100'),
  null, 'A: after the remedy, retention logs nothing for [100, 200) on later calls');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.rd339a'::regclass), 0::bigint,
  'A: and status().retain_drop_failures does not climb');
select is((select array_agg(child_name::text order by lo::bigint) from pgpm.part
            where parent_table = 'public.rd339a'::regclass and lo::bigint < 400),
  array[(select child_name::text from pgpm.part where parent_table = 'public.rd339a'::regclass and lo = '300')],
  'A: pgpm.part keeps no row for the dropped table nor the retired one, and keeps [300, 400)');
select is((select array_agg(id order by id) from public.rd339a), array[350, 450]::bigint[],
  'A: the parent holds exactly the rows it should (150 and 160 dropped by the operator, 250 retired)');

-- ============================ PART B: retire() disowns it ============================
create schema rd339s;
create table rd339s.rd339b (id bigint primary key, payload text);
insert into rd339s.rd339b values (150, 'old'), (160, 'old');
call pgpm.transmute('rd339s.rd339b', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('rd339s.rd339b', '500');
insert into rd339s.rd339b values (250, 'aged'), (350, 'kept');
create table rd339s.rd339b_ref (rid int primary key, pid bigint references rd339s.rd339b (id));

select child_name as b_old from pgpm.part where parent_table = 'rd339s.rd339b'::regclass and lo = '100' \gset
select is(pgpm.retire('rd339s.rd339b', :'b_old'), false, 'LIVENESS: B: retire() took the referenced path');
select ok(exists (select 1 from pgpm.log where parent_table = 'rd339s.rd339b'::regclass
                   and action = 'fail_retain_detach' and lo = '100')
          and exists (select 1 from pgpm.part where parent_table = 'rd339s.rd339b'::regclass and child_name = :'b_old'
                       and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: B: its dispatch failed, and the mark stands without the record of a dispatch');

alter table rd339s.rd339b detach partition rd339s.:"b_old";
select is(pgpm.retire('rd339s.rd339b', :'b_old'), false, 'LIVENESS: B: retire() refused the table it found detached');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'rd339s.rd339b'::regclass
            and lo = '100' and action in ('retain_disown', 'fail_retain_drop')),
  array['retain_disown', 'fail_retain_drop'],
  'LIVENESS: B: and disowned its mark (retain_disown, by retire()), then refused it as detached by hand');

select method as b_method from pgpm.log
 where parent_table = 'rd339s.rd339b'::regclass and action = 'retain_disown' and lo = '100' \gset
select is((regexp_match(:'b_method', 'drop table [^;]+; delete from pgpm\.part where [^;]+;'))[1],
  format('drop table rd339s.%I; delete from pgpm.part where parent_table = %L::regclass and child_name = %L;',
         :'b_old', 'rd339s.rd339b', :'b_old'),
  'B: retire()''s retain_disown names the same remedy, in the table''s own schema');

select coalesce((regexp_match(:'b_method', '(drop table [^;]+;(?: delete from pgpm\.part where [^;]+;)?)'))[1], 'select 1;')
  as b_remedy \gset
:b_remedy

select is(to_regclass(format('rd339s.%I', :'b_old')), null, 'B: the disowned table is gone');

alter table rd339s.rd339b_ref drop constraint rd339b_ref_pid_fkey;
insert into rd339s.rd339b values (450, 'kept');
select max(id) as b_before from pgpm.log \gset
select pgpm.retain('rd339s.rd339b');
select pgpm.retain('rd339s.rd339b');

select ok(exists (select 1 from pgpm.log where parent_table = 'rd339s.rd339b'::regclass and id > :b_before
                   and action = 'retain_drop' and lo = '200'),
  'LIVENESS: B: retention ran after the remedy and reached the next aged partition, [200, 300)');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'rd339s.rd339b'::regclass and id > :b_before and lo = '100'),
  null, 'B: after the remedy, retention logs nothing for [100, 200) on later calls');
select is((select retain_drop_failures from pgpm.status() where parent = 'rd339s.rd339b'::regclass), 0::bigint,
  'B: and status().retain_drop_failures does not climb');
select is((select array_agg(id order by id) from rd339s.rd339b), array[350, 450]::bigint[],
  'B: the parent holds exactly the rows it should');

-- ============================ PART C: _retain_recall disowns it, retention no longer reaching it ============================
-- The operator detaches the partition, then lengthens the policy (set_retain '1000'): retention no longer reaches
-- [100, 200), so the next retain()'s _retain_recall disowns the mark rather than re-attach it. Its rows are rows the
-- policy in force keeps, so the remedy is the ATTACH alone, never a DROP. The part types the drop remedy if the row
-- spells one (as parts A and B do), and the ATTACH otherwise, and then asks whether rows 150 and 160 are served.
create table public.rd339c (id bigint primary key, payload text);
insert into public.rd339c values (150, 'kept'), (160, 'kept');
call pgpm.transmute('public.rd339c', 'id', 100::bigint, p_obtain => 1, p_paused => false, p_retain => '100');
select pgpm.extend_to('public.rd339c', '500');
insert into public.rd339c values (350, 'kept');
create table public.rd339c_ref (rid int primary key, pid bigint references public.rd339c (id));

select child_name as c_old from pgpm.part where parent_table = 'public.rd339c'::regclass and lo = '100' \gset
select is(pgpm.retire('public.rd339c', :'c_old'), false, 'LIVENESS: C: retire() took the referenced path');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.rd339c'::regclass and child_name = :'c_old'
                   and retiring_at is not null and detach_dispatched_oid is null),
  'LIVENESS: C: its dispatch failed, and the mark stands without the record of a dispatch');
select oid as c_oid from pg_class where oid = to_regclass(format('public.%I', :'c_old')) \gset

alter table public.rd339c detach partition :"c_old";
select pgpm.set_retain('public.rd339c', '1000');
select ok(pgpm._retain_boundary(c) is null or pgpm._retain_boundary(c)::bigint < 200,
  'LIVENESS: C: under the lengthened policy retention no longer reaches [100, 200)')
  from pgpm.config c where c.parent_table = 'public.rd339c'::regclass;
select pgpm.retain('public.rd339c');

select method as c_method from pgpm.log
 where parent_table = 'public.rd339c'::regclass and action = 'retain_disown' and lo = '100' \gset
select ok(:'c_method' like 'retention no longer reaches%',
  'LIVENESS: C: _retain_recall disowned the mark (retain_disown, retention no longer reaching it)');
select is((regexp_match(:'c_method', 'alter table [^;]+ attach partition [^;]+;'))[1],
  format('alter table public.rd339c attach partition public.%I for values from (%L) to (%L);', :'c_old', '100', '200'),
  'C: the remedy is the ATTACH of that table on its bounds, spelled as the statement to run');
select is((regexp_match(:'c_method', '(drop table [^;]+;|delete from pgpm\.part[^;]*;)'))[1], null,
  'C: and spells no DROP of the table and no DELETE of its row');
select ok(:'c_method' not like '%so retention retires it%' and :'c_method' like '%Do not drop it%',
  'C: and neither promises that retention retires it nor leaves the drop open');

-- the operator types the remedy the row spells: the drop remedy if it spells one, as in parts A and B, else the ATTACH
select coalesce((regexp_match(:'c_method', '(drop table [^;]+;(?: delete from pgpm\.part where [^;]+;)?)'))[1],
                (regexp_match(:'c_method', '(alter table [^;]+ attach partition [^;]+;)'))[1],
                'select 1;')
  as c_remedy \gset
:c_remedy

select is((select array_agg(id order by id) from public.rd339c), array[150, 160, 350]::bigint[],
  'C: after the remedy the parent serves rows 150 and 160 again, beside 350');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.rd339c'::regclass and p.child_name = :'c_old' and p.attached
                     and p.child_oid = :c_oid and i.inhparent = 'public.rd339c'::regclass and not i.inhdetachpending),
  'C: the very relation pgpm.part records is a partition of the parent again, under its row');
select max(id) as c_before from pgpm.log \gset
select pgpm.retain('public.rd339c');
select pgpm.retain('public.rd339c');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.rd339c'::regclass and id > :c_before and lo = '100'),
  null, 'C: and later retention leaves [100, 200) alone, logging nothing for it');
select is((select array_agg(id order by id) from public.rd339c), array[150, 160, 350]::bigint[],
  'C: its rows are still served after retention ran');

select is((select count(*)::int from pgpm.part where retiring_at is not null
            and parent_table in ('public.rd339a'::regclass, 'rd339s.rd339b'::regclass, 'public.rd339c'::regclass)),
  0, 'no retirement mark is left in flight by any part');

select * from finish();
