-- The scratch-relation conformance suite, core half (issues #949, #950, #955; the lever of #966).
--
-- A SCRATCH relation is one pgpm makes for its own use beside a table it manages. Every one is MINTED one
-- way (the parent's owner and an owner-only ACL, in the transaction that creates it: _scratch_mint) and
-- RESOLVED one way (from the record that transaction wrote, never from a name rendered from the parent's),
-- and its owner FOLLOWS the parent's on every tick (_scratch_owner_follow). The core's, the list this file
-- is driven by:
--
--   regrain_delta       <rel>_pgpm_regrain_delta    recorded in pgpm.config.regrain_delta_oid
--   regrain_capture_fn  <rel>_pgpm_regrain_capture() recorded in pgpm.config.regrain_capture_fn_oid
--   regrain_fine_child  a regrain's copy, standalone until the swap, recorded in pgpm.part.child_oid
--   transmute_staging   <rel>_pgpm_new, transmute's new parent before the renames: phase 3 is one
--                       transaction, so it never outlives it and needs no record; its name is refused when
--                       held (#344) and it ends as the parent, with the original table's grants (#838)
--
-- (pgpm_hypertable's are tests/timescale/db/49.) Each stage below runs every entry of the list, and stage A
-- checks the LIST against what pgpm actually created: every relation and function that appeared in the
-- parent's schema while a regrain was in flight must be one the list names, and recorded. A new scratch
-- relation that some later change mints therefore fails here as an omission from the list, rather than
-- passing because nobody thought to test it.
--
-- STAGE A, minted (#949). The maintaining role (this session) holds ALTER DEFAULT PRIVILEGES granting SELECT
-- on new tables to w267_stranger, which holds nothing on the parent; on Supabase that is anon and
-- authenticated. Every scratch relation must be the parent's owner's with no grant to the stranger from the
-- tick that creates it: the delta right after the prepare tick (it carries INSERT for the parent's writers,
-- whom the capture trigger writes as, and nothing else), a fine child after its FIRST copy batch, its
-- sub-range unfinished. Before, the delta was never reset and a fine child only after its sub-range's last
-- batch. LIVENESS: a table this session creates gets the stranger's SELECT (the default grant is in force);
-- the fine child holds copied rows; the delta holds a captured key.
-- STAGE B, resolved (#955). An operator's table and function under the delta's and capture function's
-- derived names, on a parent that has never regrained: regrain_cancel used to TRUNCATE the table, untransmute
-- to DROP both. Must survive, by their rows and their oids. The prepare refuses them (#496), a fine child's
-- name held by another relation is refused (#631), and transmute refuses an occupied staging name (#344).
-- STAGE C, handed over, the session can (#950). The parent and its partitions are given to w267_new mid-regrain.
-- The next tick (a superuser) gives the delta, the function and the not-yet-attached copy to w267_new too; it
-- does not skip; w267_new writes into the regraining range, and the parent's writer w267_writer still can
-- (the delta's grants are re-synced); the swap keeps both writes, by identity.
-- STAGE D, handed over, the session cannot (#950). Maintenance is the table's owner, a non-superuser; the table
-- is handed from w267_m1 to w267_m2, and w267_m2 runs the next tick. It can neither re-own w267_m1's delta nor
-- act as w267_m1, so the tick refuses ONCE, up front, with the hand-over statements (never 'permission
-- denied' on the delta, which is what every tick logged before). After the remedy the message names, the
-- next tick goes on.
--
-- ASYMMETRIC: 200 rows, one sub-range copied 30 of 49, two writers making three changes (an UPDATE by each,
-- a DELETE), the operator's tables holding 2 rows and 1 row. bench/scratch_relations.sh runs this file against
-- the core mutants (scratch_* and regrain_capture_names_derived_fallback), each of which it must FAIL.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(47);

do $$ begin create role w267_owner;    exception when duplicate_object then null; end $$;
do $$ begin create role w267_stranger; exception when duplicate_object then null; end $$;
do $$ begin create role w267_writer;   exception when duplicate_object then null; end $$;
do $$ begin create role w267_new;      exception when duplicate_object then null; end $$;
do $$ begin create role w267_m1 nosuperuser nobypassrls; exception when duplicate_object then null; end $$;
do $$ begin create role w267_m2 nosuperuser nobypassrls; exception when duplicate_object then null; end $$;
grant usage on schema public to w267_stranger, w267_writer, w267_new;
grant create, usage on schema public to w267_owner, w267_new, w267_m1, w267_m2;
grant usage on schema pgpm to w267_m1, w267_m2;
grant all on all tables in schema pgpm to w267_m1, w267_m2;
grant all on all sequences in schema pgpm to w267_m1, w267_m2;

-- what a role reads of a relation, without letting a 42501 kill the file: null when it is refused
create function pg_temp.w267_reads(p_rel text) returns bigint language plpgsql as $f$
declare v bigint;
begin
  execute format('select count(*) from %s', p_rel) into v;
  return v;
exception when insufficient_privilege then return null;
end $f$;
grant execute on function pg_temp.w267_reads(text) to w267_stranger;

-- ======================================================================================================
-- STAGE A: minted owner-only, and the list is complete
-- ======================================================================================================
create table public.s267 (id bigint primary key, payload text);
insert into public.s267 select g, 'a' || g from generate_series(1, 200) g;
alter table public.s267 owner to w267_owner;
grant insert, update, select on public.s267 to w267_writer;
-- the maintaining role's default privileges, from here on
alter default privileges in schema public grant select on tables to w267_stranger;
create table public.s267_witness (x int);
select ok(has_table_privilege('w267_stranger', 'public.s267_witness', 'SELECT'),
  'LIVENESS: a table this session creates now grants w267_stranger SELECT (the default privilege is in force)');

call pgpm.transmute('public.s267', 'id', 50, p_regrain_batch => 30);
select pgpm.obtain('public.s267');
insert into public.s267 values (1000, 'frontier');   -- the monolith [0, 250) freezes
select ok(not has_table_privilege('w267_stranger', 'public.s267', 'SELECT'),
  'transmute_staging: the converted parent, built under the staging name, grants w267_stranger nothing (it carries the original''s grants)');

create temp table w267_before as
  select oid, 'r' as k from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p')
  union all select oid, 'f' from pg_proc where pronamespace = 'public'::regnamespace;

select is(pgpm.regrain_step('public.s267', 's267_p0000000000000000000_to_0000000000000000250', '50'), 'prepared',
  'LIVENESS: the prepare tick minted change capture');
update public.s267 set payload = 'prep' where id = 7;   -- a captured key before the first copy
-- read right after the prepare tick, before a resuming tick's ownership check (#950) could mend the owner
select pg_get_userbyid(p.proowner) as fn_owner_at_prepare from pg_proc p
 where p.oid = (select regrain_capture_fn_oid from pgpm.config where parent_table = 'public.s267'::regclass) \gset
select is(pgpm.regrain_step('public.s267', 's267_p0000000000000000000_to_0000000000000000250', '50'), 'copied:30',
  'LIVENESS: the next tick copies one batch of 30 of [0, 50) into the first fine child, its sub-range unfinished');

select cfg.regrain_delta_oid as delta, cfg.regrain_capture_fn_oid as fn
  from pgpm.config cfg where cfg.parent_table = 'public.s267'::regclass \gset
select child_oid as fine from pgpm.part where parent_table = 'public.s267'::regclass and not attached \gset

-- THE LIST AGAINST WHAT WAS CREATED: every new relation and function in the parent's schema is a recorded
-- scratch object, and every recorded one is new.
select is(
  (select array_agg(c.oid order by c.oid) from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
      and c.oid not in (select oid from w267_before where k = 'r')),
  (select array_agg(o order by o) from unnest(array[:'delta'::oid, :'fine'::oid]) o),
  'the list is complete: the only relations the regrain created are the recorded delta (regrain_delta) and the recorded copy (regrain_fine_child)');
select is(
  (select array_agg(p.oid order by p.oid) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.oid not in (select oid from w267_before where k = 'f')),
  array[:'fn'::oid],
  'the list is complete: the only function the regrain created is the recorded capture function (regrain_capture_fn)');

select ok(exists (select 1 from public.s267_pgpm_regrain_delta where id = 7),
  'LIVENESS: the delta holds the captured key 7');
select is(pg_temp.w267_reads(:'fine'::regclass::text), 30::bigint,
  'LIVENESS: the fine child holds the 30 copied rows (this superuser reads them)');

select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'delta'::oid), 'w267_owner',
  'regrain_delta: owned like the parent');
select ok(not has_table_privilege('w267_stranger', :'delta'::oid, 'SELECT')
          and not has_table_privilege('w267_stranger', :'delta'::oid, 'INSERT'),
  'regrain_delta: w267_stranger holds nothing on it from the prepare tick on');
select is((select array_agg(distinct pg_get_userbyid(a.grantee)::text || ':' || a.privilege_type)
             from pg_class c cross join lateral aclexplode(c.relacl) a
            where c.oid = :'delta'::oid and a.grantee <> c.relowner),
  array['w267_writer:INSERT'],
  'regrain_delta: its only grant beyond the owner''s is INSERT for the parent''s writer');
set role w267_stranger;
select is(pg_temp.w267_reads('public.s267_pgpm_regrain_delta'), null::bigint,
  'regrain_delta: w267_stranger is refused reading the captured keys');
reset role;
select is(:'fn_owner_at_prepare'::text, 'w267_owner',
  'regrain_capture_fn: owned like the parent from the prepare tick that creates it');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'fine'::oid), 'w267_owner',
  'regrain_fine_child: owned like the parent, mid-copy');
select ok((select relacl is null or not exists (select 1 from aclexplode(relacl) a where a.grantee <> relowner)
             from pg_class where oid = :'fine'::oid),
  'regrain_fine_child: its ACL is the owner''s alone, mid-copy');
set role w267_stranger;
select is(pg_temp.w267_reads(:'fine'::regclass::text), null::bigint,
  'regrain_fine_child: w267_stranger is refused reading the rows copied so far');
reset role;

-- ======================================================================================================
-- STAGE C: the table is handed to w267_new mid-regrain, and this session can re-own (superuser)
-- ======================================================================================================
do $$ declare r record; begin
  execute 'alter table public.s267 owner to w267_new';
  for r in select inhrelid::regclass as t from pg_inherits where inhparent = 'public.s267'::regclass loop
    execute format('alter table %s owner to w267_new', r.t);
  end loop;
end $$;
select ok((select relowner = 'w267_new'::regrole from pg_class where oid = 'public.s267'::regclass)
          and (select relowner = 'w267_owner'::regrole from pg_class where oid = :'delta'::oid)
          and (select relowner = 'w267_owner'::regrole from pg_class where oid = :'fine'::oid),
  'LIVENESS: the parent and its partitions are w267_new''s, the delta and the copy still w267_owner''s');
select max(id) as mark from pgpm.log \gset
select is(pgpm.regrain_step('public.s267', 's267_p0000000000000000000_to_0000000000000000250', '50'), 'copied:19',
  'LIVENESS: the first tick after the hand-over goes on copying');
select is((select array_agg(pg_get_userbyid(relowner)::text order by oid) from pg_class where oid in (:'delta'::oid, :'fine'::oid)),
  array['w267_new', 'w267_new'],
  'regrain_delta, regrain_fine_child: owned like the parent as it is now, after the tick');
select is((select pg_get_userbyid(proowner)::text from pg_proc where oid = :'fn'::oid), 'w267_new',
  'regrain_capture_fn: owned like the parent as it is now, after the tick');

create function public.w267_write_as_new() returns void language plpgsql security definer as $$
begin update public.s267 set payload = 'new-10' where id = 10; delete from public.s267 where id = 120; end $$;
alter function public.w267_write_as_new() owner to w267_new;
select lives_ok('select public.w267_write_as_new()',
  'the table''s new owner updates and deletes rows of the regraining range');
set role w267_writer;
select lives_ok($$ update public.s267 set payload = 'writer-20' where id = 20 $$,
  'the parent''s writer still updates a row of the regraining range (its INSERT on the delta survives the re-own)');
reset role;

create temp table w267_steps (r text);
do $$ declare v text; begin
  for i in 1..40 loop
    v := pgpm.regrain_step('public.s267', (select child_name from pgpm.part where parent_table = 'public.s267'::regclass
                                             and attached order by lo::numeric limit 1), '50');
    insert into w267_steps values (v);
    exit when v like 'swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from w267_steps where r like 'swapped:%'),
  'LIVENESS: the regrain swapped');
select is((select array_agg(method order by id) from pgpm.log
            where id > :mark and parent_table = 'public.s267'::regclass and action = 'skip_regrain'),
  null::text[], 'no tick after the hand-over skipped the regrain');
select is((select array_agg(id || ':' || payload order by id) from public.s267 where id in (7, 9, 10, 11, 19, 20, 21, 119, 120, 121)),
  array['7:prep', '9:a9', '10:new-10', '11:a11', '19:a19', '20:writer-20', '21:a21', '119:a119', '121:a121'],
  'every write survived the swap: the three updates hold, the deleted row is gone, its neighbours untouched');

-- ======================================================================================================
-- STAGE B: what pgpm did not record is never emptied, dropped or adopted
-- ======================================================================================================
create table public.s267b (id bigint primary key, payload text);
insert into public.s267b select g, 'b' || g from generate_series(1, 120) g;
call pgpm.transmute('public.s267b', 'id', 50);
create table public.s267b_pgpm_regrain_delta (note text);
insert into public.s267b_pgpm_regrain_delta values ('operator-a'), ('operator-b');
create function public.s267b_pgpm_regrain_capture() returns trigger language plpgsql as $$ begin return null; end $$;
select 'public.s267b_pgpm_regrain_delta'::regclass::oid as op_delta,
       'public.s267b_pgpm_regrain_capture()'::regprocedure::oid as op_fn \gset
select ok((select regrain_delta_oid is null and regrain_capture_fn_oid is null from pgpm.config
            where parent_table = 'public.s267b'::regclass),
  'LIVENESS: s267b has never regrained, so nothing is recorded, and its derived names are held by the operator''s table and function');
select is(pgpm.regrain_cancel('public.s267b'), 0, 'LIVENESS: regrain_cancel ran on s267b');
select is((select array_agg(note order by note) from public.s267b_pgpm_regrain_delta), array['operator-a', 'operator-b'],
  'regrain_delta: regrain_cancel leaves the operator''s namesake table and its 2 rows alone');
select is(pgpm.untransmute('public.s267b')::text, 's267b', 'LIVENESS: untransmute handed s267b back');
select is((select relkind::text from pg_class where oid = 'public.s267b'::regclass), 'r',
  'LIVENESS: s267b is a plain table again');
select is((select array_agg(note order by note) from public.s267b_pgpm_regrain_delta where tableoid = :'op_delta'::oid),
  array['operator-a', 'operator-b'],
  'regrain_delta: untransmute leaves the operator''s namesake table, the same relation, with its rows');
select is((select oid from pg_proc where oid = :'op_fn'::oid), :'op_fn'::oid,
  'regrain_capture_fn: untransmute leaves the operator''s namesake function');

-- the prepare, against the same two namesakes (#496), then a fine child's name held by the operator (#631)
create table public.s267c (id bigint primary key, payload text);
insert into public.s267c select g, 'c' || g from generate_series(1, 120) g;
call pgpm.transmute('public.s267c', 'id', 50);
insert into public.s267c values (1000, 'frontier');
select pgpm.obtain('public.s267c');
select child_name as cmono from pgpm.part where parent_table = 'public.s267c'::regclass and attached order by lo::numeric limit 1 \gset
create table public.s267c_pgpm_regrain_delta (note text);
insert into public.s267c_pgpm_regrain_delta values ('operator-c');
create function public.s267c_pgpm_regrain_capture() returns trigger language plpgsql as $$ begin return null; end $$;
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.s267c', :'cmono', '10'),
  '%would mint its delta table as public.s267c_pgpm_regrain_delta, and that name is held by relation%',
  'regrain_delta: the prepare refuses to mint under the operator''s table (#496)');
select is((select array_agg(note) from public.s267c_pgpm_regrain_delta), array['operator-c'],
  'regrain_delta: the operator''s table keeps its row');
drop table public.s267c_pgpm_regrain_delta;
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.s267c', :'cmono', '10'),
  '%would mint its trigger function as public.s267c_pgpm_regrain_capture(), and that name is held by function%',
  'regrain_capture_fn: the prepare refuses to mint over the operator''s function (#496)');
drop function public.s267c_pgpm_regrain_capture();
select is(pgpm.regrain_step('public.s267c', :'cmono', '10'), 'prepared', 'LIVENESS: with the names free, s267c''s regrain prepares');
create table public.s267c_p0000000000000000000 (note text);
insert into public.s267c_p0000000000000000000 values ('operator-fine');
select throws_like(format('select pgpm.regrain_step(%L, %L, %L)', 'public.s267c', :'cmono', '10'),
  '%already exists and this regrain did not create it%',
  'regrain_fine_child: a copy is never made into the operator''s table under its name (#631)');
select is((select array_agg(note) from public.s267c_p0000000000000000000), array['operator-fine'],
  'regrain_fine_child: the operator''s table keeps its row');

-- transmute_staging: the staging name held by the operator's table (#344)
create table public.s267d (id bigint primary key, payload text);
insert into public.s267d select g, 'd' || g from generate_series(1, 30) g;
create table public.s267d_pgpm_new (note text);
insert into public.s267d_pgpm_new values ('operator-staging');
select throws_like($$ call pgpm.transmute('public.s267d', 'id', 50) $$,
  '%s267d_pgpm_new already exists, and transmute needs it as a staging name%',
  'transmute_staging: transmute refuses the operator''s table under its staging name');
select is((select array_agg(note) from public.s267d_pgpm_new), array['operator-staging'],
  'transmute_staging: the operator''s table keeps its row');

-- ======================================================================================================
-- STAGE D: handed over, and the tick's role can neither re-own nor act as the old owner
-- ======================================================================================================
set role w267_m1;
create table public.s267e (id bigint primary key, payload text);
insert into public.s267e select g, 'e' || g from generate_series(1, 200) g;
call pgpm.transmute('public.s267e', 'id', 100, p_obtain => 3, p_regrain_batch => 1000, p_paused => false);
select pgpm.obtain('public.s267e');
insert into public.s267e values (450, 'frontier');
select pgpm.set_regrain('public.s267e', '50');
call pgpm.maintain('public.s267e');   -- the owner's prepare tick
reset role;
select ok((select pg_get_userbyid(relowner) = 'w267_m1' from pg_class
            where oid = (select regrain_delta_oid from pgpm.config where parent_table = 'public.s267e'::regclass)),
  'LIVENESS: w267_m1''s prepare tick minted the delta, owned like the parent');
do $$ declare r record; begin
  execute 'alter table public.s267e owner to w267_m2';
  for r in select inhrelid::regclass as t from pg_inherits where inhparent = 'public.s267e'::regclass loop
    execute format('alter table %s owner to w267_m2', r.t);
  end loop;
end $$;
select ok(not pg_has_role('w267_m2', 'w267_m1', 'USAGE') and not (select rolsuper from pg_roles where rolname = 'w267_m2'),
  'LIVENESS: w267_m2 is no superuser and holds nothing of w267_m1''s');
select max(id) as mark_d from pgpm.log \gset
set role w267_m2;
call pgpm.maintain('public.s267e');
reset role;
select is((select array_agg(method order by id) from pgpm.log
            where id > :mark_d and parent_table = 'public.s267e'::regclass and action = 'skip_regrain'),
  array[left('pg_partition_magician: run select pgpm.hand_over_scratch(''public.s267e'') as a superuser or a member of both w267_m1 and w267_m2: the regrain of s267e cannot go on while pgpm''s scratch objects for it are owned by w267_m1, not by the table''s owner w267_m2', 200)],
  'the new owner''s tick refuses once, up front, leading with the hand-over step, rather than failing permission denied on the delta');
select throws_like('select pgpm.hand_over_scratch(null)', '%hand_over_scratch does not accept null for p_parent%',
  'the hand-over step refuses a null table');
select is(pgpm.hand_over_scratch('public.s267e'), 2, 'the remedy hands the delta and the capture function to w267_m2');
select ok((select relowner = 'w267_m2'::regrole from pg_class
            where oid = (select regrain_delta_oid from pgpm.config where parent_table = 'public.s267e'::regclass))
          and (select proowner = 'w267_m2'::regrole from pg_proc
                where oid = (select regrain_capture_fn_oid from pgpm.config where parent_table = 'public.s267e'::regclass)),
  'both are w267_m2''s after the remedy');
select max(id) as mark_e from pgpm.log \gset
set role w267_m2;
call pgpm.maintain('public.s267e');
reset role;
select is((select array_agg(action order by id) from pgpm.log
            where id > :mark_e and parent_table = 'public.s267e'::regclass and action in ('skip_regrain', 'regrain_copy')),
  array['regrain_copy'], 'after the remedy, the new owner''s tick copies and skips nothing');

select * from finish();
