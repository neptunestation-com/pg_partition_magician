-- from_hypertable carried a pgpm 0.6.0 change capture onto the migrated table once the hypertable had been
-- renamed or moved (issue #988). The swap replays the hypertable's triggers onto the copy (#787), leaving out
-- this module's own capture. A capture 0.6.0 minted carries neither record (no pgpm.scratch row, no horizon
-- comment on its delta), so it is recognised by proof (#969): a function <x>_pgpm_delta_fn whose body inserts
-- into <x>_pgpm_delta. That proof derived <x> from the hypertable's CURRENT schema and relname, and 0.6.0
-- named the function, the delta and the trigger for the table as it was when the tracking copy ran. After an
-- ALTER TABLE ... RENAME or SET SCHEMA nothing matched, the trigger read as a user's, the swap carried it and
-- transmute cloned it onto every partition, so every write to the migrated table went on logging into a
-- delta nothing drains. The proof now reads <x> off the function itself (its own name and schema), which a
-- rename or a move of the table does not change.
--
-- ASYMMETRIC FIXTURE. Two hypertables, each carrying a 0.6.0-shaped capture (built by hand in the spelling
-- 0.6.0's from_hypertable_copy minted, the copy itself dropped as the 0.6.0 remedy says): r55 is then
-- renamed to r55n, s55 is moved into app55. r55 also carries two triggers of the operator's that must be
-- carried: a neutral one, and one whose function is named r55x_pgpm_delta_fn, the module's suffix, but whose
-- body writes the operator's audit, not a delta of its own name (the #969 hazard, under a name the table's
-- current one does not derive). r55 holds 3 rows, s55 holds 2; each capture's delta holds a known key set
-- before the migration ({4} and {3}); after it one write to each table lands in the table and in r55n's
-- audit twice, and in neither delta.
-- WITNESSES: each capture is on its table before the migration and is live (it logged a write), nothing
-- records it, and each migration completed with every row by id.
select plan(17);

create schema app55;
create table public.audit55 (marker text not null, id bigint not null);
create function public.r55_stamp() returns trigger language plpgsql as $f$
begin insert into public.audit55 values ('stamp', new.id); return new; end $f$;
create function public.r55x_pgpm_delta_fn() returns trigger language plpgsql as $f$
begin insert into public.audit55 values ('audit', new.id); return new; end $f$;

-- r55: the 0.6.0 capture, the operator's two triggers, then a RENAME
create table public.r55 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.r55', 'ts', chunk_time_interval => interval '1 day');
insert into public.r55 values (1, '2024-09-01 00:00+00', 1), (2, '2024-09-02 00:00+00', 2), (3, '2024-09-03 00:00+00', 3);
create table public.r55_pgpm_delta as select id, ts from public.r55 with no data;
alter table public.r55_pgpm_delta add column pgpm_seq bigint generated always as identity;
create index on public.r55_pgpm_delta (pgpm_seq);
create function public.r55_pgpm_delta_fn() returns trigger language plpgsql as $pgpm$
      begin
        if tg_op = 'DELETE' then
          insert into public.r55_pgpm_delta (id, ts) values (old.id, old.ts); return old;
        elsif tg_op = 'UPDATE' then
          insert into public.r55_pgpm_delta (id, ts) values (old.id, old.ts), (new.id, new.ts); return new;   -- old + new: a key change dirties both
        else
          insert into public.r55_pgpm_delta (id, ts) values (new.id, new.ts); return new;
        end if;
      end $pgpm$;
create trigger r55_pgpm_delta_trg after insert or update or delete on public.r55
  for each row execute function public.r55_pgpm_delta_fn();
create trigger r55_audit after insert on public.r55 for each row execute function public.r55x_pgpm_delta_fn();
create trigger r55_stamp after insert on public.r55 for each row execute function public.r55_stamp();
alter table public.r55 rename to r55n;

-- s55: the 0.6.0 capture, then a SET SCHEMA (the function and its delta stay where 0.6.0 made them)
create table public.s55 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.s55', 'ts', chunk_time_interval => interval '1 day');
insert into public.s55 values (1, '2024-09-01 00:00+00', 1), (2, '2024-09-02 00:00+00', 2);
create table public.s55_pgpm_delta as select id, ts from public.s55 with no data;
alter table public.s55_pgpm_delta add column pgpm_seq bigint generated always as identity;
create index on public.s55_pgpm_delta (pgpm_seq);
create function public.s55_pgpm_delta_fn() returns trigger language plpgsql as $pgpm$
      begin
        if tg_op = 'DELETE' then
          insert into public.s55_pgpm_delta (id, ts) values (old.id, old.ts); return old;
        elsif tg_op = 'UPDATE' then
          insert into public.s55_pgpm_delta (id, ts) values (old.id, old.ts), (new.id, new.ts); return new;   -- old + new: a key change dirties both
        else
          insert into public.s55_pgpm_delta (id, ts) values (new.id, new.ts); return new;
        end if;
      end $pgpm$;
create trigger s55_pgpm_delta_trg after insert or update or delete on public.s55
  for each row execute function public.s55_pgpm_delta_fn();
alter table public.s55 set schema app55;

-- a write to each during the window, so each capture is shown live before the migration
insert into public.r55n values (4, '2024-09-03 06:00+00', 4);
insert into app55.s55 values (3, '2024-09-03 00:00+00', 3);

select is((select string_agg(t.tgname || ' -> ' || t.tgfoid::regprocedure::text, ', ' order by t.tgname)
             from pg_trigger t where t.tgrelid = 'public.r55n'::regclass and not t.tgisinternal
              and t.tgfoid::regprocedure::text not like '\_timescaledb%'),
          'r55_audit -> r55x_pgpm_delta_fn(), r55_pgpm_delta_trg -> r55_pgpm_delta_fn(), r55_stamp -> r55_stamp()',
          'LIVENESS: the renamed r55n carries the 0.6.0 capture under its old name and the operator''s two triggers');
select is((select string_agg(t.tgname || ' -> ' || t.tgfoid::regprocedure::text, ', ' order by t.tgname)
             from pg_trigger t where t.tgrelid = 'app55.s55'::regclass and not t.tgisinternal
              and t.tgfoid::regprocedure::text not like '\_timescaledb%'),
          's55_pgpm_delta_trg -> s55_pgpm_delta_fn()',
          'LIVENESS: the moved app55.s55 carries the 0.6.0 capture, whose function is still public''s');
select is((select string_agg(id::text, ',' order by id) from public.r55_pgpm_delta), '4',
          'LIVENESS: r55n''s 0.6.0 capture is live: it logged the write made after the rename');
select is((select string_agg(id::text, ',' order by id) from public.s55_pgpm_delta), '3',
          'LIVENESS: s55''s 0.6.0 capture is live: it logged the write made after the move');
select is((select string_agg(marker, ',' order by marker) from public.audit55 where id = 4), 'audit,stamp',
          'LIVENESS: both of the operator''s triggers fire on r55n before the migration');
select ok(not exists (select 1 from pgpm.scratch s where s.obj in ('public.r55_pgpm_delta_fn()'::regprocedure,
                                                                 'public.s55_pgpm_delta_fn()'::regprocedure))
          and obj_description('public.r55_pgpm_delta'::regclass, 'pg_class') is null
          and obj_description('public.s55_pgpm_delta'::regclass, 'pg_class') is null,
          'LIVENESS: nothing records either capture: no pgpm.scratch row, no horizon comment');

call pgpm.from_hypertable('public.r55n', 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable('app55.s55', 'ts', interval '1 day', p_paused => true);

select is((select relkind::text from pg_class where oid = 'public.r55n'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.r55n),
          'p/1,2,3,4', 'LIVENESS: r55n migrated with its 4 rows');
select is((select relkind::text from pg_class where oid = 'app55.s55'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from app55.s55),
          'p/1,2,3', 'LIVENESS: app55.s55 migrated with its 3 rows');

select is((select string_agg(t.tgname, ', ' order by t.tgname) from pg_trigger t
            where t.tgrelid = 'public.r55n'::regclass and not t.tgisinternal),
          'r55_audit, r55_stamp',
          'the migrated r55n carries the operator''s two triggers and not the 0.6.0 capture');
select is((select string_agg(t.tgname, ', ' order by t.tgname) from pg_trigger t
            where t.tgrelid = 'app55.s55'::regclass and not t.tgisinternal),
          null, 'the migrated app55.s55 carries no trigger: not the 0.6.0 capture');
select is((select count(*)::int from pg_trigger where tgfoid = 'public.r55_pgpm_delta_fn()'::regprocedure), 0,
          'no table or partition fires r55''s 0.6.0 capture function after the migration');
select is((select count(*)::int from pg_trigger where tgfoid = 'public.s55_pgpm_delta_fn()'::regprocedure), 0,
          'no table or partition fires s55''s 0.6.0 capture function after the migration');
select cmp_ok((select count(*)::int from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
                where i.inhparent = 'public.r55n'::regclass and t.tgname = 'r55_audit'), '>', 0,
          'LIVENESS: transmute cloned the operator''s r55_audit onto r55n''s partitions');

insert into public.r55n values (5, '2024-09-03 12:00+00', 5);
insert into app55.s55 values (4, '2024-09-03 12:00+00', 4);
select is((select string_agg(marker, ',' order by marker) from public.audit55 where id = 5), 'audit,stamp',
          'both of the operator''s triggers fire on the migrated r55n');
select is((select string_agg(id::text, ',' order by id) from public.r55_pgpm_delta), '4',
          'a write to the migrated r55n is not logged into the 0.6.0 delta');
select is((select string_agg(id::text, ',' order by id) from public.s55_pgpm_delta), '3',
          'a write to the migrated app55.s55 is not logged into the 0.6.0 delta');
select is((select string_agg(id::text, ',' order by id) from app55.s55), '1,2,3,4',
          'the write reached the migrated app55.s55');

select * from finish();
