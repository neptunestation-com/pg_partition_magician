-- from_hypertable and from_hypertable_cutover ask the grid's mixed-step rule before anything is changed (issue
-- #1268), and the column-unit refusals they raise name the call to re-run, not transmute's (issue #1232).
--
-- #1268. transmute refuses a p_interval that mixes a month count with a duration ('1 mon 1 day', '1 year 2
-- hours', '1 mon -40 days'): pgpm._grid_floor raises 'mixed month + duration interval unsupported' when it
-- first places a bound. Its preflight does not ask that rule, and neither did the module's
-- _from_hypertable_check_arguments, which asks only _refuse_bad_transmute_arguments (it reads the step as
-- positive: a whole month first) and _time_unit_contract. So both entry points copied, the cutover's swap
-- committed, the hypertable and its incoming foreign key were dropped, and only the handoff refused, leaving
-- a plain table pgpm does not manage. '1 mon -40 days' met the frontier check first instead, whose limit
-- (now() + step + 1 hour) then lay in the past, with a remedy that deleted the newest rows.
--
-- #1232. _time_unit_contract's two off-unit refusals (a date key's anchor off 00:00 UTC, #769; a step or an
-- anchor finer than a timestamp(p) key keeps, #1039), asked by the module before its copy and its swap,
-- carried transmute's remedy: "then re-run transmute; ... call pgpm.transmute_abort(<table>) first". Raised
-- there the table is still a hypertable, which transmute refuses, and nothing left a bound to abort.
--
-- WHAT THE HARNESS ALLOWS. Every refused call is a committing procedure. Wrapped by throws_like, or by the
-- capturing pg_temp.err below, one that wrongly does NOT refuse dies at its first COMMIT inside that function
-- context with 2D000 (the copy's, or with p_predrain => false the swap's) and rolls back into the state a
-- refusal leaves. So the pinned messages, anchored at the start, are the discriminating assertions; the state
-- checks after them are invariants, marked so. Each remedy check that says what a message does NOT name is
-- paired with one that pins what it does, so a 2D000 cannot satisfy it.
--
-- ASYMMETRIC FIXTURES. a69 (keyed, ids 1, 2, 3, id 2 referenced by a69_ref) goes through the one-shot driver
-- and b69 (keyed, ids 7 and 8, id 8 referenced by b69_ref) through the two phases, for #1268; d69 (a date
-- key, 4, 5, 6) and t69 (a timestamptz(0) key, 10 and 20) through the driver and e69 (a date key, 31 to 34)
-- through the two phases, for #1232, and u69 (a timestamptz(0) key, 41 to 43) through the two phases with its
-- column widened as the timestamp(p) remedy offers. WITNESSES: transmute refuses the mixed step on a plain table, and
-- refuses the noon anchor on a plain date table with its own remedy, so the rules asked are transmute's and
-- only the remedy is the caller's; the frontier check, asked of '1 mon -40 days', would refuse a69 with the
-- delete-the-rows remedy. Then each remedy is TYPED as the message gives it, and each table migrates.
select plan(30);

create table public.a69 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.a69', 'ts', chunk_time_interval => interval '1 day');
insert into public.a69 select g, now() - g * interval '20 hours', g * 10 from generate_series(1, 3) g;
create table public.a69_ref (rid int primary key, h_id bigint, h_ts timestamptz,
  constraint a69_ref_fk foreign key (h_id, h_ts) references public.a69 (id, ts));
insert into public.a69_ref select 1, id, ts from public.a69 where id = 2;
create table public.b69 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.b69', 'ts', chunk_time_interval => interval '1 day');
insert into public.b69 values (7, now() - interval '3 days', 70), (8, now() - interval '2 hours', 80);
create table public.b69_ref (rid int primary key, h_id bigint, h_ts timestamptz,
  constraint b69_ref_fk foreign key (h_id, h_ts) references public.b69 (id, ts));
