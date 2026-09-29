-- from_hypertable_cutover records what its swap drops INSIDE the swap, before the handoff (issue #563).
--
-- The cutover commits the irreversible swap (hypertable dropped, incoming foreign keys dropped, the plain
-- copy renamed into place with identity re-added) and only then calls transmute, which can still refuse
-- (the monolith name a long table name derives on a fine grid is the reproduced case). The dropped keys'
-- definitions and the source sequence's position used to live only in plpgsql locals until transmute
-- returned, so that refusal lost both: the referencing tables kept no key and nothing recorded one, and
-- the plain table handed out ids from 1 again. They are now written in the swap transaction itself.
--
-- The refusal path itself cannot be driven from here: the state it leaves exists only after the swap's
-- COMMIT, a throws_* wrapper runs the procedure inside a function where that COMMIT dies with 2D000 and
-- rolls the swap back, and this track fails any file that prints an ERROR: line. bench/hypertable_swap_order.sh
-- drives it as a bare CALL and checks the records, the id and the operator's recovery. This file pins the
-- same ordering on a real hypertable's success path, where it is observable by WHEN the records were
-- written, and the recovery's core half (transmute carries a record that names the table it converts onto
-- the new parent) on its own.
--
-- Autocommit, disposable-db. from_hypertable_copy and _cutover are called as bare statements.
select plan(11);

-- ============================ A: a real hypertable, two incoming keys ============================
create table public.hso (id bigint generated always as identity, ts timestamptz not null, v text,
                         primary key (id, ts));
select create_hypertable('public.hso', 'ts', chunk_time_interval => interval '1 day');
insert into public.hso (ts, v) values (now() - interval '3 days', 'a'), (now() - interval '2 days', 'b'),
                                      (now() - interval '1 day', 'c');
-- burn the sequence AHEAD of max(id): next 8 against max 3, so "seeded past max(id)" (4) cannot pass
select nextval(pg_get_serial_sequence('public.hso', 'id')) from generate_series(1, 4);
create table public.hso_ref_a (rid int primary key, h_id bigint, h_ts timestamptz,
  constraint hso_ref_a_fk foreign key (h_id, h_ts) references public.hso (id, ts));
create table public.hso_ref_b (rid int primary key, h_id bigint, h_ts timestamptz,
  constraint hso_ref_b_fk foreign key (h_id, h_ts) references public.hso (id, ts));
insert into public.hso_ref_a select 1, id, ts from public.hso where v = 'b';
insert into public.hso_ref_b select 1, id, ts from public.hso where v = 'c';

select is(
  (select string_agg(conrelid::regclass || ':' || conname, ',' order by conname) from pg_constraint
    where confrelid = 'public.hso'::regclass and contype = 'f' and conparentid = 0),
  'hso_ref_a:hso_ref_a_fk,hso_ref_b:hso_ref_b_fk',
  'LIVENESS: both incoming keys are live on the hypertable before the migration');

call pgpm.from_hypertable_copy('public.hso', 'ts');
-- The relation the swap renames into place, by oid: after the handoff it is the monolith child.
create temp table hso_dest as select to_regclass('public.hso_pgpm_dest')::oid as oid;
select isnt((select oid from hso_dest), NULL::oid, 'LIVENESS: the copy built the destination');

call pgpm.from_hypertable_cutover('public.hso', 'ts', interval '1 day', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'public.hso'::regclass) || '/'
    || (select count(*) from pg_inherits where inhparent = 'public.hso'::regclass
                                           and inhrelid = (select oid from hso_dest)),
  'p/1', 'LIVENESS: the migration completed, with the swapped-in table as the monolith child');

-- THE ORDERING. Each record and each log row is written by the swap transaction, so it predates the
-- `transmute` row the handoff's cutover writes. Recorded after the handoff (pre-#563), they postdate it.
select is(
  (select string_agg(d.constraint_name || ':' || (d.dropped_at < t.at), ',' order by d.constraint_name)
     from pgpm.dropped_fk d
     cross join (select at from pgpm.log where parent_table = 'public.hso'::regclass and action = 'transmute') t),
  'hso_ref_a_fk:true,hso_ref_b_fk:true',
  'each incoming key is recorded in pgpm.dropped_fk by the swap, before the handoff to transmute');
select is(
  (select string_agg(l.method || ':' || (l.parent_table::oid = (select oid from hso_dest)) || ':' || (l.at < t.at),
                     ',' order by l.method)
     from pgpm.log l
     cross join (select at from pgpm.log where parent_table = 'public.hso'::regclass and action = 'transmute') t
    where l.action = 'drop_incoming_fk'),
  'hso_ref_a_fk:true:true,hso_ref_b_fk:true:true',
  'each drop is logged by the swap, against the table it put in place, before the handoff');

-- The records followed the table onto the new parent and closed the window.
select is(
  (select string_agg(constraint_name || ':' || referencing_table::text || ':'
                     || (restored_at is not null) || ':' || (validated_at is not null), ',' order by constraint_name)
     from pgpm.dropped_fk where parent_table = 'public.hso'::regclass),
  'hso_ref_a_fk:hso_ref_a:true:true,hso_ref_b_fk:hso_ref_b:true:true',
  'the records name the new parent, and both keys are restored and validated');
select throws_ok(
  $$ insert into public.hso_ref_a values (9, 999, now()) $$,
  '23503', NULL, 'and the restored key enforces: an orphan reference is refused');

insert into public.hso (ts, v) values (now() - interval '1 hour', 'd');
select is((select id from public.hso where v = 'd'), 8::bigint,
  'the next id continues from the source sequence''s position (8), not max(id)+1 (4)');

-- ============================ B: the recovery's core half ============================
-- A plain table in the state a refused handoff leaves it: its incoming key dropped and recorded against
-- it. The operator's remedy is to re-run transmute; the record must come along to the new parent, or
-- restore_incoming_fks (which reads records by parent) never finds it.
create table public.hso_rec (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.hso_rec values (1, now() - interval '2 days'), (2, now() - interval '1 day');
create table public.hso_rec_ref (rid int primary key, r_id bigint, r_ts timestamptz);
insert into public.hso_rec_ref select 1, id, ts from public.hso_rec where id = 2;
insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
  values ('public.hso_rec'::regclass, 'public.hso_rec_ref'::regclass, 'hso_rec_ref_fk',
          'FOREIGN KEY (r_id, r_ts) REFERENCES public.hso_rec(id, ts)');
create temp table hso_rec_orig as select 'public.hso_rec'::regclass::oid as oid;

call pgpm.transmute('public.hso_rec', 'ts', interval '1 day', p_paused => false);

select is(
  (select (parent_table = 'public.hso_rec'::regclass) || ':' || (parent_table::oid <> (select oid from hso_rec_orig))
     from pgpm.dropped_fk where constraint_name = 'hso_rec_ref_fk'),
  'true:true',
  'transmute carries a record naming the table it converts onto the new parent, off the monolith child');
select is(pgpm.restore_incoming_fks('public.hso_rec'::regclass), 1,
  'so restore_incoming_fks finds it and re-adds the key');
select throws_ok(
  $$ insert into public.hso_rec_ref values (9, 999, now()) $$,
  '23503', NULL, 'and the re-added key enforces against the parent');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
