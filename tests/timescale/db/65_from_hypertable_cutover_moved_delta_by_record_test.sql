-- The drains and the cutover find a tracking copy's delta by what pgpm.scratch RECORDS, wherever it lives now,
-- and the swap drops what is recorded (issue #1057 bullet 1, A1057-1 and F6-04).
--
-- The capture trigger writes the recorded delta by its oid (#1037), so a delta moved with ALTER TABLE ... SET
-- SCHEMA (or renamed) during the online window goes on taking every change. The drains and the cutover looked
-- it up through _from_hypertable_scratch, which answers only for a relation in the hypertable's own schema (a
-- rule that belongs to the copy, which the swap renames into the hypertable's place), so a moved delta read as
-- no delta at all: the drains refused ('found no delta'), and the cutover ran the append-only catch-up for a
-- tracking copy (its conservation check refusing whenever an update or delete had been captured) and, on a
-- clean swap, deleted every pgpm.scratch row of the hypertable while leaving the moved delta and the capture
-- function in place, nothing naming them any more. The swap also dropped the recorded capture function only
-- when it took the copy for a tracking one, so a delta dropped by hand left its function behind the records.
--
-- ASYMMETRIC FIXTURE. Two keyed hypertables in schema g65a, each with a TRACKING copy:
--   a65 (ids 1..5, v = id * 10): the recorded delta moved to g65side AND renamed log65, and an operator's own
--     table, of the delta's shape and holding one row (99), created under the freed name g65a.a65_pgpm_delta.
--     Three rounds of writes, each read from the moved delta by the drain step, the drain and the cutover:
--     W1 update id 2 (222) and delete id 3; W2 insert id 6 (60) and update id 4 (444); W3 update id 5 (555).
--     The cutover runs without its pre-drain, so W3 reaches the swap only through the under-lock reconcile.
--     It must hold 1=10,2=222,4=444,5=555,6=60.
--   b65 (ids 1..3): the recorded delta dropped by hand, nothing written since; the cutover runs append-only and
--     must still drop the recorded capture function.
-- Every recorded object is named by the oid recorded before anything moved, and asserted gone by that oid.
-- WITNESSES: before each drain and the cutover, the moved delta holds the keys the round wrote (so an empty
-- delta afterwards was the drain's work), and the recorded objects exist where the fixture put them.
select plan(17);

create schema g65a;
create schema g65side;

create table g65a.a65 (ts timestamptz not null, id int not null, v int, primary key (id, ts));
select create_hypertable('g65a.a65', 'ts', chunk_time_interval => interval '1 day');
insert into g65a.a65 select now() - g * interval '5 hours', g, g * 10 from generate_series(1, 5) g;
create table g65a.b65 (ts timestamptz not null, id int not null, v int, primary key (id, ts));
select create_hypertable('g65a.b65', 'ts', chunk_time_interval => interval '1 day');
insert into g65a.b65 select now() - g * interval '5 hours', g, g * 10 from generate_series(1, 3) g;

call pgpm.from_hypertable_copy('g65a.a65', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('g65a.b65', 'ts', p_track_changes => true);

-- the change capture each copy recorded (its delta and function), by oid, before anything moves; the copy
-- itself is left out, as the swap makes it the migrated table
create table pg_temp.rec65 as
  select c.relname::text as ht, s.kind, s.obj from pgpm.scratch s join pg_class c on c.oid = s.parent_oid
   where s.parent_oid in ('g65a.a65'::regclass, 'g65a.b65'::regclass)
     and s.kind in ('hypertable_delta', 'hypertable_delta_fn');

-- the recorded objects of one hypertable that still exist, as kind=schema.name, in kind order
create function pg_temp.alive65(p_ht text) returns text language sql as $$
  select string_agg(p.kind || '=' || coalesce(
           (select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where c.oid = p.obj),
           (select n.nspname || '.' || f.proname from pg_proc f join pg_namespace n on n.oid = f.pronamespace
             where f.oid = p.obj)), ',' order by p.kind)
    from pg_temp.rec65 p where p.ht = p_ht
     and (exists (select 1 from pg_class where oid = p.obj) or exists (select 1 from pg_proc where oid = p.obj))
$$;

-- the keys a65's recorded delta holds now, in capture order, read by its recorded oid
create function pg_temp.delta65() returns text language plpgsql as $$
declare v text;
begin
  execute format('select coalesce(string_agg(id::text, '','' order by pgpm_seq), '''') from %s',
                 (select obj::regclass from pg_temp.rec65 where ht = 'a65' and kind = 'hypertable_delta')) into v;
  return v;
end $$;

-- one drain step of a65, its return value, or the error it raised (so a refusal fails an assertion, not the file)
create function pg_temp.step65() returns text language plpgsql as $$
begin
  return pgpm.from_hypertable_drain_delta_step('g65a.a65', 'ts', 1000)::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

-- the moved, renamed delta, and an operator's table under the name it gave up
alter table g65a.a65_pgpm_delta set schema g65side;
alter table g65side.a65_pgpm_delta rename to log65;
create table g65a.a65_pgpm_delta (id int, ts timestamptz, pgpm_seq bigint generated always as identity);
insert into g65a.a65_pgpm_delta (id, ts) values (99, now());
-- b65's delta, dropped by hand (its capture now refuses every write, so nothing is written to b65)
drop table g65a.b65_pgpm_delta;

select is(pg_temp.alive65('a65'),
          'hypertable_delta=g65side.log65,hypertable_delta_fn=g65a.a65_pgpm_delta_fn',
          'LIVENESS: a65''s recorded delta sits in g65side as log65, its function beside the hypertable');
select is(pg_temp.alive65('b65'),
          'hypertable_delta_fn=g65a.b65_pgpm_delta_fn',
          'LIVENESS: b65''s recorded delta is gone and its capture function remains');

-- W1, then one drain step
update g65a.a65 set v = 222 where id = 2;
delete from g65a.a65 where id = 3;
select is(pg_temp.delta65(), '2,2,3', 'LIVENESS: W1 reached the moved delta (the capture follows it by oid)');
select is(pg_temp.step65(), '2',
          'the drain step reconciles the two keys W1 wrote into the moved delta');
select is(pg_temp.delta65() || ' | ' || (select string_agg(id::text || '=' || v::text, ',' order by id) from g65a.a65_pgpm_dest),
          ' | 1=10,2=222,4=40,5=50',
          'the step consumed the moved delta and applied W1 to the copy');

-- W2, then the drain
insert into g65a.a65 values (now() - interval '1 hour', 6, 60);
update g65a.a65 set v = 444 where id = 4;
select ok(pg_temp.delta65() like '%6,4,4', 'LIVENESS: W2 reached the moved delta');
call pgpm.from_hypertable_drain_delta('g65a.a65', 'ts');
select is(pg_temp.delta65() || ' | ' || (select string_agg(id::text || '=' || v::text, ',' order by id) from g65a.a65_pgpm_dest),
          ' | 1=10,2=222,4=444,5=50,6=60',
          'the drain consumed the moved delta and applied W2 to the copy');

-- W3, then the cutovers (a65's without its pre-drain, so the under-lock reconcile reads the moved delta)
update g65a.a65 set v = 555 where id = 5;
select ok(pg_temp.delta65() like '%5,5', 'LIVENESS: W3 reached the moved delta, for the cutover to read under its lock');
call pgpm.from_hypertable_cutover('g65a.a65', 'ts', interval '1 day', p_predrain => false);
call pgpm.from_hypertable_cutover('g65a.b65', 'ts', interval '1 day');

select is((select string_agg(c.oid::regclass::text || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in (to_regclass('g65a.a65'), to_regclass('g65a.b65'))),
          'g65a.a65:p,g65a.b65:p', 'both hypertables were cut over');
select is((select string_agg(id::text || '=' || v::text, ',' order by id) from g65a.a65),
          '1=10,2=222,4=444,5=555,6=60',
          'a65 holds every change the moved delta logged: W1 and W2 by the drains, W3 by the cutover''s reconcile');
select is((select string_agg(id::text || '=' || v::text, ',' order by id) from g65a.b65), '1=10,2=20,3=30',
          'b65 holds its rows');
select is(pg_temp.alive65('a65'), null,
          'the swap dropped a65''s moved delta and its capture function by their recorded oids');
select is(pg_temp.alive65('b65'), null,
          'the swap dropped b65''s capture function by its recorded oid, its delta already gone');
select is((select count(*)::int from pgpm.scratch where parent_oid in ('g65a.a65'::regclass, 'g65a.b65'::regclass)),
          0, 'and no scratch record is left');
select is((select string_agg(id::text, ',') from g65a.a65_pgpm_delta), '99',
          'the operator''s table under the delta''s minted name keeps its row: never read, emptied or dropped');
select is((select string_agg(c.relname::text, ',' order by c.relname) from pg_class c
            where c.relnamespace = 'g65side'::regnamespace and c.relkind in ('r', 'p')),
          null, 'g65side holds nothing the moved delta left');
select is((select string_agg(f.proname::text, ',' order by f.proname) from pg_proc f
            where f.pronamespace = 'g65a'::regnamespace and f.proname like '%pgpm_delta_fn'),
          null, 'g65a holds no capture function');

select * from finish();
