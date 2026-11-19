-- untransmute() returns the pgpm_detach job to idle when it forgets a retirement that armed it (issue #954).
--
-- THE GAP. A referenced partition's retirement arms the standing pgpm_detach job with `ALTER TABLE <parent> DETACH
-- PARTITION <child> CONCURRENTLY` and leaves the partition attached until pg_cron runs it. untransmute deletes every
-- pgpm.part row of the parent, a retiring one included, and never touched the job, so after the reverse pg_cron
-- re-ran a detach against the restored plain table on every tick ("table ... is not partitioned"), for good, and
-- the one detach slot the database has stayed taken. forget_missing() had the same gap and was fixed by #893; this is
-- its sibling one call away.
--
-- REACHABLE on a 'time' grid, whose frontier is now(): a table whose newest row is days old converts with forward
-- cells already in the past, which retention reaches while every row still lives in the monolith, so untransmute's
-- gate passes. The incoming key makes retire() take the referenced (dispatched-detach) path.
--
-- THE CONTRACT.
--   PART A  untransmute with a retirement armed returns the job to idle (`select 1`).
--   PART B  a command the job holds for ANOTHER table's retirement is left alone (the disarm is conditional, as
--           every disarm since #407 is).
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for cron.job
-- and cron.alter_job, as tests/194, 204, 229 and 246 do. bench/retain_edges_tap.sh runs this file against the
-- mutants that leave the job armed (part A) or idle it whatever it holds (part B).
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(12);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

-- ==================== (A) untransmute with a forward cell's retirement armed ====================
create table public.t383 (ts timestamptz primary key, payload text);
insert into public.t383 values (now() - interval '9 seconds', 'a'), (now() - interval '8 seconds', 'b'), (now() - interval '7 seconds', 'c');
create table public.t383_ref (id bigint primary key, t_ts timestamptz references public.t383 (ts));
insert into public.t383_ref values (100, (select min(ts) from public.t383));
call pgpm.transmute('public.t383', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval,
                    p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.t383');

-- the first forward cell: the attached partition just above the monolith. A 1-second grid with retain 0 stands in
-- for days of quiet: wait, in a statement of its own, until the cell's hi is a second behind now()
select p.child_name as fwd from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
 where p.parent_table = 'public.t383'::regclass and p.child_oid is distinct from c.monolith_oid
 order by p.lo limit 1 \gset
select pg_sleep(greatest(0, extract(epoch from hi::timestamptz - clock_timestamp()) + 1.2)) from pgpm.part where child_name = :'fwd';

select ok((select not pgpm._native_gt('time', p.hi, pgpm._retain_boundary(c))
             from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table where p.child_name = :'fwd'),
  'LIVENESS: the first forward cell lies wholly past the retention horizon');
select ok(exists (select 1 from pg_constraint where confrelid = 'public.t383'::regclass and contype = 'f'),
  'LIVENESS: the parent is referenced by a live incoming key');
select is(pgpm.retire('public.t383', :'fwd'), false,
  'LIVENESS: retire() of the empty forward cell takes the referenced path');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.t383 detach partition public.%I concurrently', :'fwd'),
  'LIVENESS: and armed pgpm_detach with that cell''s detach');
select ok((select retiring_at is not null and attached from pgpm.part where child_name = :'fwd'),
  'LIVENESS: the cell is marked retiring and still attached');

select lives_ok($$select pgpm.untransmute('public.t383')$$,
  'LIVENESS: untransmute() succeeds with the retirement in flight');
select is((select relkind::text from pg_class where oid = 'public.t383'::regclass), 'r',
  'LIVENESS: the restored table is a plain table again');
select ok(not exists (select 1 from pgpm.part where child_name = :'fwd'),
  'LIVENESS: and the retiring row went with the rest of the table''s pgpm state');
select is((select command from cron.job where jobname = 'pgpm_detach'), 'select 1',
  'untransmute() returned pgpm_detach to idle when it forgot the retirement that armed it');
select is((select array_agg(payload order by ts) from public.t383), array['a', 'b', 'c'],
  'the restored table holds exactly its three rows');

-- ==================== (B) another table's detach is left armed ====================
create table public.u383 (ts timestamptz primary key, payload text);
insert into public.u383 values (now() - interval '9 seconds', 'x');
call pgpm.transmute('public.u383', 'ts', '1 second'::interval, p_obtain => 4, p_retain => '0 seconds'::interval, p_paused => true);
select p.child_name as ufwd from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
 where p.parent_table = 'public.u383'::regclass and p.child_oid is distinct from c.monolith_oid
 order by p.lo limit 1 \gset
-- a retirement of u383's that pgpm recorded as in flight, and a job armed with some other table's detach
update pgpm.part set retiring_at = now() where child_name = :'ufwd';
update cron.job set command = 'alter table public.elsewhere detach partition public.elsewhere_p1 concurrently'
 where jobname = 'pgpm_detach';
select lives_ok($$select pgpm.untransmute('public.u383')$$,
  'LIVENESS: B''s untransmute() succeeds with a retiring row of its own');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  'alter table public.elsewhere detach partition public.elsewhere_p1 concurrently',
  'a command that is not one of the reversed table''s detaches stays armed');

select * from finish();
