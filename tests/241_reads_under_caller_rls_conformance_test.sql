-- The RLS conformance suite (issue #873; the lever is pgpm._refuse_filtered_reads, #825). pgpm reads user
-- rows as the CALLER, and on a table with FORCE ROW LEVEL SECURITY a non-superuser owner without BYPASSRLS
-- reads only the rows its policies admit. Transmute leaves the monolith with its own ENABLE / FORCE and
-- policies, and carries them onto the parent, so every later read is filtered for such an owner: the
-- write frontier (max of the control column), regrain's copy of its source, untransmute's outside-rows
-- gate, the archive step's reads of a partition, the sampling checks, retention's search for the rows
-- referencing a retiring partition, and the orphan count. The invariant: pgpm never reads user rows under
-- a caller's row-level security without saying so. Each of those reads now asks the lever of the relation
-- it ACTUALLY reads (the parent, the monolith or source partition, a referencing table), before anything
-- is written, and refuses with pgpm's own message.
--
-- EXHAUSTIVENESS. Part Z enumerates every public routine of the pgpm schema from the catalog and requires
-- each to be classified below: 'refuses' (it reads user rows and is refused here, or in tests/218 and
-- tests/242), 'null answer' (status(), which reports no answer rather than a filtered one), or 'no user
-- rows' (with what it reads instead). A new entry point fails this file until someone decides which it
-- is. The archive and hypertable modules have their own halves (tests/archive/db/38,
-- tests/timescale/db/46), each enumerating its own routines.
--
-- ASYMMETRIC FIXTURES. Every table's policy hides a few named rows and admits the rest, and the hidden
-- ones are chosen where the filtered answer would differ from the true one (the largest id, a row a
-- referencing row points at, an orphan), so a read that saw only the visible rows cannot pass for one
-- that saw them all. Each fixture carries a witness that the owner's view really is short.
--
-- INSTRUMENT. The refused calls run as the owner through a SECURITY DEFINER function the owner owns
-- (tests/timescale/db/37's pattern: pgTAP's temp tables belong to the harness's role, so `set role` around
-- throws_* cannot work). The committing procedures (maintain, maintain_obtain and their sweeps) run as the
-- owner at the top level, where they can commit, and are judged by the skip rows they log: each step's
-- refusal is caught by the step's own handler, so the row's method carries pgpm's message. Fixtures that
-- isolate one site keep every other relation unfiltered for the owner (a parent set NO FORCE, a time grid
-- whose frontier is now()), so the refusal asserted is the one site's and no other check can stand in.
create extension if not exists pgtap;

select plan(48);

-- Roles are cluster-wide and the database is per-file, so the role is created only when absent and never
-- dropped (tests/72 explains why a DROP ROLE here would be the worse choice).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't241_owner') then
    create role t241_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to t241_owner;
grant usage on schema pgpm to t241_owner;
grant all on all tables in schema pgpm to t241_owner;
grant all on all sequences in schema pgpm to t241_owner;

set role t241_owner;
create function public.t241_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;

-- F1. ida241: an id grid, parent and monolith FORCE'd. The largest id (37) and ids 4 and 11 are hidden.
create table public.ida241 (id bigint primary key, tenant text not null);
insert into public.ida241 select g, case when g in (4, 11) then 'hid' else 'vis' end from generate_series(1, 20) g;
insert into public.ida241 values (37, 'hid');
alter table public.ida241 enable row level security;
alter table public.ida241 force row level security;
create policy ida241_vis on public.ida241 using (tenant = 'vis');

-- F2. ck241: a plain table for the sampling checks. Three plausible rows, and one hidden row whose
-- timestamp is five years ahead and whose n is the smallest, so the maximum and the order both differ.
create table public.ck241 (id uuid primary key, tt text not null, ts timestamptz not null, n bigint not null,
                           secret boolean not null);