insert into public.b69_ref select 5, id, ts from public.b69 where id = 8;
create table public.d69 (d date not null, v int);
select create_hypertable('public.d69', 'd', chunk_time_interval => interval '7 days');
insert into public.d69 values (current_date - 9, 4), (current_date - 5, 5), (current_date - 1, 6);
create table public.t69 (ts timestamptz(0) not null, v int);
select create_hypertable('public.t69', 'ts', chunk_time_interval => interval '1 day');
insert into public.t69 values (now() - interval '30 hours', 10), (now() - interval '2 hours', 20);
create table public.e69 (d date not null, v int);
select create_hypertable('public.e69', 'd', chunk_time_interval => interval '7 days');
insert into public.e69 values (current_date - 40, 31), (current_date - 20, 32), (current_date - 10, 33),
                              (current_date - 2, 34);
create table public.u69 (ts timestamptz(0) not null, v int);
select create_hypertable('public.u69', 'ts', chunk_time_interval => interval '1 day');
insert into public.u69 select date_trunc('second', now() - g * interval '20 hours'), 40 + g from generate_series(1, 3) g;
-- each hypertable's own oid, the key of its pgpm.scratch records, taken while the names are still its own (#1283)
create table pg_temp.ht69 as
  select c.relname::text as ht, c.oid from pg_class c
   where c.oid in ('public.a69'::regclass, 'public.b69'::regclass, 'public.d69'::regclass,
                   'public.t69'::regclass, 'public.e69'::regclass, 'public.u69'::regclass);
create table public.p69 (ts timestamptz not null, v int);
insert into public.p69 values (now() - interval '1 hour', 1);
create table public.p69d (d date not null, v int);
insert into public.p69d values (current_date - 1, 1);

-- the message of a refused statement, or 'ok'; a committing procedure that does not refuse returns the 2D000's
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm; end $$;

-- ================================ the rules are transmute's ================================
select throws_like(
  $$ call pgpm.transmute('public.p69', 'ts', interval '1 mon 1 day') $$,
  'pg_partition_magician: mixed month + duration interval unsupported (1 mon 1 day)',
  'LIVENESS: transmute refuses a step that mixes a month count with a duration on a plain table');
select throws_like(
  $$ select pgpm._from_hypertable_check_frontier('public.a69', 'ts', interval '1 mon -40 days', false) $$,
  'pg_partition_magician: cannot migrate hypertable a69 with p_interval 1 mon -40 days -- %Delete or correct the rows whose ts is after %',
  'LIVENESS: asked of ''1 mon -40 days'', the frontier check would refuse a69 telling the operator to delete rows');
select alike(pg_temp.err($$ call pgpm.transmute('public.p69d', 'd', interval '1 day', p_anchor => '2000-01-01 12:00:00+00') $$),
  'pg_partition_magician: cannot partition p69d on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 12:00:00 UTC%then re-run transmute; if an earlier attempt left a pgpm_monolith_bound CHECK on the table, call pgpm.transmute_abort(p69d) first, since a re-run resumes its recorded bound.',
  'LIVENESS: transmute refuses a noon anchor on a plain date table, and its own refusal keeps transmute''s remedy');

-- ================================ #1268 A: the one-shot driver, before its copy ================================
select throws_like(
  $$ call pgpm.from_hypertable('public.a69', 'ts', interval '1 mon 1 day') $$,
  'pg_partition_magician: cannot migrate hypertable a69 with p_interval 1 mon 1 day -- refused before anything is changed, %(mixed month + duration interval unsupported). Give a whole number of months or a pure duration, then re-run pgpm.from_hypertable %',
  'from_hypertable refuses ''1 mon 1 day'' before its copy (#1268)');
select throws_like(
  $$ call pgpm.from_hypertable('public.a69', 'ts', interval '1 year 2 hours') $$,
  'pg_partition_magician: cannot migrate hypertable a69 with p_interval 1 year 02:00:00 -- refused before anything is changed, %(mixed month + duration interval unsupported)%',
  'from_hypertable refuses a year mixed with hours before its copy');
select throws_like(
  $$ call pgpm.from_hypertable('public.a69', 'ts', interval '1 mon -40 days') $$,
  'pg_partition_magician: cannot migrate hypertable a69 with p_interval 1 mon -40 days -- refused before anything is changed, %(mixed month + duration interval unsupported)%',
  'from_hypertable refuses ''1 mon -40 days'' as a mixed step, not as a frontier with rows to delete');
