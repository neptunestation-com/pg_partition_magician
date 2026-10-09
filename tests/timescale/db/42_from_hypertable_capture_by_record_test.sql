-- from_hypertable carried a stale change-capture trigger onto the migrated table (issue #842). The swap
-- replays the hypertable's triggers onto the copy (#787), leaving out this module's own capture trigger, and
-- it recognised that trigger by a name derived from the hypertable's CURRENT schema and relname. A tracking
-- copy that is never cut over (a state docs/guide.md names) leaves its trigger on the live hypertable, named
-- for the table as it was then; once the table was moved (ALTER TABLE ... SET SCHEMA) or renamed, a later
-- from_hypertable read that trigger as a user's, carried it onto the copy, and transmute cloned it onto the
-- parent and every partition, so every write to the migrated table went on appending to a delta nothing
-- drains. The capture is now recognised by the module's record, the horizon comment on its delta, which is
-- how pgpm_core/uninstall.sql finds an abandoned copy too (#737).
--
-- ASYMMETRIC FIXTURE. Two hypertables, each with an abandoned tracking copy AND a user trigger of its own
-- that must still be carried: z42 is moved to another schema, y42 is renamed (its key keeps the name y42_pkey,
-- so its migration also crosses the abandoned copy's y42_pkey_pgpm_new, #768). Each stale delta is given a
-- write AFTER the abandoned copy, so it holds a known key set before the migration ({50} and {60, 61}) and
-- the capture is shown to be live; after the migration one write to each table lands in the table and in the
-- user's audit (the carry worked) and in neither delta.
-- WITNESSES: the stale trigger is on each hypertable before, its delta carries the record, its capture is
-- live (it logged the pre-migration writes), and each migration completed with every row by id.
select plan(23);

create schema app42;
create table public.audit42 (tbl text not null, id bigint not null);
create function public.audit42_fn() returns trigger language plpgsql as $$
begin insert into public.audit42 values (tg_table_name, new.id); return new; end $$;

create table public.z42 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.z42', 'ts', chunk_time_interval => interval '1 day');
insert into public.z42 select g, now() - g * interval '3 hours', g from generate_series(1, 20) g;
create trigger z42_audit after insert on public.z42 for each row execute function public.audit42_fn();
create table public.y42 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.y42', 'ts', chunk_time_interval => interval '1 day');
insert into public.y42 select g, now() - g * interval '2 hours', g from generate_series(1, 12) g;
create trigger y42_audit after insert on public.y42 for each row execute function public.audit42_fn();

call pgpm.from_hypertable_copy('public.z42', 'ts', p_track_changes => true);   -- abandoned, never cut over
call pgpm.from_hypertable_copy('public.y42', 'ts', p_track_changes => true);   -- abandoned, never cut over
insert into public.z42 values (50, now() - interval '5 hours', 50);
insert into public.y42 values (60, now() - interval '5 hours', 60), (61, now() - interval '6 hours', 61);
-- #1083: a re-run of the copy (the migration below runs one) drops a capture pgpm.scratch records for the table,
-- wherever it lives, so the stale capture this file is about is one the record no longer names
-- (deleted here: no released version leaves a capture with the horizon comment and no record, so this is the
-- only way left to reach the carry's comment-record arm)
delete from pgpm.scratch where parent_oid in ('public.z42'::regclass, 'public.y42'::regclass);
alter table public.z42 set schema app42;
alter table public.y42 rename to y42r;
truncate public.audit42;

select is((select string_agg(t.tgname || ' -> ' || t.tgfoid::regprocedure::text, ', ' order by t.tgname)
             from pg_trigger t where t.tgrelid = 'app42.z42'::regclass and not t.tgisinternal
              and t.tgfoid::regprocedure::text not like '\_timescaledb%'),
          'z42_audit -> audit42_fn(), z42_pgpm_delta_trg -> z42_pgpm_delta_fn()',
          'LIVENESS: the moved app42.z42 carries the user''s trigger and the abandoned copy''s capture trigger');
select is((select string_agg(t.tgname || ' -> ' || t.tgfoid::regprocedure::text, ', ' order by t.tgname)
             from pg_trigger t where t.tgrelid = 'public.y42r'::regclass and not t.tgisinternal
              and t.tgfoid::regprocedure::text not like '\_timescaledb%'),
          'y42_audit -> audit42_fn(), y42_pgpm_delta_trg -> y42_pgpm_delta_fn()',
          'LIVENESS: the renamed public.y42r carries the user''s trigger and the abandoned copy''s capture trigger');
select ok(obj_description('public.z42_pgpm_delta'::regclass, 'pg_class') ~ '^pgpm from_hypertable horizon [0-9]+$'
          and obj_description('public.y42_pgpm_delta'::regclass, 'pg_class') ~ '^pgpm from_hypertable horizon [0-9]+$',
          'LIVENESS: both stale deltas carry the module''s record (the horizon comment)');
select is((select string_agg(id::text, ',' order by id) from public.z42_pgpm_delta), '50',
          'LIVENESS: z42''s stale capture is live: it logged the write made after its copy');
select is((select string_agg(id::text, ',' order by id) from public.y42_pgpm_delta), '60,61',
          'LIVENESS: y42''s stale capture is live: it logged the two writes made after its copy');

call pgpm.from_hypertable('app42.z42', 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable('public.y42r', 'ts', interval '1 day', p_paused => true);

select is((select relkind::text from pg_class where oid = 'app42.z42'::regclass), 'p',
          'LIVENESS: app42.z42 was migrated to a partitioned table');
select is((select relkind::text from pg_class where oid = 'public.y42r'::regclass), 'p',
          'LIVENESS: public.y42r was migrated to a partitioned table');
select is((select string_agg(id::text, ',' order by id) from app42.z42),
          (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g) || ',50',
          'LIVENESS: app42.z42 holds ids 1..20 and 50');
select is((select string_agg(id::text, ',' order by id) from public.y42r),
          (select string_agg(g::text, ',' order by g) from generate_series(1, 12) g) || ',60,61',
          'LIVENESS: public.y42r holds ids 1..12, 60 and 61');

-- the contract: no stale capture rides onto the parent or any partition
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgfoid = 'public.z42_pgpm_delta_fn()'::regprocedure and (c.relkind = 'p' or c.relispartition)),
          0, 'no partitioned table or partition fires z42''s abandoned capture trigger');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgfoid = 'public.y42_pgpm_delta_fn()'::regprocedure and (c.relkind = 'p' or c.relispartition)),
          0, 'no partitioned table or partition fires y42''s abandoned capture trigger');
select is((select string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t
            where t.tgrelid = 'app42.z42'::regclass and t.tgparentid = 0),
          'z42_audit', 'the migrated app42.z42''s own triggers are the user''s alone');
select is((select string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t
            where t.tgrelid = 'public.y42r'::regclass and t.tgparentid = 0),
          'y42_audit', 'the migrated public.y42r''s own triggers are the user''s alone');

insert into app42.z42 values (100, now() - interval '1 hour', 100);
insert into public.y42r values (200, now() - interval '1 hour', 200);
select is((select string_agg(tbl || ':' || id, ',' order by tbl, id) from public.audit42),
          (select string_agg(c.relname || ':' || r.id, ',' order by c.relname, r.id)
             from (select tableoid, id from app42.z42 where id = 100
                   union all select tableoid, id from public.y42r where id = 200) r
             join pg_class c on c.oid = r.tableoid),
          'LIVENESS: the carried user trigger fired for each write, on the partition that took it');
select is((select string_agg(id::text, ',' order by id) from app42.z42 where id >= 100), '100',
          'LIVENESS: the write to app42.z42 landed');
select is((select string_agg(id::text, ',' order by id) from public.y42r where id >= 100), '200',
          'LIVENESS: the write to public.y42r landed');
select is((select string_agg(id::text, ',' order by id) from public.z42_pgpm_delta), '50',
          'the write to the migrated app42.z42 is not logged into its abandoned delta');
select is((select string_agg(id::text, ',' order by id) from public.y42_pgpm_delta), '60,61',
          'the write to the migrated public.y42r is not logged into its abandoned delta');

-- and the capture of a copy that IS cut over is still left out as before (#787), by its record
create table public.w42 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.w42', 'ts', chunk_time_interval => interval '1 day');
insert into public.w42 select g, now() - g * interval '4 hours', g from generate_series(1, 6) g;
call pgpm.from_hypertable('public.w42', 'ts', interval '1 day', p_paused => true, p_track_changes => true);
select is((select relkind::text from pg_class where oid = 'public.w42'::regclass), 'p',
          'LIVENESS: a tracked migration of an unmoved table still completes');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname = 'w42_pgpm_delta_trg'), 0,
          'and leaves no capture trigger anywhere');