insert into public.ck241
select pgpm._ts_to_uuid(now() - make_interval(days => g)),
       pgpm._ts_to_text_time(now() - make_interval(days => g), 'c', 8, 36, 'ms'),
       now() - make_interval(days => g), 10 - g, false
  from generate_series(1, 3) g;
insert into public.ck241 values (pgpm._ts_to_uuid(now() + interval '5 years'),
       pgpm._ts_to_text_time(now() + interval '5 years', 'c', 8, 36, 'ms'), now() + interval '5 years', 0, true);
alter table public.ck241 enable row level security;
alter table public.ck241 force row level security;
create policy ck241_visible on public.ck241 using (not secret);

-- F3. tc241: an id grid whose MONOLITH alone is FORCE'd (the parent is set NO FORCE after the
-- conversion), archived with pgpm._archive_noop, which counts the partition's rows. Ids 7, 14, ... hidden.
create table public.tc241 (id bigint primary key, tenant text not null);
insert into public.tc241 select g, case when g % 7 = 0 then 'hid' else 'vis' end from generate_series(1, 30) g;
alter table public.tc241 enable row level security;
alter table public.tc241 force row level security;
create policy tc241_vis on public.tc241 using (tenant = 'vis');

-- F4. tp241: a time grid (its frontier is now(), read from no row) with no row-level security at the
-- conversion; the owner puts FORCE and a policy on the PARENT afterwards, so the monolith reads whole and
-- only a read through the parent is filtered.
create table public.tp241 (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
insert into public.tp241 select g, now() - g * interval '6 hours', case when g in (2, 5) then 'hid' else 'vis' end
  from generate_series(1, 8) g;

-- F5. cr241 / ref241: an id grid without row-level security, referenced by a FORCE'd table whose policy
-- hides one of the two rows that point into the monolith.
create table public.cr241 (id bigint primary key, body text);
insert into public.cr241 select g, 'x' from generate_series(1, 30) g;

-- F6. oa241 / ra241 and ob241 / rb241: preserve-managed foreign keys left re-added but unvalidated by an
-- orphan. In the first pair the REFERENCING table is FORCE'd and hides one of the two orphans; in the
-- second the PARENT is FORCE'd and hides the row that one referencing row points at.
create table public.oa241 (id bigint primary key, body text);
insert into public.oa241 select g, 'x' from generate_series(1, 30) g;
create table public.ra241 (id bigint primary key, p_id bigint not null references public.oa241 (id), tenant text not null);
insert into public.ra241 values (1, 5, 'vis');
alter table public.ra241 enable row level security;
alter table public.ra241 force row level security;
create policy ra241_vis on public.ra241 using (tenant = 'vis');
create table public.ob241 (id bigint primary key, tenant text not null);
insert into public.ob241 select g, case when g = 7 then 'hid' else 'vis' end from generate_series(1, 30) g;
alter table public.ob241 enable row level security;
alter table public.ob241 force row level security;
create policy ob241_vis on public.ob241 using (tenant = 'vis');
create table public.rb241 (id bigint primary key, p_id bigint not null references public.ob241 (id));
insert into public.rb241 values (1, 5), (2, 7);

-- F7. ut241: a table of its own for untransmute, so a reverse that does not refuse takes no other fixture
-- with it. Parent and monolith FORCE'd; id 3 hidden.
create table public.ut241 (id bigint primary key, tenant text not null);
insert into public.ut241 select g, case when g = 3 then 'hid' else 'vis' end from generate_series(1, 8) g;
alter table public.ut241 enable row level security;
alter table public.ut241 force row level security;
create policy ut241_vis on public.ut241 using (tenant = 'vis');
reset role;

-- The conversions, by the harness's role, which bypasses row-level security (tests/218 part C).
call pgpm.transmute('public.ida241', 'id', 10::bigint, p_retain => 10::bigint, p_paused => false);
call pgpm.transmute('public.tc241', 'id', 10::bigint, p_retain => 100::bigint, p_paused => false);
insert into public.tc241 values (300, 'vis');     -- the frontier, far past the monolith: retention-eligible
select pgpm.set_archive_fn('public.tc241', 'pgpm._archive_noop(regclass, name, text, text)'::regprocedure);
call pgpm.transmute('public.tp241', 'ts', interval '1 day', p_paused => true);
call pgpm.transmute('public.cr241', 'id', 10::bigint, p_retain => 100::bigint, p_paused => true);
insert into public.cr241 values (300, 'frontier');
call pgpm.transmute('public.oa241', 'id', 10::bigint, p_incoming_fks => 'preserve', p_paused => true);
call pgpm.transmute('public.ob241', 'id', 10::bigint, p_incoming_fks => 'preserve', p_paused => true);
call pgpm.transmute('public.ut241', 'id', 10::bigint, p_paused => true);
-- Written while the preserved keys are suspended, the orphans the preserve lifecycle admits (tests/73).
insert into public.ra241 values (2, 9999, 'vis'), (3, 8888, 'hid');
insert into public.rb241 values (3, 9999);
select pgpm.restore_incoming_fks('public.oa241');
select pgpm.restore_incoming_fks('public.ob241');

-- The parent of tc241 is set NO FORCE, so only its monolith filters the owner; tp241's parent is FORCE'd
-- with a policy, so only it does; ref241 is created now, against cr241's parent.
set role t241_owner;
alter table public.tc241 no force row level security;
alter table public.tp241 enable row level security;
alter table public.tp241 force row level security;
create policy tp241_vis on public.tp241 using (tenant = 'vis');
create table public.ref241 (id bigint primary key, p_id bigint not null references public.cr241 (id) on delete cascade,
                            tenant text not null);
insert into public.ref241 values (1, 5, 'vis'), (2, 7, 'hid');
alter table public.ref241 enable row level security;
alter table public.ref241 force row level security;
create policy ref241_vis on public.ref241 using (tenant = 'vis');
create function public.t241_parent_count(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $f$
declare r pgpm.archive_result;
begin
  execute format('select count(*) from %s', p_parent) into r.rows_archived;   -- reads THROUGH the parent
  r.covered_hi := p_hi;
  return r;
end $f$;
reset role;
select pgpm.set_archive_fn('public.tp241', 'public.t241_parent_count(regclass, name, text, text)'::regprocedure);

select child_name as ida_mono from pgpm.part where parent_table = 'public.ida241'::regclass and lo = '0' \gset
select child_name as tc_mono from pgpm.part where parent_table = 'public.tc241'::regclass and lo = '0' \gset
select child_name as tp_mono, lo as tp_lo from pgpm.part
 where parent_table = 'public.tp241'::regclass and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.tp241'::regclass) \gset
select child_name as cr_mono from pgpm.part where parent_table = 'public.cr241'::regclass and lo = '0' \gset
select pgpm._install_write_block('public.tp241', :'tp_mono');   -- the archive candidate (see part F4)

-- What the owner can see of each, read once as the owner.
set role t241_owner;
select (select max(id) from public.ida241) as ida_max,
       (select count(*) from public.ck241) as ck,
       (select count(*) from public.tc241 where id < 100) as tc_parent,
       (select count(*) from public.tp241) as tp_parent,
       (select string_agg(id::text, ',' order by id) from public.ref241) as ref,
       (select string_agg(id::text, ',' order by id) from public.ra241) as ra,
       (select string_agg(id::text, ',' order by id) from public.ob241 where id in (5, 7)) as ob,
       row_security_active('public.ida241')::text as ida_rls,
       row_security_active(format('public.%I', :'ida_mono')::regclass)::text as ida_mono_rls,
       row_security_active('public.tc241')::text as tc_rls,
       row_security_active(format('public.%I', :'tc_mono')::regclass)::text as tc_mono_rls,
       row_security_active('public.tp241')::text as tp_rls,
       row_security_active(format('public.%I', :'tp_mono')::regclass)::text as tp_mono_rls,
       row_security_active('public.cr241')::text as cr_rls
\gset owner_
select count(*) as tc_mono from public.tc241 where id < 100 and tableoid = format('public.%I', :'tc_mono')::regclass \gset owner_
reset role;
select count(*) as tc_mono_all from public.tc241 where id < 100 \gset

-- ================= WITNESSES: the owner's reads really are filtered, where and only where intended =====
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't241_owner')
          || '/' || (select (rolsuper or rolbypassrls)::text from pg_roles where rolname = current_user), 'true/true',
  'LIVENESS: t241_owner is neither a superuser nor BYPASSRLS, and the harness''s role bypasses row-level security');
