-- A re-run of from_hypertable_copy replaces the previous copy by what pgpm.scratch RECORDS, wherever it lives
-- now (issue #1083, F6-03 and F6-06).
--
-- The re-run used to replace the previous apparatus only while it sat under the names this copy mints, in the
-- hypertable's CURRENT schema. After ALTER TABLE <hypertable> SET SCHEMA the copy, the delta and the capture
-- function stay in the old schema and the capture trigger moves with the table under the same name, so the
-- cutover refuses ('found no copy ... run from_hypertable_copy first') and the remedy it names failed:
--   a tracking re-run died raw 42710 'trigger <rel>_pgpm_delta_trg already exists', because
--   _from_hypertable_scratch_check accepted that trigger (it fires the recorded function) and the replace
--   step, looking the function up in the NEW schema, dropped nothing (F6-03);
--   a re-run of either shape left the previous copy, a full second copy of the rows, in the old schema, and
--   then recorded the new copy over it, so pgpm had forgotten it (F6-06); a re-run without tracking also left
--   the old capture trigger on the hypertable, logging every write into a delta nothing recorded.
-- A RENAME of the hypertable left the previous apparatus the same way, under the table's old name.
--
-- ASYMMETRIC FIXTURE. Three hypertables, each with a TRACKING first copy, in schema g60a:
--   a60 (ids 1..5): SET SCHEMA g60b, a write (id 6), a TRACKING re-run, then two writes (id 2 deleted, id 7
--     inserted out of order, below the watermark) and the cutover: it must hold 1,3,4,5,6,7;
--   b60 (ids 1..4): SET SCHEMA g60c, a re-run WITHOUT tracking, an in-order append (id 5), the cutover: 1..5;
--   c60 (ids 1..3): RENAME to c60r, a TRACKING re-run, a delete of id 1, the cutover: 2,3.
-- The previous apparatus of each is named by the oids recorded before the move and asserted gone by those
-- oids; an operator's table in the old schema (g60a.keep60) is asserted untouched.
-- WITNESSES: before each re-run, the moved table carries the recorded capture trigger and every recorded
-- object exists, in the old schema (or under the old name), so "gone" afterwards was done by the re-run.
select plan(18);

create schema g60a;
create schema g60b;
create schema g60c;
create table g60a.keep60 (id int primary key);
insert into g60a.keep60 values (60);

create table g60a.a60 (ts timestamptz not null, id int not null, v int, primary key (id, ts));
select create_hypertable('g60a.a60', 'ts', chunk_time_interval => interval '1 day');
insert into g60a.a60 select now() - g * interval '5 hours', g, g * 10 from generate_series(1, 5) g;
create table g60a.b60 (ts timestamptz not null, id int not null, v int, primary key (id, ts));
select create_hypertable('g60a.b60', 'ts', chunk_time_interval => interval '1 day');
insert into g60a.b60 select now() - g * interval '5 hours', g, g * 10 from generate_series(1, 4) g;
create table g60a.c60 (ts timestamptz not null, id int not null, v int, primary key (id, ts));
select create_hypertable('g60a.c60', 'ts', chunk_time_interval => interval '1 day');
insert into g60a.c60 select now() - g * interval '5 hours', g, g * 10 from generate_series(1, 3) g;

call pgpm.from_hypertable_copy('g60a.a60', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('g60a.b60', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('g60a.c60', 'ts', p_track_changes => true);

-- every object each first copy recorded, by oid, before anything moves
create table pg_temp.prev60 as
  select c.relname::text as ht, s.kind, s.obj from pgpm.scratch s join pg_class c on c.oid = s.parent_oid
   where s.parent_oid in ('g60a.a60'::regclass, 'g60a.b60'::regclass, 'g60a.c60'::regclass);

-- the recorded objects of one hypertable that still exist, as kind=schema.name, in kind order
create function pg_temp.alive60(p_ht text) returns text language sql as $$
  select string_agg(p.kind || '=' || coalesce(
           (select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where c.oid = p.obj),
           (select n.nspname || '.' || f.proname from pg_proc f join pg_namespace n on n.oid = f.pronamespace
             where f.oid = p.obj)), ',' order by p.kind)
    from pg_temp.prev60 p where p.ht = p_ht
     and (exists (select 1 from pg_class where oid = p.obj) or exists (select 1 from pg_proc where oid = p.obj))
$$;

-- the user-visible triggers on a table, as name=function, the function schema-qualified
create function pg_temp.trg60(p_rel regclass) returns text language sql as $$
  select string_agg(t.tgname || '=' || n.nspname || '.' || f.proname, ',' order by t.tgname)
    from pg_trigger t join pg_proc f on f.oid = t.tgfoid join pg_namespace n on n.oid = f.pronamespace
   where t.tgrelid = p_rel and not t.tgisinternal and t.tgname <> 'ts_insert_blocker'
$$;

alter table g60a.a60 set schema g60b;
alter table g60a.b60 set schema g60c;
alter table g60a.c60 rename to c60r;
insert into g60b.a60 values (now() - interval '1 hour', 6, 60);

select is(pg_temp.alive60('a60') || ' | ' || pg_temp.trg60('g60b.a60'),
          'hypertable_delta=g60a.a60_pgpm_delta,hypertable_delta_fn=g60a.a60_pgpm_delta_fn,hypertable_dest=g60a.a60_pgpm_dest'
          || ' | a60_pgpm_delta_trg=g60a.a60_pgpm_delta_fn',
          'LIVENESS: a60, moved to g60b, carries the trigger the re-run mints by name, firing the recorded function left in g60a');
select is(pg_temp.alive60('b60') || ' | ' || pg_temp.trg60('g60c.b60'),
          'hypertable_delta=g60a.b60_pgpm_delta,hypertable_delta_fn=g60a.b60_pgpm_delta_fn,hypertable_dest=g60a.b60_pgpm_dest'
          || ' | b60_pgpm_delta_trg=g60a.b60_pgpm_delta_fn',
          'LIVENESS: b60, moved to g60c, carries the recorded capture, its copy and delta left in g60a');
select is(pg_temp.alive60('c60') || ' | ' || pg_temp.trg60('g60a.c60r'),
          'hypertable_delta=g60a.c60_pgpm_delta,hypertable_delta_fn=g60a.c60_pgpm_delta_fn,hypertable_dest=g60a.c60_pgpm_dest'
          || ' | c60_pgpm_delta_trg=g60a.c60_pgpm_delta_fn',
          'LIVENESS: c60, renamed to c60r, carries the recorded capture under its old name');
select is((select string_agg(id::text, ',' order by id) from g60a.a60_pgpm_delta), '6',
          'LIVENESS: the moved a60''s write reached the recorded delta in g60a');

-- the remedy the cutover names, in each shape
call pgpm.from_hypertable_copy('g60b.a60', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('g60c.b60', 'ts');
call pgpm.from_hypertable_copy('g60a.c60r', 'ts', p_track_changes => true);

select is(pg_temp.alive60('a60'), null, 'a60''s tracking re-run dropped the previous copy, delta and function, by their recorded oids');
select is(pg_temp.alive60('b60'), null, 'b60''s re-run without tracking dropped the previous copy, delta and function');
select is(pg_temp.alive60('c60'), null, 'c60r''s tracking re-run dropped the apparatus recorded under its old name');
select is(pg_temp.trg60('g60b.a60') || ' / ' || coalesce(pg_temp.trg60('g60c.b60'), 'none') || ' / ' || pg_temp.trg60('g60a.c60r'),
          'a60_pgpm_delta_trg=g60b.a60_pgpm_delta_fn / none / c60r_pgpm_delta_trg=g60a.c60r_pgpm_delta_fn',
          'each hypertable carries only the capture its re-run made, and the re-run without tracking none');
select is((select string_agg(c.relname::text || ':' || s.kind || '=' || coalesce(
                    (select n.nspname || '.' || r.relname from pg_class r join pg_namespace n on n.oid = r.relnamespace where r.oid = s.obj),
                    (select n.nspname || '.' || f.proname from pg_proc f join pg_namespace n on n.oid = f.pronamespace where f.oid = s.obj)),
                    ',' order by c.relname, s.kind)
             from pgpm.scratch s join pg_class c on c.oid = s.parent_oid
            where s.parent_oid in ('g60b.a60'::regclass, 'g60c.b60'::regclass, 'g60a.c60r'::regclass)),
          'a60:hypertable_delta=g60b.a60_pgpm_delta,a60:hypertable_delta_fn=g60b.a60_pgpm_delta_fn,a60:hypertable_dest=g60b.a60_pgpm_dest,'
          || 'b60:hypertable_dest=g60c.b60_pgpm_dest,'
          || 'c60r:hypertable_delta=g60a.c60r_pgpm_delta,c60r:hypertable_delta_fn=g60a.c60r_pgpm_delta_fn,c60r:hypertable_dest=g60a.c60r_pgpm_dest',
          'pgpm.scratch records exactly what each re-run made, beside the hypertable');
select is((select string_agg(c.relname::text, ',' order by c.relname) from pg_class c
            where c.relnamespace = 'g60a'::regnamespace and c.relkind in ('r', 'p')),
          'c60r,c60r_pgpm_delta,c60r_pgpm_dest,keep60',
          'g60a holds the renamed c60r''s new apparatus and the operator''s keep60, and nothing the moved tables left');
select is((select string_agg(id::text, ',' order by id) from g60a.keep60), '60', 'and the operator''s keep60 keeps its row');
select is((select string_agg(id::text, ',' order by id) from g60b.a60_pgpm_dest), '1,2,3,4,5,6',
          'a60''s new copy holds every row, the write made after the move included');

-- the window after the re-run, then the cutovers
delete from g60b.a60 where id = 2;
insert into g60b.a60 values (now() - interval '30 hours', 7, 70);
insert into g60c.b60 values (now(), 5, 50);
delete from g60a.c60r where id = 1;
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from g60b.a60_pgpm_delta), '2,7',
          'LIVENESS: a60''s writes after the re-run reached the delta it recorded');

call pgpm.from_hypertable_cutover('g60b.a60', 'ts', interval '1 day');
call pgpm.from_hypertable_cutover('g60c.b60', 'ts', interval '1 day');
call pgpm.from_hypertable_cutover('g60a.c60r', 'ts', interval '1 day');

select is((select string_agg(c.oid::regclass::text || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in (to_regclass('g60b.a60'), to_regclass('g60c.b60'), to_regclass('g60a.c60r'))),
          'g60b.a60:p,g60c.b60:p,g60a.c60r:p', 'each hypertable was cut over, in its own schema');
select is((select string_agg(id::text || '=' || v::text, ',' order by id) from g60b.a60), '1=10,3=30,4=40,5=50,6=60,7=70',
          'a60 holds its rows: the write made after the move in, the late delete out and the late insert in');
select is((select string_agg(id::text || '=' || v::text, ',' order by id) from g60c.b60), '1=10,2=20,3=30,4=40,5=50',
          'b60 holds its rows and the append made after the re-run');
select is((select string_agg(id::text || '=' || v::text, ',' order by id) from g60a.c60r), '2=20,3=30',
          'c60r holds its rows, the delete made after the re-run applied');
select is((select count(*)::int from pgpm.scratch
            where parent_oid in ('g60b.a60'::regclass, 'g60c.b60'::regclass, 'g60a.c60r'::regclass)),
          0, 'and the cutovers left no scratch record behind');

select * from finish();