select throws_like(
  $$ call pgpm.from_hypertable('public.a69', 'ts', interval '1 mon -40 days', p_force_frontier => true) $$,
  'pg_partition_magician: cannot migrate hypertable a69 with p_interval 1 mon -40 days -- refused before anything is changed, %(mixed month + duration interval unsupported)%',
  'from_hypertable refuses ''1 mon -40 days'' with p_force_frontier too');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'a69')
  || '/' || (select count(*) from pg_constraint where conname = 'a69_ref_fk' and confrelid = 'public.a69'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'a69')
  || '/' || (select count(*) from pgpm.scratch where parent_oid = 'public.a69'::regclass::oid)
  || '/' || (select string_agg(id::text, ',' order by id) from public.a69),
  '1/1/0/0/1,2,3', 'invariant: a69 is still a hypertable, its incoming key in place, unregistered, no copy recorded, holding 1,2,3');

-- ================================ #1268 B: the cutover, before its pre-drain and its swap ================================
call pgpm.from_hypertable_copy('public.b69', 'ts');
select is(
  (select string_agg(id::text, ',' order by id) from public.b69_pgpm_dest)
  || '/' || (pgpm._from_hypertable_scratch('public.b69', 'hypertable_dest') is not null)::text,
  '7,8/true', 'LIVENESS: the copy of b69 ran, holds 7,8 and is recorded');
-- p_predrain => false, so nothing commits ahead of the swap for an unrelated reason: a cutover that does not
-- refuse dies on the swap's COMMIT inside throws_like, which its pinned message tells apart.
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b69', 'ts', interval '1 mon 1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable b69 with p_interval 1 mon 1 day -- refused before anything is changed, %(mixed month + duration interval unsupported)%',
  'from_hypertable_cutover refuses ''1 mon 1 day'' before its swap (#1268)');
-- the pre-drain is the cutover's first COMMIT: the refusal comes before it too
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.b69', 'ts', interval '1 mon 1 day') $$,
  'pg_partition_magician: cannot migrate hypertable b69 with p_interval 1 mon 1 day -- refused before anything is changed, %(mixed month + duration interval unsupported)%',
  'from_hypertable_cutover refuses ''1 mon 1 day'' before its pre-drain');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name = 'b69')
  || '/' || (select count(*) from pg_constraint where conname = 'b69_ref_fk' and confrelid = 'public.b69'::regclass)
  || '/' || (select count(*) from pgpm.config where parent_table::text = 'b69')
  || '/' || (select string_agg(id::text, ',' order by id) from public.b69)
  || '/' || (select string_agg(id::text, ',' order by id) from public.b69_pgpm_dest),
  '1/1/0/7,8/7,8', 'invariant: b69 is still a hypertable, its incoming key in place, unregistered, holding 7,8, its copy in place');

-- ================================ #1232: the column-unit refusals name the call to re-run ================================
call pgpm.from_hypertable_copy('public.e69', 'd');
select is((select string_agg(v::text, ',' order by v) from public.e69_pgpm_dest), '31,32,33,34',
  'LIVENESS: the copy of e69 ran and holds 31,32,33,34');
create temp table msg69 (k text primary key, m text);
insert into msg69 values
  ('d', pg_temp.err($$ call pgpm.from_hypertable('public.d69', 'd', interval '1 day', p_anchor => '2000-01-01 12:00:00+00') $$)),
  ('t', pg_temp.err($$ call pgpm.from_hypertable('public.t69', 'ts', interval '500 milliseconds') $$)),
  ('e', pg_temp.err($$ call pgpm.from_hypertable_cutover('public.e69', 'd', interval '1 day', p_anchor => '2000-01-01 05:00:00+00', p_predrain => false) $$));
select alike((select m from msg69 where k = 'd'),
  'pg_partition_magician: cannot partition d69 on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 12:00:00 UTC%then re-run pgpm.from_hypertable, or on the two-phase path pgpm.from_hypertable_cutover, re-running pgpm.from_hypertable_copy before it if the column''s type was changed (the copy keeps the type it was made with, and the cutover refuses a copy whose shape is not the hypertable''s): this call was refused before anything was changed, so the table is still a hypertable, which transmute does not take, and no transmute bound was left to abort.',
  'from_hypertable''s date-anchor refusal names from_hypertable as the call to re-run (#1232)');