select is(:'owner_ida_max'::text || '/' || (select max(id) from public.ida241)::text, '20/37',
  'LIVENESS: (F1) the owner''s largest id of ida241 is 20; the true one is 37');
select is(:'owner_ida_rls'::text || '/' || :'owner_ida_mono_rls'::text, 'true/true',
  'LIVENESS: (F1) row-level security filters the owner on ida241''s parent and on its monolith');
select is(:'owner_ck'::text || '/' || (select count(*) from public.ck241)::text, '3/4',
  'LIVENESS: (F2) the owner sees 3 of ck241''s 4 rows, the future-dated one hidden');
select is(:'owner_tc_rls'::text || '/' || :'owner_tc_mono_rls'::text || '/' || :'owner_tc_parent'::text, 'false/true/30',
  'LIVENESS: (F3) tc241''s parent no longer filters the owner (all 30 rows through it), its monolith still does');
select is(:'owner_tc_mono'::text || '/' || :'tc_mono_all'::text, '30/30',
  'LIVENESS: (F3) through the unfiltered parent the owner sees all 30 monolith rows');
select is(:'owner_tp_rls'::text || '/' || :'owner_tp_mono_rls'::text || '/' || :'owner_tp_parent'::text, 'true/false/6',
  'LIVENESS: (F4) tp241''s parent filters the owner (6 of 8 rows), its monolith does not');