-- and so is the capture of a copy whose delta carries no comment record, by pgpm.scratch's record (#969; a
-- capture pgpm 0.6.0 minted, with no record of either kind, is tests/timescale/db/49 stage D's): carried, it
-- would be replayed after the cutover dropped its function
create table public.u42 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.u42', 'ts', chunk_time_interval => interval '1 day');
insert into public.u42 select g, now() - g * interval '4 hours', g from generate_series(1, 5) g;
call pgpm.from_hypertable_copy('public.u42', 'ts', p_track_changes => true);
comment on table public.u42_pgpm_delta is null;   -- the copy as an older release left it
select ok(obj_description('public.u42_pgpm_delta'::regclass, 'pg_class') is null
          and exists (select 1 from pg_trigger where tgrelid = 'public.u42'::regclass and tgname = 'u42_pgpm_delta_trg'),
          'LIVENESS: u42''s tracking copy has its capture trigger on the source and no record on its delta');
call pgpm.from_hypertable_cutover('public.u42', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.u42'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.u42), 'p/1,2,3,4,5',
          'an unrecorded tracking copy still cuts over: u42 is partitioned, holding ids 1..5');
select is((select count(*)::int from pg_trigger t where t.tgname = 'u42_pgpm_delta_trg'), 0,
          'and leaves no capture trigger anywhere');

select * from finish();