select alike((select m from msg69 where k = 't'),
  'pg_partition_magician: cannot partition t69 on ts with step 00:00:00.5 and anchor % -- the column is timestamp(0) with time zone, which keeps whole seconds only%or widen the column''s precision (ALTER TABLE t69 ALTER COLUMN ts TYPE timestamp with time zone), then re-run pgpm.from_hypertable, or on the two-phase path pgpm.from_hypertable_cutover, re-running pgpm.from_hypertable_copy before it if the column''s type was changed (the copy keeps the type it was made with, and the cutover refuses a copy whose shape is not the hypertable''s): this call was refused before anything was changed%',
  'from_hypertable''s timestamp(0) refusal names from_hypertable as the call to re-run (#1232)');
select alike((select m from msg69 where k = 'e'),
  'pg_partition_magician: cannot partition e69 on d with step 1 day and anchor % -- the column is a date, %this anchor falls at 05:00:00 UTC%then re-run pgpm.from_hypertable, or on the two-phase path pgpm.from_hypertable_cutover, re-running pgpm.from_hypertable_copy before it if the column''s type was changed (the copy keeps the type it was made with, and the cutover refuses a copy whose shape is not the hypertable''s)%',
  'from_hypertable_cutover''s date-anchor refusal names the cutover as the call to re-run (#1232)');
select is((select string_agg(k, ',' order by k) from msg69 where m like '%transmute_abort%' or m like '%re-run transmute%'), null,
  'none of the three tells the operator to re-run transmute or to call pgpm.transmute_abort on a hypertable');
select is(
  (select count(*) from timescaledb_information.hypertables where hypertable_name in ('d69', 't69', 'e69'))
  || '/' || (select count(*) from pgpm.config where parent_table::text in ('d69', 't69', 'e69'))
  || '/' || (select string_agg(v::text, ',' order by v) from public.d69)
  || '/' || (select string_agg(v::text, ',' order by v) from public.t69)
  || '/' || (select string_agg(v::text, ',' order by v) from public.e69),
  '3/0/4,5,6/10,20/31,32,33,34', 'invariant: d69, t69 and e69 are still hypertables, unregistered, holding their rows');
-- the remedy the old message named, typed: transmute refuses the hypertable outright
select alike(pg_temp.err($$ call pgpm.transmute('public.d69', 'd', interval '1 day') $$),
  'pg_partition_magician: d69 has inheritance children%',
  'LIVENESS: transmute on the hypertable, the re-run the old remedy named, is refused');