select is(:'owner_ref'::text || '/' || (select string_agg(id || '->' || p_id, ',' order by id) from public.ref241), '1/1->5,2->7',
  'LIVENESS: (F5) the owner sees ref241''s row 1 (-> 5) and not row 2 (-> 7), both into cr241''s monolith');
select is(:'owner_cr_rls'::text, 'false', 'LIVENESS: (F5) cr241 itself does not filter the owner');
select is(:'owner_ra'::text || '/' || (select string_agg(id || '->' || p_id, ',' order by id) from public.ra241),
  '1,2/1->5,2->9999,3->8888', 'LIVENESS: (F6) ra241 holds two orphans (9999, 8888) and the owner sees one');
select is((select string_agg(referencing_table::text || '=' || orphan_rows, ',' order by referencing_table::text)
             from (select * from pgpm.incoming_fk_orphans('public.oa241')
                   union all select * from pgpm.incoming_fk_orphans('public.ob241')) o),
  'ra241=2,rb241=1', 'LIVENESS: (F6) read by a role row-level security does not filter, ra241 has 2 orphans and rb241 has 1');
select is(:'owner_ob'::text, '5', 'LIVENESS: (F6) the owner cannot see ob241''s row 7, which rb241''s row 2 points at');

-- ================= C1. the write frontier: read through the parent, refused =================
select throws_like($$ select public.t241_as_owner('select pgpm.obtain(''public.ida241'')') $$,
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%obtain, retention and regrain would place the grid by it. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'C1: obtain refuses the owner, whose largest id is not the table''s');
select throws_like($$ select public.t241_as_owner('select pgpm.extend_to(''public.ida241'', ''200'')') $$,
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%',
  'C1: so does extend_to');
select throws_like($$ select public.t241_as_owner('select * from pgpm.progress(''public.ida241'')') $$,
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%',
  'C1: and progress(), which reports the frontier');
