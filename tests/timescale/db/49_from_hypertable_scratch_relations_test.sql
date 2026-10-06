-- The scratch-relation conformance suite, pgpm_hypertable's half (issues #955, #949; the lever of #966).
--
-- tests/267 states the lever for the core: a relation pgpm makes for its own use is MINTED one way (the
-- parent's owner and an owner-only ACL, in the transaction that creates it) and RESOLVED one way (from the
-- record that transaction wrote, never from a name rendered from the parent's). The module's, the list this
-- file is driven by:
--
--   hypertable_dest      <rel>_pgpm_dest, the copy, recorded in pgpm.scratch
--   hypertable_delta     <rel>_pgpm_delta, a tracking copy's change log, recorded in pgpm.scratch
--   hypertable_delta_fn  <rel>_pgpm_delta_fn(), its trigger function, recorded in pgpm.scratch
--   hypertable_delta_trg <rel>_pgpm_delta_trg, the row trigger on the hypertable, known by the function it fires
--   the key index        <conname>_pgpm_new (or pgpm_new_<oid>), pre-built on the copy, known by the copy it is on
--
-- STAGE A, minted (#949) and the list complete. The migrating role (this session, postgres) holds ALTER
-- DEFAULT PRIVILEGES granting SELECT on new tables to w49_stranger, which holds nothing on the hypertable.
-- After a tracking copy, every relation, index and function that appeared in the hypertable's schema must
-- be one the list names and pgpm.scratch records; the copy and the delta must be the hypertable's owner's
-- with no grant to the stranger during the whole online window (the delta carries INSERT for the
-- hypertable's writer, whom the capture trigger writes as, and nothing else). The copy used to keep the
-- migrating role's default privileges until the swap, and the delta for good. Then the cutover: the
-- migrated table holds the writer's row and pgpm.scratch keeps nothing of the hypertable it no longer has.
-- STAGE B, resolved (#955). An operator's table, function or trigger under each name the copy mints, or the
-- drains and the cutover read, is never dropped, replaced, drained into, read as the delta or swapped in:
-- the copy refuses up front (it used to drop or replace each), the drains and the cutover with no copy
-- recorded refuse by their own message (they used to work whatever answered to the name), an append-only
-- copy's cutover does not take the operator's <rel>_pgpm_delta for its change log, and the cutover of a
-- hypertable renamed since its copy drops the function the copy recorded, not the operator's under the
-- new name.
-- STAGE D, carried by record, never by name (#969). The swap replays every trigger pgpm did not make: an
-- operator's trigger whose function happens to be named <rel>_pgpm_delta_fn is carried by an untracked
-- migration (it was left out by that name and went with the hypertable). And none it did: a tracking copy's
-- capture on a hypertable renamed since, whose delta's comment the operator replaced, is known by
-- pgpm.scratch's record alone, and a capture pgpm 0.6.0 minted, which carries neither record, by proof (its
-- function's body inserts into <rel>_pgpm_delta). Run before stage C, which uninstalls. (Lettered after it.)
-- STAGE C, uninstall.sql reads the record. A tracking copy never cut over, whose comment the operator has
-- since replaced: uninstall drops the copy, the delta and the function by pgpm.scratch, where the comment
-- sweeps alone (#737, #773) would have left all three, the trigger logging every write.
--
-- ASYMMETRIC: 30 rows; the operator's tables hold 2, 1, 3 and 1 rows, each asserted by identity after every
-- step that could reach it. Every refusal is pinned by its message (a procedure that does not refuse dies at
-- its first COMMIT inside throws_like, 2D000, and that must not pass). Autocommit, disposable database: every
-- committing procedure that must succeed is a top-level CALL. bench/scratch_relations.sh runs this file
-- against the hypertable_scratch_* mutants, uninstall_scratch_record_unread and the carried-DDL mutants of
-- stage D (hypertable_carried_ddl_*, hypertable_carry_capture_unrecorded), each of which it must FAIL.
\if :{?uninstall}
\else
\set uninstall ../../../pgpm_core/uninstall.sql
\endif
select plan(64);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w49_owner') then create role w49_owner; end if;
  if not exists (select 1 from pg_roles where rolname = 'w49_stranger') then create role w49_stranger; end if;
  if not exists (select 1 from pg_roles where rolname = 'w49_writer') then create role w49_writer; end if;
end $$;
-- by name, never `to current_user` (that segfaults a backend on the fleet image): the migrating role must be a
-- member of the hypertable's owner to give it the copy, and of the writer to write as it below
grant w49_owner, w49_writer, w49_stranger to postgres;
grant usage, create on schema public to w49_owner;
grant usage on schema public to w49_stranger, w49_writer;

-- what a role reads of a relation, without letting a 42501 kill the file: null when it is refused
create function w49_reads(p_rel text) returns bigint language plpgsql as $f$
declare v bigint;
begin
  execute format('select count(*) from %s', p_rel) into v;
  return v;
exception when insufficient_privilege then return null;
end $f$;
grant execute on function w49_reads(text) to w49_stranger;
-- an operator table's notes, or '(table dropped)'
create function w49_notes(p_rel text) returns text language plpgsql as $f$
declare v text;
begin
  if to_regclass(p_rel) is null then return '(table dropped)'; end if;
  execute format('select string_agg(note, '','' order by note) from %s', p_rel) into v;
  return v;
end $f$;

-- ======================================================================================================
-- STAGE A: minted owner-only, and the list is complete
-- ======================================================================================================
-- CREATED as w49_owner rather than handed to it: ALTER ... OWNER on a hypertable re-owns its chunks, which needs
-- CREATE on _timescaledb_internal, which the fleet image's postgres cannot grant (tests/timescale/db/33)
set role w49_owner;
create table public.m49 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.m49', 'ts', chunk_time_interval => interval '1 day');
insert into public.m49 select timestamptz '2024-01-01 00:00+00' + g * interval '2 hours', g, g from generate_series(1, 30) g;
grant insert, update, select on public.m49 to w49_writer;
reset role;
alter default privileges in schema public grant select on tables to w49_stranger;
create table public.w49_witness (x int);
select ok(has_table_privilege('w49_stranger', 'public.w49_witness', 'SELECT')
          and not has_table_privilege('w49_stranger', 'public.m49', 'SELECT'),
  'LIVENESS: a table this session creates now grants w49_stranger SELECT, and w49_stranger holds nothing on m49');

-- every relation of every kind (a sequence, a view, a matview is as much an omission as a table)
create temp table w49_before as
  select oid, 'r' as k from pg_class where relnamespace = 'public'::regnamespace
  union all select oid, 'f' from pg_proc where pronamespace = 'public'::regnamespace;

call pgpm.from_hypertable_copy('public.m49', 'ts', p_track_changes => true);

select s.obj as dest from pgpm.scratch s where s.parent_oid = 'public.m49'::regclass::oid and s.kind = 'hypertable_dest' \gset
select s.obj as delta from pgpm.scratch s where s.parent_oid = 'public.m49'::regclass::oid and s.kind = 'hypertable_delta' \gset
select s.obj as fn from pgpm.scratch s where s.parent_oid = 'public.m49'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset
select is((select array_agg(c.oid::regclass::text order by c.relname) from pg_class c where c.oid in (:'dest'::oid, :'delta'::oid)),
  array['m49_pgpm_delta', 'm49_pgpm_dest'],
  'LIVENESS: the copy recorded its copy (hypertable_dest) and its delta (hypertable_delta), under the names it minted');

-- THE LIST AGAINST WHAT WAS CREATED
-- of whatever kind: a relation that is not the recorded copy or delta, or an index or identity sequence that
-- PostgreSQL makes and drops with one of them, is an omission
select is(
  (select array_agg(c.oid order by c.oid) from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.oid not in (select oid from w49_before where k = 'r')),
  (select array_agg(o order by o) from (
     select o from unnest(array[:'dest'::oid, :'delta'::oid]) o
     union select i.indexrelid from pg_index i where i.indrelid in (:'dest'::oid, :'delta'::oid)
     union select d.objid from pg_depend d
            where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype = 'i'
              and d.refobjid in (:'dest'::oid, :'delta'::oid)
              and (select relnamespace from pg_class where oid = d.objid) = 'public'::regnamespace) x),
  'the list is complete: the only relations the copy created, of any kind, are the recorded copy and delta and their indexes');
select is(
  (select count(*)::int from pg_class c join pg_index i on i.indexrelid = c.oid
    where c.relnamespace = 'public'::regnamespace and c.oid not in (select oid from w49_before where k = 'r')
      and i.indrelid not in (:'dest'::oid, :'delta'::oid)),
  0, 'the list is complete: every index the copy created (the key index, the delta''s) is on the recorded copy or delta');
select ok(exists (select 1 from pg_index i where i.indrelid = :'dest'::oid and i.indisunique),
  'LIVENESS: the tracking copy pre-built its key index on the recorded copy');
select is(
  (select array_agg(p.oid order by p.oid) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.oid not in (select oid from w49_before where k = 'f')),
  array[:'fn'::oid],
  'the list is complete: the only function the copy created is the recorded trigger function (hypertable_delta_fn)');
select is((select tgfoid from pg_trigger where tgrelid = 'public.m49'::regclass and tgname = 'm49_pgpm_delta_trg'), :'fn'::oid,
  'hypertable_delta_trg: the trigger on the hypertable fires the recorded function');

select is((select array_agg(pg_get_userbyid(relowner)::text order by oid) from pg_class where oid in (:'dest'::oid, :'delta'::oid)),
  array['w49_owner', 'w49_owner'], 'hypertable_dest, hypertable_delta: owned like the hypertable from the copy on');
select is((select pg_get_userbyid(proowner)::text from pg_proc where oid = :'fn'::oid), 'w49_owner',
  'hypertable_delta_fn: owned like the hypertable');
select ok((select relacl is null or not exists (select 1 from aclexplode(relacl) a where a.grantee <> relowner)
             from pg_class where oid = :'dest'::oid),
  'hypertable_dest: its ACL is the owner''s alone during the online window');
select is((select array_agg(distinct pg_get_userbyid(a.grantee)::text || ':' || a.privilege_type)
             from pg_class c cross join lateral aclexplode(c.relacl) a
            where c.oid = :'delta'::oid and a.grantee <> c.relowner),
  array['w49_writer:INSERT'], 'hypertable_delta: its only grant beyond the owner''s is INSERT for the hypertable''s writer');
set role w49_stranger;
select is(w49_reads('public.m49_pgpm_dest'), null::bigint, 'hypertable_dest: w49_stranger is refused reading the copied rows');
select is(w49_reads('public.m49_pgpm_delta'), null::bigint, 'hypertable_delta: w49_stranger is refused reading the captured keys');
reset role;
select is(w49_reads('public.m49_pgpm_dest'), 30::bigint, 'LIVENESS: the copy holds the 30 rows');

set role w49_writer;
select lives_ok($$ insert into public.m49 values (timestamptz '2024-01-03 01:00+00', 31, 310) $$,
  'the hypertable''s writer writes during the online window (its INSERT on the delta)');
select lives_ok($$ update public.m49 set v = -2 where id = 2 $$, 'and updates a copied row');
reset role;
select is((select array_agg(id order by pgpm_seq) from public.m49_pgpm_delta), array[31, 2, 2]::bigint[],
  'LIVENESS: the capture trigger logged both writes in the recorded delta');

call pgpm.from_hypertable_cutover('public.m49', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.m49'::regclass), 'p', 'LIVENESS: m49 was migrated');
select is((select array_agg(id || ':' || v order by id) from public.m49 where id in (1, 2, 3, 30, 31)),
  array['1:1', '2:-2', '3:3', '30:30', '31:310'], 'the migrated table holds the writer''s two writes, and its neighbours');
select is((select count(*)::int from pgpm.scratch where obj in (:'dest'::oid, :'delta'::oid, :'fn'::oid)), 0,
  'the swap forgot the copy, the delta and the function: none of them is pgpm''s scratch any more');
select ok(not has_table_privilege('w49_stranger', 'public.m49', 'SELECT'),
  'the migrated table grants w49_stranger nothing (it carries the hypertable''s grants)');

-- ======================================================================================================
-- STAGE B: what pgpm did not record is never dropped, replaced, drained, read or swapped in
-- ======================================================================================================
-- hypertable_dest: the copy's name held by the operator's table
create table public.n49a (ts timestamptz not null, v int);
select create_hypertable('public.n49a', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49a values ('2024-02-01 00:00+00', 1), ('2024-02-02 00:00+00', 2);
create table public.n49a_pgpm_dest (note text primary key);
insert into public.n49a_pgpm_dest values ('operator-dest-a'), ('operator-dest-b');
select 'public.n49a_pgpm_dest'::regclass::oid as op_dest \gset
select throws_like($$ call pgpm.from_hypertable_copy('public.n49a', 'ts') $$,
  '%from_hypertable_copy builds its copy as public.n49a_pgpm_dest, and that name is held by%which pgpm did not record as this hypertable''s copy%',
  'hypertable_dest: the copy refuses the operator''s table under its name');
select is(w49_notes('public.n49a_pgpm_dest') || '/' || (select oid from pg_class where oid = :'op_dest'::oid)::text,
  'operator-dest-a,operator-dest-b/' || :'op_dest',
  'hypertable_dest: the operator''s table is the same relation, with its 2 rows');
alter table public.n49a_pgpm_dest rename to n49a_mine;
call pgpm.from_hypertable_copy('public.n49a', 'ts');
select is(w49_reads('public.n49a_pgpm_dest'), 2::bigint, 'LIVENESS: with the name free the copy is built, so the name was the only obstacle');
select is(w49_notes('public.n49a_mine'), 'operator-dest-a,operator-dest-b', 'and the operator''s table, renamed aside, is untouched');

-- hypertable_delta: a tracking copy's delta name held by the operator's table
create table public.n49b (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.n49b', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49b values ('2024-03-01 00:00+00', 1, 1), ('2024-03-02 00:00+00', 2, 2), ('2024-03-03 00:00+00', 3, 3);
create table public.n49b_pgpm_delta (id bigint, ts timestamptz, pgpm_seq bigint, note text);
insert into public.n49b_pgpm_delta values (2, '2024-03-02 00:00+00', 1, 'operator-delta');
select throws_like($$ call pgpm.from_hypertable_copy('public.n49b', 'ts', p_track_changes => true) $$,
  '%builds its change-capture delta as public.n49b_pgpm_delta, and that name is held by%',
  'hypertable_delta: the tracking copy refuses the operator''s table under its delta''s name');
select is(w49_notes('public.n49b_pgpm_delta'), 'operator-delta', 'hypertable_delta: the operator''s table keeps its row');
call pgpm.from_hypertable_copy('public.n49b', 'ts');   -- append-only: mints no delta
call pgpm.from_hypertable_cutover('public.n49b', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.n49b'::regclass), 'p',
  'hypertable_delta: the append-only copy''s cutover completes without taking the operator''s table for its change log');
select is(w49_notes('public.n49b_pgpm_delta'), 'operator-delta', 'hypertable_delta: and the cutover leaves it, with its row');
select is((select array_agg(id order by id) from public.n49b), array[1, 2, 3]::bigint[], 'LIVENESS: n49b migrated with its 3 rows');

-- hypertable_delta_fn: the function's name held by the operator's function
create table public.n49c (ts timestamptz not null, id bigint not null, primary key (id, ts));
select create_hypertable('public.n49c', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49c values ('2024-04-01 00:00+00', 1);
create function public.n49c_pgpm_delta_fn() returns trigger language plpgsql as $$ begin return new; end $$;
select prosrc as op_src, oid as op_fn from pg_proc where oid = 'public.n49c_pgpm_delta_fn()'::regprocedure \gset
select throws_like($$ call pgpm.from_hypertable_copy('public.n49c', 'ts', p_track_changes => true) $$,
  '%creates its change-capture function as public.n49c_pgpm_delta_fn(), and that name is held by function%',
  'hypertable_delta_fn: the tracking copy refuses the operator''s function under its name');
select is((select prosrc from pg_proc where oid = :'op_fn'::oid), :'op_src',
  'hypertable_delta_fn: the operator''s function is the same, its body unreplaced');

-- hypertable_delta_trg: the trigger's name held by the operator's trigger on the hypertable
create table public.n49d (ts timestamptz not null, id bigint not null, primary key (id, ts));
select create_hypertable('public.n49d', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49d values ('2024-05-01 00:00+00', 1);
create table public.n49d_audit (id bigint);
create function public.n49d_audit_fn() returns trigger language plpgsql as $$ begin insert into public.n49d_audit values (new.id); return new; end $$;
create trigger n49d_pgpm_delta_trg after insert on public.n49d for each row execute function public.n49d_audit_fn();
select oid as op_trg from pg_trigger where tgrelid = 'public.n49d'::regclass and tgname = 'n49d_pgpm_delta_trg' \gset
select throws_like($$ call pgpm.from_hypertable_copy('public.n49d', 'ts', p_track_changes => true) $$,
  '%puts its change-capture trigger on it as n49d_pgpm_delta_trg, and a trigger of that name is already there%',
  'hypertable_delta_trg: the tracking copy refuses the operator''s trigger under its name');
select is((select tgfoid::regprocedure::text from pg_trigger where oid = :'op_trg'::oid), 'n49d_audit_fn()',
  'hypertable_delta_trg: the operator''s trigger is the same, still firing its own function');

-- the drains and the cutover, with no copy recorded, and the operator's tables under both names
create table public.n49e (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.n49e', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49e values ('2024-06-01 00:00+00', 1, 1), ('2024-06-02 00:00+00', 2, 2);
create table public.n49e_pgpm_dest (like public.n49e);
insert into public.n49e_pgpm_dest values ('2020-01-01 00:00+00', 900, 9);
create table public.n49e_pgpm_delta (id bigint, ts timestamptz, pgpm_seq bigint generated always as identity);
insert into public.n49e_pgpm_delta (id, ts) values (901, '2020-01-01 00:00+00'), (902, '2020-01-02 00:00+00'), (903, '2020-01-03 00:00+00');
select 'public.n49e_pgpm_dest'::regclass::oid as e_dest, 'public.n49e_pgpm_delta'::regclass::oid as e_delta \gset
create function w49_e_state() returns text language sql as $f$
  select (select string_agg(id::text, ',' order by id) from public.n49e_pgpm_dest) || '/'
      || (select string_agg(id::text, ',' order by id) from public.n49e_pgpm_delta) || '/'
      || (select count(*) from timescaledb_information.hypertables where hypertable_name = 'n49e')::text
$f$;
select is(w49_e_state(), '900/901,902,903/1', 'LIVENESS: n49e is a hypertable with no copy, and the operator''s tables hold 1 and 3 rows');
select throws_like($$ select pgpm.from_hypertable_drain_delta_step('public.n49e', 'ts') $$,
  'pg_partition_magician: from_hypertable_drain_delta_step(n49e) found no delta%',
  'drain_delta_step refuses with no delta recorded, never reading the operator''s');
select throws_like($$ call pgpm.from_hypertable_drain_delta('public.n49e', 'ts') $$,
  'pg_partition_magician: from_hypertable_drain_delta(n49e) found no delta%',
  'drain_delta refuses by its own message with no delta recorded');
select throws_like($$ select pgpm.from_hypertable_drain_appends_step('public.n49e', 'ts', 100, null) $$,
  'pg_partition_magician: from_hypertable_drain_appends_step(n49e) found no copy to drain%',
  'drain_appends_step refuses with no copy recorded, never inserting into the operator''s table');
select throws_like($$ call pgpm.from_hypertable_drain_appends('public.n49e', 'ts') $$,
  'pg_partition_magician: from_hypertable_drain_appends(n49e) found no copy to drain%',
  'drain_appends refuses by its own message with no copy recorded');
select throws_like($$ call pgpm.from_hypertable_cutover('public.n49e', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: from_hypertable_cutover(n49e) found no copy to cut over%never a relation that merely carries its name%',
  'the cutover refuses with no copy recorded, never swapping in the operator''s table of the hypertable''s shape');
select is(w49_e_state(), '900/901,902,903/1', 'the operator''s tables keep their rows, and n49e is still a hypertable');
select is((select array_agg(oid order by oid) from pg_class where oid in (:'e_dest'::oid, :'e_delta'::oid)),
  (select array_agg(o order by o) from unnest(array[:'e_dest'::oid, :'e_delta'::oid]) o),
  'the operator''s tables are the same relations');

-- the cutover of a hypertable renamed since its tracking copy drops the function the copy recorded
create table public.n49f (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.n49f', 'ts', chunk_time_interval => interval '1 day');
insert into public.n49f values ('2024-07-01 00:00+00', 1, 1), ('2024-07-02 00:00+00', 2, 2), ('2024-07-03 00:00+00', 3, 3);
call pgpm.from_hypertable_copy('public.n49f', 'ts', p_track_changes => true);
select s.obj as f_fn from pgpm.scratch s where s.parent_oid = 'public.n49f'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset
alter table public.n49f rename to n49g;
create function public.n49g_pgpm_delta_fn() returns trigger language plpgsql as $$ begin return new; end $$;
select 'public.n49g_pgpm_delta_fn()'::regprocedure::oid as g_fn \gset
delete from public.n49g where id = 3;   -- a write during the window, after the rename
call pgpm.from_hypertable_cutover('public.n49g', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.n49g'::regclass) || '/'
          || (select string_agg(id::text, ',' order by id) from public.n49g),
  'p/1,2', 'LIVENESS: the renamed hypertable migrated from the copy its old name recorded, the late delete applied');
select is((select count(*)::int from pg_proc where oid = :'f_fn'::oid), 0,
  'hypertable_delta_fn: the cutover dropped the function the copy recorded, n49f_pgpm_delta_fn');
select is((select oid from pg_proc where oid = :'g_fn'::oid), :'g_fn'::oid,
  'hypertable_delta_fn: and left the operator''s n49g_pgpm_delta_fn, the name the hypertable''s new name derives');

-- ======================================================================================================
-- STAGE D: the swap carries every trigger pgpm did not make, and none it did (#969 bullet 5)
-- ======================================================================================================
-- _from_hypertable_carried_ddl leaves the module's capture trigger out of what the swap replays. It used to
-- know that trigger by its function's NAME, <rel>_pgpm_delta_fn, so an operator's trigger whose function
-- carried that name was silently not carried by an untracked migration and went with the hypertable. Now
-- by the record (pgpm.scratch), by the delta's horizon comment (#842), or, for a capture pgpm 0.6.0 minted
-- (neither), by proof: a function of that name whose body inserts into <rel>_pgpm_delta.
create table public.d49_audit (marker text, id bigint);
-- D1, the operator's trigger under the working name, beside a neutral one: both carried
create table public.d49a (id bigint not null, ts timestamptz not null, v int not null, primary key (id, ts));
select create_hypertable('public.d49a', 'ts', chunk_time_interval => interval '1 day');
insert into public.d49a values (1, '2024-09-01 00:00+00', 10), (2, '2024-09-02 00:00+00', 20), (3, '2024-09-03 00:00+00', 30);
create function public.d49a_pgpm_delta_fn() returns trigger language plpgsql as $f$
begin insert into public.d49_audit values ('audit', new.id); return new; end $f$;
create trigger d49a_audit after insert on public.d49a for each row execute function public.d49a_pgpm_delta_fn();
create function public.d49a_stamp() returns trigger language plpgsql as $f$
begin insert into public.d49_audit values ('stamp', new.id); return new; end $f$;
create trigger d49a_stamp after insert on public.d49a for each row execute function public.d49a_stamp();
insert into public.d49a values (4, '2024-09-03 06:00+00', 40);
select is((select string_agg(marker, ',' order by marker) from public.d49_audit where id = 4), 'audit,stamp',
  'LIVENESS: both of the operator''s triggers fire on d49a before the migration');
call pgpm.from_hypertable('public.d49a', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.d49a'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.d49a),
  'p/1,2,3,4', 'LIVENESS: d49a migrated with its 4 rows');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.d49a'::regclass and tgname = 'd49a_stamp'),
  'LIVENESS: the neutral-named trigger was carried');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.d49a'::regclass and tgname = 'd49a_audit'),
  'an operator''s trigger whose function is named d49a_pgpm_delta_fn is carried onto the migrated table');
insert into public.d49a values (5, '2024-09-03 12:00+00', 50);
select is((select string_agg(marker, ',' order by marker) from public.d49_audit where id = 5), 'audit,stamp',
  'and both of the operator''s triggers fire on the migrated table');

-- D2, the module's capture known by the record alone: a tracking copy of a hypertable renamed since, whose
-- delta's comment the operator has replaced, so neither the name nor the comment says it is pgpm's
create table public.d49b (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.d49b', 'ts', chunk_time_interval => interval '1 day');
insert into public.d49b values (1, '2024-09-01 00:00+00', 1), (2, '2024-09-02 00:00+00', 2), (3, '2024-09-03 00:00+00', 3);
call pgpm.from_hypertable_copy('public.d49b', 'ts', p_track_changes => true);
select s.obj as b_fn from pgpm.scratch s where s.parent_oid = 'public.d49b'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset
alter table public.d49b rename to d49c;
comment on table public.d49b_pgpm_delta is 'the operator''s note';
delete from public.d49c where id = 2;   -- a write during the window, captured
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.d49c'::regclass and tgfoid = :'b_fn'::oid)
          and obj_description('public.d49b_pgpm_delta'::regclass, 'pg_class') = 'the operator''s note',
  'LIVENESS: d49c carries the recorded capture trigger, under the old name, and its delta no comment record');
call pgpm.from_hypertable_cutover('public.d49c', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.d49c'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.d49c),
  'p/1,3', 'the cutover of d49c completes, the captured delete applied');
select is((select count(*)::int from pg_trigger where tgfoid = :'b_fn'::oid), 0,
  'and no table or partition fires the recorded capture function');

-- D3, a capture pgpm 0.6.0 minted, which carries no record and no comment: its trigger is still on the
-- hypertable (its abandoned copy was dropped to re-run the migration), and an untracked migration follows
create table public.d49d (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.d49d', 'ts', chunk_time_interval => interval '1 day');
insert into public.d49d values (1, '2024-09-01 00:00+00', 1), (2, '2024-09-02 00:00+00', 2);
create table public.d49d_pgpm_delta as select id, ts from public.d49d with no data;
alter table public.d49d_pgpm_delta add column pgpm_seq bigint generated always as identity;
create function public.d49d_pgpm_delta_fn() returns trigger language plpgsql as $pgpm$
    begin
      if tg_op = 'DELETE' then
        insert into public.d49d_pgpm_delta (id, ts) values (old.id, old.ts); return old;
      elsif tg_op = 'UPDATE' then
        insert into public.d49d_pgpm_delta (id, ts) values (old.id, old.ts), (new.id, new.ts); return new;
      else
        insert into public.d49d_pgpm_delta (id, ts) values (new.id, new.ts); return new;
      end if;
    end $pgpm$;
create trigger d49d_pgpm_delta_trg after insert or update or delete on public.d49d
  for each row execute function public.d49d_pgpm_delta_fn();
insert into public.d49d values (3, '2024-09-03 00:00+00', 3);
select is((select string_agg(id::text, ',') from public.d49d_pgpm_delta), '3',
  'LIVENESS: d49d''s 0.6.0 capture is live (it logged id 3), and nothing records it');
call pgpm.from_hypertable('public.d49d', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.d49d'::regclass)
          || '/' || (select string_agg(id::text, ',' order by id) from public.d49d),
  'p/1,2,3', 'LIVENESS: d49d migrated with its 3 rows');
select is((select count(*)::int from pg_trigger where tgfoid = 'public.d49d_pgpm_delta_fn()'::regprocedure), 0,
  'no table or partition fires the 0.6.0 capture function after the migration');
insert into public.d49d values (4, '2024-09-03 06:00+00', 4);
select is((select string_agg(id::text, ',') from public.d49d_pgpm_delta), '3',
  'and a write to the migrated d49d is not logged into the 0.6.0 delta');

-- ======================================================================================================
-- STAGE C: uninstall.sql reads the record
-- ======================================================================================================
create table public.u49 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.u49', 'ts', chunk_time_interval => interval '1 day');
insert into public.u49 values ('2024-08-01 00:00+00', 1, 1), ('2024-08-02 00:00+00', 2, 2), ('2024-08-03 00:00+00', 3, 3);
call pgpm.from_hypertable_copy('public.u49', 'ts', p_track_changes => true);   -- never cut over
comment on table public.u49_pgpm_dest is 'the operator''s note';
comment on table public.u49_pgpm_delta is 'the operator''s note';
select s.obj as u_fn from pgpm.scratch s where s.parent_oid = 'public.u49'::regclass::oid and s.kind = 'hypertable_delta_fn' \gset
select ok(to_regclass('public.u49_pgpm_dest') is not null and to_regclass('public.u49_pgpm_delta') is not null
          and exists (select 1 from pg_trigger where tgrelid = 'public.u49'::regclass and tgfoid = :'u_fn'::oid)
          and obj_description('public.u49_pgpm_dest'::regclass, 'pg_class') = 'the operator''s note',
  'LIVENESS: u49''s abandoned tracking copy, delta and trigger are there, and neither table carries the comment record any more');

begin;
\ir :uninstall
commit;

select is(to_regnamespace('pgpm'), null, 'LIVENESS: the uninstall removed the pgpm schema');
select is(to_regclass('public.u49_pgpm_dest'), null, 'hypertable_dest: uninstall dropped the recorded copy');
select is(to_regclass('public.u49_pgpm_delta'), null, 'hypertable_delta: uninstall dropped the recorded delta');
select is((select count(*)::int from pg_proc where oid = :'u_fn'::oid), 0,
  'hypertable_delta_fn: uninstall dropped the recorded function, and its trigger with it');
select is((select array_agg(id order by id) from public.u49), array[1, 2, 3]::bigint[], 'and u49 keeps its 3 rows');
select is(w49_notes('public.n49a_mine'), 'operator-dest-a,operator-dest-b', 'the operator''s tables are untouched by the uninstall');

select * from finish();
