-- retire()'s crossing step reads a timestamptz referencing key back through _ts_text (issue #814, F4-01).
--
-- THE BUG. _crossing_keys rendered the referencing FK column with a bare ::text, and retire()'s crossing
-- DELETE parses those values back as %L::text[]::<control type>[] in the same session, the #788 class.
-- Under a DateStyle that renders zone abbreviations (SQL, Postgres) the render does not round-trip:
-- Asia/Kolkata renders 'IST', which PostgreSQL before 18 parses as Israel (+02). The DELETE then matched
-- nothing, the FK's declared ON DELETE CASCADE was never applied, retain_crossing logged '0 row(s)
-- deleted', and the dispatched DETACH CONCURRENTLY could never succeed, so the partition never retired.
--
-- THE CONTRACT. Whatever the session's DateStyle and TimeZone, the crossing DELETE removes exactly the
-- doomed rows a referencing key points at, so the declared ON DELETE runs on exactly the referencing rows
-- that point into the doomed partition, and retain_crossing reports what it deleted.
--
-- On PostgreSQL 18 an abbreviation is resolved in the session's own zone first, so the bare render happens
-- to round-trip there; the file passes on every version and catches the defect on 15 to 17.
--
-- pg_cron exists only in the `postgres` database on the harness images, so this file brings a stand-in for
-- cron.job and cron.alter_job, as tests/194 and 204 do. Nothing here runs the armed command.
--
-- ASYMMETRIC FIXTURE. The doomed partition holds two rows (id 10, referenced by ref 100 ON DELETE CASCADE,
-- and id 11, unreferenced); a kept partition holds id 20, referenced by ref 200. Exactly one doomed row and
-- exactly one referencing row must go, so a DELETE that matched too much or too little cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(9);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

-- a 1-second grid, so the monolith ages out within the file: its hi is the end of transmute's own second
create table public.ck231 (id bigint, created_at timestamptz, payload text, primary key (id, created_at));
insert into public.ck231 values
  (1,  now() - interval '0.75 seconds', 'seed'),
  (10, now() - interval '0.5 seconds',  'doomed, referenced'),
  (11, now() - interval '0.25 seconds', 'doomed, unreferenced');
call pgpm.transmute('public.ck231', 'created_at', '1 second'::interval, p_obtain => 30,
                    p_retain => '1 second'::interval, p_paused => false);

select child_name as doomed, lo as d_lo, hi as d_hi from pgpm.part
 where parent_table = 'public.ck231'::regclass and pgpm._native_gt('time', hi, (select max(created_at)::text from public.ck231))
   and not pgpm._native_gt('time', lo, (select min(created_at)::text from public.ck231)) \gset

insert into public.ck231 values (20, :'d_hi'::timestamptz + interval '20.5 seconds', 'kept, referenced');
create table public.ck231_ref (id bigint primary key, ck_id bigint, ck_at timestamptz,
  foreign key (ck_id, ck_at) references public.ck231 (id, created_at) on delete cascade);
insert into public.ck231_ref
  select 100, id, created_at from public.ck231 where id = 10
  union all
  select 200, id, created_at from public.ck231 where id = 20;

select pg_sleep(2.2);   -- the doomed partition's hi is now at least a second behind the clock

-- the session a tick may run in: a zone whose abbreviation is ambiguous, and an abbreviating DateStyle
set timezone = 'Asia/Kolkata';
set datestyle = 'SQL, MDY';

select ok(not pgpm._native_gt('time', :'d_hi', (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.ck231'::regclass)),
  'LIVENESS: the doomed partition is wholly past the retention horizon');
select is((select array_agg(id order by id) from public.ck231 where created_at >= :'d_lo'::timestamptz and created_at < :'d_hi'::timestamptz),
  array[1, 10, 11]::bigint[], 'LIVENESS: the doomed partition holds ids 1, 10 and 11, and id 20 is elsewhere');
select ok((select array_length(pgpm._crossing_keys('public.ck231', :'d_lo', :'d_hi'), 1)) = 1,
  'LIVENESS: exactly one referencing key crosses the doomed partition');

select is(pgpm.retire('public.ck231', :'doomed'), false, 'LIVENESS: retire() takes the referenced path (dispatch, drop on a later call)');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.ck231 detach partition public.%I concurrently', :'doomed'),
  'LIVENESS: retire() reached the dispatch, so the crossing step ran before it');

-- the defect checks
select is((select array_agg(id order by id) from public.ck231_ref), array[200]::bigint[],
  'the declared ON DELETE CASCADE removed exactly ref 100, which pointed into the doomed partition');
select is((select array_agg(id order by id) from public.ck231), array[1, 11, 20]::bigint[],
  'the crossing DELETE removed exactly the referenced doomed row (id 10)');
select is((select array_agg(method) from pgpm.log where parent_table = 'public.ck231'::regclass and action = 'retain_crossing' and lo = :'d_lo'),
  array['1 referenced key(s), 1 row(s) deleted to honour the declared ON DELETE'],
  'retain_crossing, logged once, reports the one row it deleted');
select is((select array_agg(action) from pgpm.log where parent_table = 'public.ck231'::regclass and lo = :'d_lo'
            and action in ('fail_retain_crossing', 'fail_retain_identity', 'fail_retain_drop', 'fail_retain_detach')),
  null, 'the crossing step raised nothing');

select * from finish();