select throws_like($$ select public.t241_as_owner('select pgpm.retain(''public.ida241'')') $$,
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%',
  'C1: and retain(), whose horizon on an id grid is the frontier less the retention');
select throws_like(format($$ select public.t241_as_owner('select pgpm.retire(''public.ida241'', ''%s'')') $$, :'ida_mono'),
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%',
  'C1: and retire()');
select throws_like($$ select public.t241_as_owner('select pgpm.set_retain(''public.ida241'', ''20'')') $$,
  'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%',
  'C1: and set_retain(), which compares the old horizon with the new');
set role t241_owner;
select (retain_backlog is null)::text as backlog_null from pgpm.status() where parent = 'public.ida241'::regclass \gset owner_
reset role;
select is(:'owner_backlog_null'::text || '/' || ((select retain_backlog from pgpm.status() where parent = 'public.ida241'::regclass) is not null)::text,
  'true/true', 'C1: status() gives the owner no retain_backlog for ida241 (null) where the harness''s role gets one');
set role t241_owner;
call pgpm.maintain_obtain('public.ida241');
call pgpm.maintain('public.ida241');
reset role;
select is((select string_agg(action, ',' order by action) from pgpm.log
            where parent_table = 'public.ida241'::regclass and action like 'skip%'
              and method like 'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%'),
  'skip_obtain,skip_retain,skip_write_block',
  'C1: maintain_obtain and maintain log their frontier-reading steps as deferred, each with pgpm''s message');
select is((select count(*)::int from pgpm.part where parent_table = 'public.ida241'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.ida241 where id in (4, 11, 37)), '31/4,11,37',
  'C1 (invariant): ida241''s grid is the conversion''s (a monolith and 30 forward partitions), its hidden rows in place');

-- ================= C2, C3. regrain and untransmute (tests/242 holds them by identity) =================
select throws_like(format($$ select public.t241_as_owner('select pgpm.regrain(''public.ida241'', ''%s'', ''5'')') $$, :'ida_mono'),
  format('pg_partition_magician: cannot regrain %s as t241_owner -- row-level security is active on it for that role%%the swap would drop the others with the source%%', :'ida_mono'),
  'C2: regrain refuses the owner, naming the monolith it would copy');
select throws_like(format($$ select public.t241_as_owner('select pgpm.regrain_step(''public.ida241'', ''%s'', ''5'')') $$, :'ida_mono'),
  format('pg_partition_magician: cannot regrain %s as t241_owner -- row-level security is active on it%%', :'ida_mono'),
  'C2: so does regrain_step');
select throws_like($$ select public.t241_as_owner('select pgpm.regrain_history(''public.ida241'', ''5'')') $$,
  format('pg_partition_magician: cannot regrain %s as t241_owner -- row-level security is active on it%%', :'ida_mono'),
  'C2: and regrain_history');
select throws_like($$ select public.t241_as_owner('select pgpm.untransmute(''public.ut241'')') $$,
  'pg_partition_magician: cannot untransmute ut241 as t241_owner -- row-level security is active on it for that role%the reverse would drop them with the parent%',
  'C3: untransmute refuses the owner');

-- ================= C4. the archive step, a strategy reading through the parent =================
set role t241_owner;
select pgpm._archive_step('public.tp241') as tp_archived \gset owner_
reset role;
select is(:'owner_tp_archived'::text || '/' || (select count(*) from pgpm.archive_ledger where parent_table = 'public.tp241'::regclass)::text,
  '0/0', 'C4: the archive step recorded no chunk of tp241 for the owner');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tp241'::regclass and action = 'skip_archive'
              and lo = :'tp_lo'
              and method like 'pg_partition_magician: cannot archive a partition of tp241 as t241_owner -- row-level security is active on it for that role%'),
  1, 'C4: and logged the monolith''s turn skip_archive, refused because the parent filters the owner');