-- ================================ the remedies, typed as the messages give them ================================
-- #1268: "a whole number of months or a pure duration, then re-run pgpm.from_hypertable (or the cutover)"
call pgpm.from_hypertable('public.a69', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select is(
  (select relkind::text from pg_class where oid = 'public.a69'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.a69'::regclass)
  || '/' || (select count(*) from pg_constraint where conname = 'a69_ref_fk' and confrelid = 'public.a69'::regclass)
  || '/' || (select string_agg(id::text, ',' order by id) from public.a69),
  'p/1 mon/1/1,2,3', 'from_hypertable re-run with a whole-month step migrates a69: registered, its key back, every row');
call pgpm.from_hypertable_cutover('public.b69', 'ts', interval '1 day', p_obtain => 2, p_paused => true);
select is(
  (select relkind::text from pg_class where oid = 'public.b69'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.b69'::regclass)
  || '/' || (select count(*) from pg_constraint where conname = 'b69_ref_fk' and confrelid = 'public.b69'::regclass)
  || '/' || (select string_agg(id::text, ',' order by id) from public.b69),
  'p/1 day/1/7,8', 'the cutover re-run with a pure-duration step migrates b69: registered, its key back, every row');
-- #1232 date: "an anchor at 00:00 UTC ... then re-run pgpm.from_hypertable (or the cutover)"
call pgpm.from_hypertable('public.d69', 'd', interval '1 day', p_anchor => '2000-01-01 00:00:00+00', p_obtain => 2);
select is(
  (select relkind::text from pg_class where oid = 'public.d69'::regclass)
  || '/' || (select extract(epoch from partition_anchor::timestamptz)::bigint::text from pgpm.config where parent_table = 'public.d69'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.d69),
  'p/946684800/4,5,6', 'from_hypertable re-run with the anchor at 00:00 UTC migrates d69, every row');
call pgpm.from_hypertable_cutover('public.e69', 'd', interval '1 day', p_anchor => '2000-01-01 00:00:00+00', p_obtain => 2);
select is(
  (select relkind::text from pg_class where oid = 'public.e69'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.e69'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.e69),
  'p/1 day/31,32,33,34', 'the cutover re-run with the anchor at 00:00 UTC migrates e69, every row');
-- #1232 timestamp(0), the two-phase path (PR #1302 round 1, P1-02): "or widen the column's precision (ALTER TABLE
-- ...), then re-run ... on the two-phase path pgpm.from_hypertable_cutover, re-running pgpm.from_hypertable_copy
-- before it if the column's type was changed". u69 (41, 42, 43) is copied before the refusal, so its copy keeps
-- timestamptz(0); the cutover alone after the ALTER is refused by the shape check, the re-copy then the cutover is
-- the whole repair.
call pgpm.from_hypertable_copy('public.u69', 'ts');
select alike(pg_temp.err($$ call pgpm.from_hypertable_cutover('public.u69', 'ts', interval '500 milliseconds', p_predrain => false) $$),
  'pg_partition_magician: cannot partition u69 on ts with step 00:00:00.5 and anchor % -- the column is timestamp(0) with time zone, which keeps whole seconds only%or widen the column''s precision (ALTER TABLE u69 ALTER COLUMN ts TYPE timestamp with time zone), then re-run pgpm.from_hypertable, or on the two-phase path pgpm.from_hypertable_cutover, re-running pgpm.from_hypertable_copy before it if the column''s type was changed%',
  'the cutover''s timestamp(0) refusal names the re-copy a widened column needs before the cutover is re-run (#1232)');
alter table public.u69 alter column ts type timestamp with time zone;
select alike(pg_temp.err($$ call pgpm.from_hypertable_cutover('public.u69', 'ts', interval '500 milliseconds', p_predrain => false) $$),
  'pg_partition_magician: from_hypertable_cutover(u69) refusing to swap: the copy % no longer has the source''s shape: %',
  'LIVENESS: after the ALTER, the cutover alone (no re-copy) is refused by the shape check: the re-copy is needed');
call pgpm.from_hypertable_copy('public.u69', 'ts');
call pgpm.from_hypertable_cutover('public.u69', 'ts', interval '500 milliseconds', p_obtain => 2);
select is(
  (select relkind::text from pg_class where oid = 'public.u69'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.u69'::regclass)
  || '/' || (select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.u69'::regclass and attname = 'ts')
  || '/' || (select string_agg(v::text, ',' order by v) from public.u69),
  'p/00:00:00.5/timestamp with time zone/41,42,43',
  'the two-phase remedy as typed (ALTER, re-copy, cutover with the same step) migrates u69, every row');
-- #1232 timestamp(0): "or widen the column's precision (ALTER TABLE ...), then re-run pgpm.from_hypertable"
alter table public.t69 alter column ts type timestamp with time zone;
call pgpm.from_hypertable('public.t69', 'ts', interval '500 milliseconds', p_obtain => 2);
select is(
  (select relkind::text from pg_class where oid = 'public.t69'::regclass)
  || '/' || (select partition_step::text from pgpm.config where parent_table = 'public.t69'::regclass)
  || '/' || (select string_agg(v::text, ',' order by v) from public.t69),
  'p/00:00:00.5/10,20', 'with the column widened as the message says, from_hypertable re-run with the same step migrates t69');
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name in ('a69', 'b69', 'd69', 't69', 'e69', 'u69')), 0,
  'none of the six is a hypertable any more');
-- by the hypertables' oids: the swap gives their names to the migrated tables, which no record names
select is((select string_agg(h.ht || ':' || s.kind, ',' order by h.ht, s.kind)
             from pgpm.scratch s join pg_temp.ht69 h on h.oid = s.parent_oid), null,
  'and no scratch record is left for any, under the hypertables'' oids taken at the start');
select is((select count(*)::int from pgpm.handoff), 0,
  'and no handoff was left behind by a refused one');

select * from finish();
