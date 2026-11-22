-- No partition is made under a name a dropped table's retirement still records (#1487).
--
-- THE BUG. A referenced partition's retirement arms the pgpm_detach job with `ALTER TABLE <parent> DETACH PARTITION
-- <child> CONCURRENTLY`, by NAME. When the table is dropped with a plain DROP TABLE before the job runs it, and
-- re-created under the same name and converted on the same grid WITHOUT pgpm.forget_missing() (the only thing that
-- returns the job to idle, #893), the new table's partition of that name, a pure function of the table's name and
-- grid, was detached by the job's next run: its rows out of every read of the parent, no mark, nothing logged.
--
-- THE CONTRACT. While a pgpm.part row of a dropped parent records a retirement whose detach a job may hold (dispatched,
-- or a mark older than #1451's record), nothing pgpm does makes or names a partition under that name, and the refusal
-- names pgpm.forget_missing() as the remedy. It reads pgpm's own tables only.
--   PART A  transmute refuses (phase 1, nothing committed) a conversion whose monolith takes the name, also when run
--           by a role that cannot read cron.job at all; after forget_missing() the same conversion goes through and
--           pg_cron's next run of the job leaves every row of the namesake in place.
--   PART B  extend_to and the tick's obtain leave that one cell unbuilt, logged fail_obtain_name with the remedy, and
--           build every other cell (the tick is not deferred); after forget_missing() the next obtain builds it.
--   PART C  a regrain that would RENAME its source to the name refuses before the rename.
--   PART D  a regrain that would CREATE a fine child under the name refuses before the create, and the tick's
--           auto-regrain logs skip_regrain carrying the remedy; after forget_missing() the tick's regrain finishes.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- and cron.alter_job, as tests/246 does, and runs pg_cron's run of the job with \gexec at the top level.
--
-- ASYMMETRIC FIXTURES. Each part's old and new tables hold different id sets (A 1-3 then 4, 5; B 1, 15 then 3;
-- C 1, 15 then 6; D 2, 17 then 7, 18), so an assertion aimed at the wrong table cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(33);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pgpm_test396_owner') then
    create role pgpm_test396_owner nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema pgpm to pgpm_test396_owner;
grant all on all tables in schema pgpm to pgpm_test396_owner;
grant all on all sequences in schema pgpm to pgpm_test396_owner;
grant create, usage on schema public to pgpm_test396_owner;
-- whether the dropped tables' state records a dispatched retirement of p_name
create function pg_temp.recorded(p_name name) returns boolean language sql as $$
  select exists (select 1 from pgpm.part p where p.child_name = p_name and p.retiring_at is not null
                   and p.detach_dispatched_oid is not null
                   and not exists (select 1 from pg_class c where c.oid = p.parent_table))
$$;

-- ==================== (A) transmute: the monolith takes the name ====================
create table public.ga396 (id bigint primary key, payload text);
insert into public.ga396 values (1, 'a'), (2, 'b'), (3, 'c');
call pgpm.transmute('public.ga396', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => true);
insert into public.ga396 values (55, 'frontier');
create table public.ga396_ref (id bigint primary key, r bigint references public.ga396 (id));
insert into public.ga396_ref values (1, 55);
select child_name as a_doomed from pgpm.part where parent_table = 'public.ga396'::regclass and lo = '0' \gset
select is(pgpm.retire('public.ga396', :'a_doomed'), false, 'LIVENESS: (A) retire() takes the referenced path');
select is((select command from cron.job where jobid = 1),
  format('alter table public.ga396 detach partition public.%I concurrently', :'a_doomed'),
  'LIVENESS: (A) and armed the job with the monolith''s detach');
select 'public.ga396'::regclass::oid as a_oid \gset
drop table public.ga396_ref;
drop table public.ga396 cascade;
select ok(pg_temp.recorded(:'a_doomed'), 'LIVENESS: (A) the dropped table''s state records the dispatched retirement');
-- re-created by a role that cannot read cron at all
set role pgpm_test396_owner;
create table public.ga396 (id bigint primary key, payload text);
insert into public.ga396 values (4, 'new-d'), (5, 'new-e');
select set_config('t396.a_cron', has_schema_privilege('cron', 'usage')::text, false);
do $$
begin
  call pgpm.transmute('public.ga396', 'id', 10::bigint, p_obtain => 6, p_paused => true);
  perform set_config('t396.a', 'not refused', false);
exception when others then
  perform set_config('t396.a', sqlstate || ' ' || sqlerrm, false);
end $$;
reset role;
select is(current_setting('t396.a_cron'), 'false', 'LIVENESS: (A) the role converting it has no access to schema cron');
select ok(current_setting('t396.a') ~ ('^P0001 pg_partition_magician: transmute refused to make partition ' || :'a_doomed'
            || ': run pgpm\.forget_missing\(\) first\.'),
  'A: transmute refuses the name, naming forget_missing()');
select ok((select relkind = 'r' from pg_class where oid = 'public.ga396'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.ga396'::regclass),
  'A: and leaves the table unconverted');
select is((select array_agg(id order by id) from public.ga396), array[4, 5]::bigint[], 'A: with its rows 4, 5');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:a_oid]::oid[],
  'LIVENESS: (A) forget_missing() forgets the dropped table');
select is((select command from cron.job where jobid = 1), 'select 1', 'LIVENESS: (A) and idles the job');
call pgpm.transmute('public.ga396', 'id', 10::bigint, p_obtain => 6, p_paused => true);
select ok(exists (select 1 from pg_inherits where inhparent = 'public.ga396'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'a_doomed'))),
  'A: then the conversion goes through, its monolith under that name');
select command from cron.job where jobid = 1 \gexec
select is((select array_agg(id order by id) from public.ga396), array[4, 5]::bigint[],
  'A: and pg_cron''s next run of the job leaves rows 4, 5 in it');

-- ==================== (B) extend_to and the tick's obtain ====================
create table public.gb396 (id bigint primary key, payload text);
insert into public.gb396 values (1, 'a');
call pgpm.transmute('public.gb396', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => true);
insert into public.gb396 values (15, 'old'), (55, 'frontier');
create table public.gb396_ref (id bigint primary key, r bigint references public.gb396 (id));
insert into public.gb396_ref values (1, 55);
select child_name as b_doomed from pgpm.part where parent_table = 'public.gb396'::regclass and lo = '10' \gset
select is(pgpm.retire('public.gb396', :'b_doomed'), false, 'LIVENESS: (B) retire() dispatches the [10, 20) cell''s detach');
select 'public.gb396'::regclass::oid as b_oid \gset
drop table public.gb396_ref;
drop table public.gb396 cascade;
create table public.gb396 (id bigint primary key, payload text);
insert into public.gb396 values (3, 'new-c');
call pgpm.transmute('public.gb396', 'id', 10::bigint, p_obtain => 0, p_paused => false);
select is(pgpm.extend_to('public.gb396', '35'), 2, 'B: extend_to builds two cells');
select is((select array_agg(lo order by lo::bigint) from pgpm.part where parent_table = 'public.gb396'::regclass),
  array['0', '20', '30'], 'B: [20, 30) and [30, 40), leaving [10, 20) unbuilt');
select ok(to_regclass(format('public.%I', :'b_doomed')) is null, 'B: and nothing takes the recorded name');
select ok((select method from pgpm.log where parent_table = 'public.gb396'::regclass and lo = '10'
            and action = 'fail_obtain_name' order by id desc limit 1) ~ 'a dropped table''s pgpm state.*run pgpm\.forget_missing\(\)',
  'B: the hole is logged fail_obtain_name, naming forget_missing()');
select pgpm.set_obtain('public.gb396', 6);
call pgpm.maintain_obtain('public.gb396');
select is((select array_agg(lo order by lo::bigint) from pgpm.part where parent_table = 'public.gb396'::regclass),
  array['0', '20', '30', '40', '50', '60'], 'B: the tick''s obtain builds every other cell of its lookahead');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.gb396'::regclass
            and action in ('skip_obtain', 'fail_obtain_name')),
  array['fail_obtain_name', 'fail_obtain_name'], 'B: logs the hole again, and is not deferred (no skip_obtain)');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:b_oid]::oid[],
  'LIVENESS: (B) forget_missing() forgets the dropped table');
call pgpm.maintain_obtain('public.gb396');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.gb396'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'b_doomed'))),
  'B: then the next obtain builds the cell under that name');

-- ==================== (C) regrain: the source's rename for its split ====================
create table public.gc396 (id bigint primary key, payload text);
insert into public.gc396 values (1, 'a'), (15, 'o');
call pgpm.transmute('public.gc396', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => true);
insert into public.gc396 values (55, 'frontier');
create table public.gc396_ref (id bigint primary key, r bigint references public.gc396 (id));
insert into public.gc396_ref values (1, 55);
select child_name as c_doomed from pgpm.part where parent_table = 'public.gc396'::regclass and lo = '0' \gset
select is(pgpm.retire('public.gc396', :'c_doomed'), false, 'LIVENESS: (C) retire() dispatches the [0, 20) monolith''s detach');
select 'public.gc396'::regclass::oid as c_oid \gset
drop table public.gc396_ref;
drop table public.gc396 cascade;
create table public.gc396 (id bigint primary key, payload text);
insert into public.gc396 values (6, 'new-f');
call pgpm.transmute('public.gc396', 'id', 20::bigint, p_obtain => 0, p_paused => true);
select pgpm.extend_to('public.gc396', '45');
insert into public.gc396 values (45, 'frontier');
select child_name as c_src from pgpm.part where parent_table = 'public.gc396'::regclass and lo = '0' \gset
select is(pgpm._part_name('gc396', 'id', '10', '0', '20', 'UTC'), :'c_doomed',
  'LIVENESS: (C) regraining [0, 20) to a step of 10 renames its source to the recorded name');
select throws_like(format($$select pgpm.regrain('public.gc396', %L, '10')$$, :'c_src'),
  '%refused to make partition ' || :'c_doomed' || ': run pgpm.forget_missing() first%',
  'C: regrain refuses the rename, naming forget_missing()');
select ok(exists (select 1 from pg_inherits where inhparent = 'public.gc396'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'c_src'))),
  'C: and the source keeps its name, attached');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:c_oid]::oid[],
  'LIVENESS: (C) forget_missing() forgets the dropped table');

-- ==================== (D) regrain: a fine child's create, by hand and in the tick ====================
create table public.gd396 (id bigint primary key, payload text);
insert into public.gd396 values (2, 'b');
call pgpm.transmute('public.gd396', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint, p_paused => true);
insert into public.gd396 values (17, 'o'), (55, 'frontier');
create table public.gd396_ref (id bigint primary key, r bigint references public.gd396 (id));
insert into public.gd396_ref values (1, 55);
select child_name as d_doomed from pgpm.part where parent_table = 'public.gd396'::regclass and lo = '10' \gset
select is(pgpm.retire('public.gd396', :'d_doomed'), false, 'LIVENESS: (D) retire() dispatches the [10, 20) cell''s detach');
select 'public.gd396'::regclass::oid as d_oid \gset
drop table public.gd396_ref;
drop table public.gd396 cascade;
create table public.gd396 (id bigint primary key, payload text);
insert into public.gd396 values (7, 'new-g'), (18, 'new-r');
call pgpm.transmute('public.gd396', 'id', 10::bigint, p_obtain => 6, p_paused => false);
insert into public.gd396 values (45, 'frontier');
select child_name as d_src from pgpm.part where parent_table = 'public.gd396'::regclass and lo = '0' \gset
select is((select hi from pgpm.part where parent_table = 'public.gd396'::regclass and lo = '0'), '20',
  'LIVENESS: (D) the new monolith spans [0, 20), whose fine child [10, 20) takes the recorded name');
select throws_like(format($$select pgpm.regrain('public.gd396', %L, '10')$$, :'d_src'),
  '%refused to make partition ' || :'d_doomed' || ': run pgpm.forget_missing() first%',
  'D: regrain refuses the fine child''s create, naming forget_missing()');
select pgpm.set_regrain('public.gd396', '10');
do $$ declare s text; begin for i in 1 .. 6 loop call pgpm.maintain('public.gd396', s); end loop; end $$;
select ok((select method from pgpm.log where parent_table = 'public.gd396'::regclass and action = 'skip_regrain'
            order by id desc limit 1) like '%refused to make partition ' || :'d_doomed' || ': run pgpm.forget_missing() first%',
  'D: the tick''s auto-regrain logs skip_regrain, carrying the remedy');
select ok(to_regclass(format('public.%I', :'d_doomed')) is null, 'D: and nothing takes the recorded name');
select is((select array_agg(parent_oid) from pgpm.forget_missing()), array[:d_oid]::oid[],
  'LIVENESS: (D) forget_missing() forgets the dropped table');
do $$ declare s text; begin for i in 1 .. 8 loop call pgpm.maintain('public.gd396', s); end loop; end $$;
select ok(exists (select 1 from pg_inherits where inhparent = 'public.gd396'::regclass
                    and inhrelid = to_regclass(format('public.%I', :'d_doomed'))),
  'D: then the tick''s regrain swaps in the fine child under that name');
select is((select array_agg(id order by id) from public.gd396), array[7, 18, 45]::bigint[], 'D: with every row: 7, 18, 45');

select * from finish();