select ok(pgpm._is_write_blocked('public.tp241', :'tp_mono'),
  'LIVENESS: (C4) the monolith was a candidate (write-blocked, not covered) when the owner''s step ran');

-- ================= C5. the archive step, a strategy reading the partition itself =================
set role t241_owner;
call pgpm.maintain('public.tc241');
reset role;
select ok((select count(*) from pgpm.log where parent_table = 'public.tc241'::regclass and action = 'skip_archive' and lo = '0')
          + (select count(*) from pgpm.archive_ledger where parent_table = 'public.tc241'::regclass and child_name = :'tc_mono') >= 1,
  'LIVENESS: (C5) the owner''s tick reached tc241''s monolith in its archive step (its frontier read through the unfiltered parent wrote the block)');
select is((select string_agg(id::text, ',' order by id) from public.tc241 where tenant = 'hid')
          || '/' || pgpm._is_write_blocked('public.tc241', :'tc_mono')::text, '7,14,21,28/true',
  'C5: the monolith is still there, write-blocked, with its hidden rows by identity');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tc241'::regclass and action = 'skip_archive'
              and method like format('pg_partition_magician: cannot archive %s as t241_owner -- row-level security is active on it for that role%%', :'tc_mono')),
  1, 'C5: the tick logged the monolith''s archive turn skip_archive, naming the monolith');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.tc241'::regclass), 0,
  'C5: and recorded no chunk: no ledger row counts the visible rows as the partition''s');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tc241'::regclass and action like 'skip%'
              and method like 'pg_partition_magician: cannot read the write frontier%'), 0,
  'C5: no other step refused (the parent''s reads were not the ones filtered)');

-- ================= C6 to C8. the sampling checks =================
select throws_like($$ select public.t241_as_owner('select * from pgpm.check_uuidv7(''public.ck241'', ''id'')') $$,
  'pg_partition_magician: cannot sample ck241 as t241_owner -- row-level security is active on it for that role%check_uuidv7 would report%',
  'C6: check_uuidv7 refuses the owner');
select throws_like($$ select public.t241_as_owner('select * from pgpm.check_text_time(''public.ck241'', ''tt'', ''c'', 8, 36, ''ms'')') $$,
  'pg_partition_magician: cannot sample ck241 as t241_owner -- row-level security is active on it for that role%check_text_time would report%',
  'C7: check_text_time refuses the owner');
select throws_like($$ select public.t241_as_owner('select * from pgpm.check_time_monotonic(''public.ck241'', ''n'', ''ts'')') $$,
  'pg_partition_magician: cannot sample ck241 as t241_owner -- row-level security is active on it for that role%check_time_monotonic would report%',
  'C8: check_time_monotonic refuses the owner');
select ok((select newest_in_future from pgpm.check_uuidv7('public.ck241', 'id'))
          and (select newest_in_future from pgpm.check_text_time('public.ck241', 'tt', 'c', 8, 36, 'ms'))
          and (select fraction < 1 from pgpm.check_time_monotonic('public.ck241', 'n', 'ts')),
  'LIVENESS: (C6-C8) read whole, the column''s maximum is future-dated and n and ts do not co-increase');

-- ================= C9. retention's crossing keys, read from the referencing table =================
select throws_like(format($$ select public.t241_as_owner('select pgpm.retire(''public.cr241'', ''%s'')') $$, :'cr_mono'),
  'pg_partition_magician: cannot read the rows referencing a retiring partition from ref241 as t241_owner -- row-level security is active on it for that role%the detach would then be refused by the others%',
  'C9: retire refuses the owner, naming the referencing table its policies filter');
select is((select string_agg(id::text, ',' order by id) from public.cr241 where id in (5, 7))
          || '/' || (select string_agg(id || '->' || p_id, ',' order by id) from public.ref241), '5,7/1->5,2->7',
  'C9: both referenced rows and both referencing rows are where they were');
