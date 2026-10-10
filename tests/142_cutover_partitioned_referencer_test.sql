-- Issue #576: transmute(p_incoming_fks => 'preserve') of a table referenced from a PARTITIONED table could
-- never complete. The cutover's step 0c dropped every pg_constraint row with confrelid = the table, and a
-- foreign key declared on a partitioned table has one such row per partition as well (the per-partition
-- clones, conparentid <> 0). Dropping the top-level key removes its clones with it, so the next iteration
-- raised "constraint ... of relation <partition> does not exist", the cutover rolled back, and the table
-- was left carrying the write-rejecting pgpm_monolith_bound and a claim that every re-run failed on the
-- same way. The step-0 gate accepted the key and restore_incoming_fks re-adds a partitioned referencer's
-- key at the partitioned table, so this is a supported shape; only the cutover's selection was wrong.
-- 0c now drops and records the top-level keys only (conparentid = 0).
--
-- The fixture is asymmetric on purpose: ev142 is referenced by ONE key on a partitioned table with TWO
-- partitions (three pg_constraint rows) and by ONE key on a plain table (one row), so the records the
-- cutover leaves must be exactly the two top-level keys, named, and a selection that recorded clones, or
-- skipped the plain referencer, cannot produce the same set. Every post-conversion claim is paired with a
-- witness that the key it checks was really there to lose, and the restored key is proved by what it
-- refuses (an orphan into a partition of the referencer that the monolith does not cover) as well as by
-- what it accepts.
create extension if not exists pgtap;

select plan(12);

create table public.ev142 (id bigint primary key, body text);
insert into public.ev142 select g, 'row ' || g from generate_series(1, 15) g;
create table public.refp142 (id int, ev_id bigint references public.ev142(id), k int not null, primary key (id, k))
  partition by range (k);
create table public.refp142_a partition of public.refp142 for values from (0) to (10);
create table public.refp142_b partition of public.refp142 for values from (10) to (20);
insert into public.refp142 values (1, 3, 1), (2, 12, 15);
create table public.ref142 (id int primary key, ev_id bigint constraint ref142_ev_fk references public.ev142(id));
insert into public.ref142 values (1, 7);

-- ============================================== before: the keys the cutover has to drop and record
select is(
  (select array_agg(conrelid::regclass::text || ':' || conname || ':' || (conparentid = 0)::text
                    order by conrelid::regclass::text)
     from pg_constraint where confrelid = 'public.ev142'::regclass and contype = 'f'),
  array['ref142:ref142_ev_fk:true', 'refp142:refp142_ev_id_fkey:true',
        'refp142_a:refp142_ev_id_fkey:false', 'refp142_b:refp142_ev_id_fkey:false'],
  'LIVENESS: ev142 is referenced by a plain key and by a partitioned table''s key cloned onto both its partitions');

-- ============================================== transmute: the cutover completes
call pgpm.transmute('public.ev142', 'id', 10::bigint, p_incoming_fks => 'preserve', p_obtain => 2);

select is((select relkind::text from pg_class where oid = 'public.ev142'::regclass), 'p',
  'ev142 was converted to a partitioned table');
select ok(not exists (select 1 from pgpm.transmute_inflight
                       where parent_table in (select oid from pg_class where relname like 'ev142%')),
  'no conversion claim is left behind');
select ok(not exists (select 1 from pg_constraint c join pg_class r on r.oid = c.conrelid
                       where c.conname = 'pgpm_monolith_bound' and r.relname like 'ev142%'),
  'no write-rejecting pgpm_monolith_bound is left on any ev142 relation');

-- Which keys were recorded: the two top-level ones, by table and name, and no clone.
select is(
  (select array_agg(referencing_table::text || ':' || constraint_name order by referencing_table::text)
     from pgpm.dropped_fk where parent_table = 'public.ev142'::regclass),
  array['ref142:ref142_ev_fk', 'refp142:refp142_ev_id_fkey'],
  'the cutover recorded exactly the two top-level keys, not the partitioned referencer''s clones');
select is(
  (select array_agg(method order by method) from pgpm.log
    where parent_table = 'public.ev142'::regclass and action = 'drop_incoming_fk'),
  array['ref142_ev_fk', 'refp142_ev_id_fkey'],
  'the log names one drop_incoming_fk per top-level key');
select ok(not exists (select 1 from pg_constraint
                       where conrelid in ('public.refp142'::regclass, 'public.refp142_a'::regclass,
                                          'public.refp142_b'::regclass, 'public.ref142'::regclass)
                         and contype = 'f'),
  'the dropped keys are gone from every referencing relation, clones included, until the restore');

-- ============================================== restore: the partitioned key comes back whole
select is(pgpm.restore_incoming_fks('public.ev142'), 2, 'restore_incoming_fks re-adds both recorded keys');
select is(
  (select array_agg(conrelid::regclass::text || ':' || (conparentid = 0)::text || ':' || convalidated::text
                    order by conrelid::regclass::text)
     from pg_constraint where confrelid = 'public.ev142'::regclass and contype = 'f' and conname = 'refp142_ev_id_fkey'),
  case when current_setting('server_version_num')::int >= 180000
       then array['refp142:true:false', 'refp142_a:false:false', 'refp142_b:false:false']
       else array['refp142:true:true', 'refp142_a:false:true', 'refp142_b:false:true'] end,
  'the partitioned referencer''s key is back at refp142, with a clone on each partition: validated in one step before PostgreSQL 18, NOT VALID from 18 (#633)');

-- The monolith covers [1, 20); 25 lives in a forward partition, which is where a key left on the monolith
-- would stop enforcing. An orphan into refp142_b is refused, a real forward row is accepted.
insert into public.ev142 values (25, 'forward');
select throws_ok($$ insert into public.refp142 values (3, 999, 16) $$, '23503', NULL,
  'an orphan into refp142_b is refused by the restored key');
select lives_ok($$ insert into public.refp142 values (4, 25, 17) $$,
  'a row referencing a forward-partition ev142 row is accepted');
select is((select array_agg(ev_id order by id) from public.refp142), array[3::bigint, 12, 25],
  'refp142 holds exactly its two original rows and the accepted forward row');

select * from finish();
