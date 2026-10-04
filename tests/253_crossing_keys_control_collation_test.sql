-- retire()'s crossing step finds referencing keys under the CONTROL column's collation (issue #900, F4-07).
--
-- THE BUG. _crossing_keys found the rows referencing a retiring partition with a range predicate on the
-- REFERENCING column, `refcol >= lo and refcol < hi`, compared under that column's own collation. A
-- text_time grid's bounds order correctly only under the control column's collation (transmute insists on
-- one that separates the alphabet's digits, collate "C" for a mixed-case base62 KSUID, #456), and a
-- referencing column declared without COLLATE is ordinary DDL that carries the database default. Under
-- en_US letters compare case-insensitively first, so for a cell whose bounds' first differing digit runs
-- from an uppercase letter in lo to a lowercase one in hi, [lo, hi) is EMPTY: no crossing key was found,
-- the declared ON DELETE CASCADE ran on none of the referencing rows, and the dispatched detach was refused
-- by them on every run, a partition that could never retire.
--
-- THE CONTRACT. Whatever collation the referencing column carries, the crossing step identifies exactly
-- the keys in the doomed partition that some referencing row points at, so the declared ON DELETE runs on
-- exactly the referencing rows that point into it, and retain_crossing reports what it deleted.
--
-- The referencing column is declared collate "en_US.utf8" explicitly, so the file does not lean on the
-- database's default collation. pg_cron exists only in the `postgres` database on the harness images, so
-- this file brings a stand-in for cron.job and cron.alter_job, as tests/194 and 231 do. Nothing here runs
-- the armed command.
--
-- ASYMMETRIC FIXTURE. The doomed one-second cell holds three KSUIDs: k_up (the cell's lowest key, an
-- uppercase digit where the bounds differ) referenced TWICE, k_low (the cell's highest key, a lowercase
-- digit there) referenced once, and k_free (uppercase, unreferenced). A later cell holds k_kept,
-- referenced once. Exactly two doomed rows and exactly three referencing rows must go, so a step that
-- matched only one case, matched too much, or matched nothing cannot pass.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(10);

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

-- a KSUID with an EXPLICIT payload: 27 base62 digits, 32-bit seconds since 2014-05-13 16:53:20 over 128 bits
create function public.ks253(p_ts timestamptz, p_payload numeric) returns text language sql immutable as $$
  select pgpm._radix_encode(
    floor(extract(epoch from (p_ts - timestamptz '2014-05-13 16:53:20+00'))) * power(2::numeric, 128) + p_payload,
    62, 27, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')
$$;
create function public.ks253_bound(p_ts timestamptz) returns text language sql stable as $$
  select pgpm._ts_to_text_time(p_ts, '', 27, 62, 's',
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00')
$$;

create table public.ks253 (id text collate "C" primary key, body text);
insert into public.ks253 values (public.ks253(now(), 7), 'seed');
call pgpm.transmute('public.ks253', 'id', interval '1 second', p_obtain => 70, p_retain => interval '1 second',
  p_paused => true, p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
  p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00');

-- a future one-second cell, already built by obtain, whose bounds' first differing digit (the sixth: the
-- timestamp moves it about 7.7 places a second, so one second in eight or nine qualifies) runs from an
-- uppercase letter in lo to a lowercase one in hi
select pgpm._ts_text(c) as cell_at
  from (select date_trunc('second', clock_timestamp()) + make_interval(secs => s) as c from generate_series(3, 60) s) x
 where substr(public.ks253_bound(c), 6, 1) collate "C" between 'A' and 'Z'
   and substr(public.ks253_bound(c + interval '1 second'), 6, 1) collate "C" between 'a' and 'z'
   and substr(public.ks253_bound(c), 1, 5) = substr(public.ks253_bound(c + interval '1 second'), 1, 5)
 order by c limit 1 \gset

select public.ks253(:'cell_at'::timestamptz, 0) as k_up,
       public.ks253(:'cell_at'::timestamptz, 1000) as k_free,
       public.ks253(:'cell_at'::timestamptz, power(2::numeric, 128) - 1) as k_low,
       public.ks253(:'cell_at'::timestamptz + interval '20 seconds', 5) as k_kept \gset
insert into public.ks253 values (:'k_up', 'doomed, referenced twice'), (:'k_free', 'doomed, unreferenced'),
  (:'k_low', 'doomed, referenced once'), (:'k_kept', 'kept, referenced');

select child_name as doomed, lo as d_lo, hi as d_hi from pgpm.part
 where parent_table = 'public.ks253'::regclass and lo::timestamptz = :'cell_at'::timestamptz \gset

-- the referencing column carries a collation of its own, as any column declared without COLLATE in an
-- en_US database does
create table public.ks253_ref (id int primary key, k_id text collate "en_US.utf8" not null
  references public.ks253 (id) on delete cascade);
insert into public.ks253_ref values (1, :'k_up'), (2, :'k_up'), (3, :'k_low'), (4, :'k_kept');

-- wait until the cell has aged past the one-second horizon
select pg_sleep(greatest(0, extract(epoch from (:'cell_at'::timestamptz + interval '3 seconds' - clock_timestamp()))));

select is((select array_agg(body order by body) from public.ks253
            where tableoid = to_regclass(format('public.%I', :'doomed'))),
  array['doomed, referenced once', 'doomed, referenced twice', 'doomed, unreferenced'],
  'LIVENESS: the doomed one-second cell holds k_up, k_low and k_free, and k_kept is elsewhere');
select ok(substr(:'k_up', 6, 1) collate "C" between 'A' and 'Z' and substr(:'k_low', 6, 1) collate "C" between 'a' and 'z',
  'LIVENESS: k_up carries an uppercase digit where the bounds differ, k_low a lowercase one');
select ok((public.ks253_bound(:'d_lo'::timestamptz) collate "en_US.utf8") > (public.ks253_bound(:'d_hi'::timestamptz) collate "en_US.utf8"),
  'LIVENESS: under the referencing column''s collation the cell''s [lo, hi) is empty, the condition the defect needs');
select ok(not pgpm._native_gt('time', :'d_hi', (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.ks253'::regclass)),
  'LIVENESS: the doomed cell is wholly past the retention horizon');

select is(pgpm.retire('public.ks253', :'doomed'), false, 'LIVENESS: retire() takes the referenced path (dispatch, drop on a later call)');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.ks253 detach partition public.%I concurrently', :'doomed'),
  'LIVENESS: retire() reached the dispatch, so the crossing step ran before it');

-- the defect checks
select is((select array_agg(id order by id) from public.ks253_ref), array[4],
  'the declared ON DELETE CASCADE removed exactly refs 1, 2 and 3, which pointed into the doomed cell');
select is((select array_agg(body order by body) from public.ks253), array['doomed, unreferenced', 'kept, referenced', 'seed'],
  'the crossing DELETE removed exactly the two referenced doomed rows, of both cases');
select is((select array_agg(method) from pgpm.log where parent_table = 'public.ks253'::regclass and action = 'retain_crossing' and lo = :'d_lo'),
  array['2 referenced key(s), 2 row(s) deleted to honour the declared ON DELETE'],
  'retain_crossing, logged once, reports the two keys and the two rows it deleted');
select is((select array_agg(action) from pgpm.log where parent_table = 'public.ks253'::regclass and lo = :'d_lo'
            and action in ('fail_retain_crossing', 'fail_retain_identity', 'fail_retain_drop', 'fail_retain_detach')),
  null, 'the crossing step raised nothing');

select * from finish();