select is((select count(*)::int from pgpm.log where parent_table = 'public.cr241'::regclass and action in ('retain_crossing', 'fail_retain_crossing')), 0,
  'C9: and no crossing delete was attempted');
select ok((select retain_backlog from pgpm.status() where parent = 'public.cr241'::regclass) >= 1,
  'LIVENESS: (C9) cr241''s monolith is past the retention horizon, so retire reached the crossing');

-- ================= C10. the orphan count =================
select throws_like($$ select public.t241_as_owner('select * from pgpm.incoming_fk_orphans(''public.oa241'')') $$,
  'pg_partition_magician: cannot count the orphans in ra241 as t241_owner -- row-level security is active on it for that role%',
  'C10: incoming_fk_orphans refuses the owner whose referencing table hides an orphan');
select throws_like($$ select public.t241_as_owner('select * from pgpm.incoming_fk_orphans(''public.ob241'')') $$,
  'pg_partition_magician: cannot count the orphans against ob241 as t241_owner -- row-level security is active on it for that role%',
  'C10: and the owner whose parent hides a referenced row');

-- ================= the sweeps =================
update pgpm.config set obtain_retry_after = null where parent_table = 'public.ida241'::regclass;
select max(id) as log_before from pgpm.log \gset
set role t241_owner;
call pgpm.maintain_obtain_all();
call pgpm.maintain_all();
reset role;
select is((select string_agg(action, ',' order by action) from pgpm.log
            where id > :log_before and parent_table = 'public.ida241'::regclass and action like 'skip%'
              and method like 'pg_partition_magician: cannot read the write frontier of ida241 as t241_owner -- row-level security is active on it%'),
  'skip_obtain,skip_retain,skip_write_block', 'SWEEPS: maintain_obtain_all and maintain_all defer ida241''s reading steps the same way');

-- ================= the conversions a role the lever passes can still make =================
select lives_ok($$ select pgpm.obtain('public.ida241') $$,
  'LIVENESS: obtain runs for the harness''s role, which row-level security does not filter');
select is((select count(*)::int from pgpm.check_uuidv7('public.ck241', 'id')), 1,
  'LIVENESS: and check_uuidv7 answers it from every row');

-- ================= Z. every public entry point is classified =================
create temp table t241_entry (sig text primary key, verdict text not null check (verdict in ('refuses', 'null answer', 'no user rows')),
                              what text not null);
insert into t241_entry values
  ('pgpm.adopt_partition(regclass,regclass)', 'no user rows', 'pgpm state and the catalog: the partition''s bounds from pg_class'),
  ('pgpm.check_text_time(regclass,name,text,integer,integer,text,integer,text,integer,timestamp with time zone)', 'refuses', 'samples the table (C7)'),
  ('pgpm.check_time_monotonic(regclass,name,name,integer)', 'refuses', 'samples the table (C8)'),
  ('pgpm.check_uuidv7(regclass,name,integer)', 'refuses', 'samples the table (C6)'),
  ('pgpm.extend_to(regclass,text,integer)', 'refuses', 'the write frontier, through the parent (C1)'),
  ('pgpm.forget_missing()', 'no user rows', 'pgpm state and pg_class'),
  ('pgpm.hand_over_scratch(regclass)', 'no user rows', 'pgpm state and the catalog: OWNER TO on pgpm''s scratch relations'),
  ('pgpm.impact_report(regclass,interval)', 'no user rows', 'pgpm.log and pg_flight_recorder'),
  ('pgpm.incoming_fk_orphans(regclass)', 'refuses', 'the referencing table and the parent (C10)'),
  ('pgpm.maintain_all()', 'refuses', 'each parent''s maintain (SWEEPS)'),
  ('pgpm.maintain_obtain_all()', 'refuses', 'each parent''s maintain_obtain (SWEEPS)'),
  ('pgpm.maintain_obtain(regclass,text)', 'refuses', 'the frontier (C1): its step logs skip_obtain'),
  ('pgpm.maintain(regclass,text)', 'refuses', 'the frontier, the archive step, retention and regrain (C1, C5, tests/242): each step logs its skip'),
  ('pgpm.observe_window(regclass,interval)', 'no user rows', 'pgpm.log'),
  ('pgpm.obtain(regclass)', 'refuses', 'the write frontier (C1)'),
  ('pgpm.pause(regclass)', 'no user rows', 'pgpm.config'),
  ('pgpm.progress(regclass)', 'refuses', 'the write frontier (C1)'),
  ('pgpm.regrain_cancel(regclass)', 'no user rows', 'drops the copies and empties the delta, reading neither'),
  ('pgpm.regrain_history(regclass,text)', 'refuses', 'the source partition, through regrain (C2)'),
  ('pgpm.regrain(regclass,name,text)', 'refuses', 'the source partition (C2, tests/242)'),
  ('pgpm.regrain_step(regclass,name,text,integer)', 'refuses', 'the source partition (C2, tests/242)'),
  ('pgpm.restore_incoming_fks(regclass,bigint[])', 'no user rows', 'DDL; the foreign key''s own validation, which row-level security does not filter'),
  ('pgpm.resume(regclass)', 'no user rows', 'pgpm.config'),
  ('pgpm.retain(regclass)', 'refuses', 'the frontier on an id grid, and retire''s reads (C1, C9)'),
  ('pgpm.retire(regclass,name)', 'refuses', 'the frontier on an id grid, and the rows referencing the partition (C1, C9)'),
  ('pgpm.schedule(text,text)', 'no user rows', 'pg_cron'),
  ('pgpm.set_archive_fn(regclass,regprocedure)', 'no user rows', 'pgpm.config and pg_proc'),
  ('pgpm.set_obtain(regclass,integer)', 'no user rows', 'pgpm.config'),
  ('pgpm.set_partition_tz(regclass,text)', 'no user rows', 'pgpm.config and pgpm.part'),
  ('pgpm.set_regrain(regclass,text)', 'no user rows', 'pgpm.config and pgpm.part'),
  ('pgpm.set_retain(regclass,text)', 'refuses', 'the frontier on an id grid (C1)'),
  ('pgpm.status()', 'null answer', 'retain_backlog is null where the frontier read would be filtered (C1)'),
  ('pgpm.suspend_incoming_fks(regclass,boolean)', 'no user rows', 'drops foreign keys'),
  ('pgpm.transmute_abort(regclass,text)', 'no user rows', 'pgpm state and the catalog'),
  ('pgpm.transmute(regclass,name,bigint,integer,bigint,integer,bigint,boolean,text,integer,text)', 'refuses', 'the table it converts (#825, tests/218)'),
  ('pgpm.transmute(regclass,name,interval,integer,interval,integer,timestamp with time zone,boolean,text,boolean,integer,text,text,integer,integer,text,boolean,text,integer,timestamp with time zone,boolean)', 'refuses', 'the table it converts (#825, tests/218)'),
  ('pgpm.unschedule()', 'no user rows', 'pg_cron'),
  ('pgpm.untransmute(regclass)', 'refuses', 'the parent, for its outside-rows gate (C3, tests/242)'),
  ('pgpm.validate_incoming_fks(regclass,boolean)', 'no user rows', 'DDL; the foreign key''s own validation, which row-level security does not filter'),
  ('pgpm.version()', 'no user rows', 'a constant');
select set_eq(
  $$ select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'pgpm'::regnamespace and p.proname !~ '^_' $$,
  $$ select sig from t241_entry $$,
  'Z: every public routine of the pgpm schema is classified here (a new one fails this until it is)');
select is((select count(*)::int from t241_entry where verdict = 'refuses'), 20,
  'LIVENESS: (Z) the classification is not vacuous: 20 entry points read user rows and are refused above or in tests/218 and 242');

select * from finish();
