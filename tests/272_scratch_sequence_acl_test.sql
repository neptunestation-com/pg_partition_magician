-- The scratch-relation lever reaches the sequences a scratch relation owns (issue #974; the lever of #966).
--
-- _scratch_mint gives a scratch relation the parent's owner and an owner-only ACL in the transaction that
-- creates it (tests/267). The regrain delta also OWNS a relation: `pgpm_seq bigint generated always as
-- identity` makes the sequence <delta>_pgpm_seq_seq, born like the delta with the minting role's ALTER
-- DEFAULT PRIVILEGES (on Supabase, `grant all on sequences to anon, authenticated` is exactly this shape).
-- The mint reset the delta's ACL and not the sequence's, so a role holding nothing on the managed table could
-- setval it; pgpm_seq is the identity the reconcile addresses delta rows by (#497), duplicated values made one
-- tick apply a not-yet-eligible key into the sub-range being copied and consume it, and the swap dropped rows
-- 60..89 with the source. Ownership is not a separate concern: PostgreSQL refuses to re-own an identity
-- sequence by itself and ALTER TABLE ... OWNER carries it, so the sequence follows its table's owner, and
-- STAGE C witnesses that it does through a hand-over.
--
-- STAGE A, minted. The maintaining role (this session) holds ALTER DEFAULT PRIVILEGES granting ALL on new
-- sequences to w272_stranger, which holds nothing on the parent. After the prepare tick, the only sequence the
-- regrain created is the recorded delta's pgpm_seq sequence (a sequence any later scratch relation owns fails
-- here as an omission), and every sequence a recorded scratch relation owns is the parent's owner's with no
-- grant to anyone else. LIVENESS: a sequence this session creates gets the stranger's grant.
-- STAGE B, the row loss (the issue's reproduction, as the identity assertion). With the copy of [50, 100)
-- part-way (ids 50..59) and one change behind the cursor (id 10), the stranger tries to rewind the sequence,
-- then a change ahead of the cursor (id 90). The setval is refused, the four captured rows carry four
-- distinct pgpm_seq values, and after the swap rows 60..89 (which nothing changed) are there, as are both
-- changes. LIVENESS: the copy is part-way, the delta holds the captured keys, the regrain swapped.
-- STAGE C, owned like the parent. The parent and its partitions are handed to w272_new mid-regrain; the next
-- tick re-owns the delta (_scratch_owner_follow) and the sequence goes with it, still owner-only.
--
-- ASYMMETRIC: rows 1..260 and a frontier row 450; one change behind the cursor, one ahead of it; the rows
-- checked at the end are 60..89, which nothing touches. bench/scratch_sequences.sh runs this file against
-- the mutation scratch_mint_sequence_default_acl, which it must FAIL.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(15);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w272_owner') then create role w272_owner; end if;
  if not exists (select 1 from pg_roles where rolname = 'w272_stranger') then create role w272_stranger; end if;
  if not exists (select 1 from pg_roles where rolname = 'w272_new') then create role w272_new; end if;
end $$;
grant usage on schema public to w272_stranger;
grant create, usage on schema public to w272_owner, w272_new;

-- the stranger's setval of p_seq back to 1: 'ok' when it went through, the SQLSTATE when it was refused
create function pg_temp.w272_setval(p_seq text) returns text language plpgsql as $f$
begin
  perform setval(p_seq::regclass, 1, false);
  return 'ok';
exception when insufficient_privilege then return sqlstate;
end $f$;
grant execute on function pg_temp.w272_setval(text) to w272_stranger;

-- every sequence a recorded scratch relation of p_parent owns, with the roles it grants anything to besides
-- its owner, as 'seq:role,role' (an owner-only sequence reads 'seq:')
create function pg_temp.w272_scratch_seq_grants(p_parent regclass) returns text[] language sql as $f$
  select array_agg(s.oid::regclass::text || ':'
                   || coalesce((select string_agg(distinct pg_get_userbyid(a.grantee)::text, ',')
                                  from aclexplode(s.relacl) a where a.grantee <> s.relowner), '')
                   order by s.oid)
    from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S'
   where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
     and d.refobjid in (select unnest(o.rels) from pgpm._scratch_objects(p_parent) o);
$f$;

-- ======================================================================================================
-- STAGE A: the delta's sequence minted owner-only, and the only sequence the regrain created
-- ======================================================================================================
create table public.s272 (id bigint primary key, note text);
insert into public.s272 select g, 'n' || g from generate_series(1, 260) g;
alter table public.s272 owner to w272_owner;
call pgpm.transmute('public.s272', 'id', 100, p_obtain => 3, p_paused => true);
select pgpm.obtain('public.s272') as obtained \gset
insert into public.s272 values (450, 'frontier');   -- the monolith [0, 300) freezes
select child_name as src from pgpm.part
 where parent_table = 'public.s272'::regclass and attached and lo = '0' \gset

-- the maintaining role's default privileges, from here on
alter default privileges in schema public grant all on sequences to w272_stranger;
create sequence public.s272_witness_seq;
select ok(has_sequence_privilege('w272_stranger', 'public.s272_witness_seq', 'UPDATE')
          and not has_table_privilege('w272_stranger', 'public.s272', 'SELECT,INSERT,UPDATE,DELETE'),
  'LIVENESS: a sequence this session creates now grants w272_stranger UPDATE, and w272_stranger holds nothing on s272');
create temp table w272_before as
  select oid from pg_class where relnamespace = 'public'::regnamespace and relkind = 'S';

select is(pgpm.regrain_step('public.s272', :'src', '50', 10), 'prepared',
  'LIVENESS: the prepare tick minted change capture');
select regrain_delta_oid as delta from pgpm.config where parent_table = 'public.s272'::regclass \gset
select pg_get_serial_sequence(:'delta'::regclass::text, 'pgpm_seq')::regclass::oid as seq \gset

select is((select array_agg(c.oid order by c.oid) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
              and c.oid not in (select oid from w272_before)),
  array[:'seq'::oid],
  'the list is complete: the only sequence the regrain created is the recorded delta''s pgpm_seq sequence');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'seq'::oid), 'w272_owner',
  'regrain_delta''s pgpm_seq sequence: owned like the parent from the prepare tick on');
select is(pg_temp.w272_scratch_seq_grants('public.s272'),
  array[:'seq'::oid::regclass::text || ':'],
  'every sequence a scratch relation of s272 owns grants nothing beyond its owner''s from the tick that creates it');

-- copy [0, 50) whole and the first 10 rows of [50, 100)
do $$ begin
  for i in 1 .. 20 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.s272'::regclass) = '50';
    perform pgpm.regrain_step('public.s272', (select child_name from pgpm.part
                                               where parent_table = 'public.s272'::regclass and attached and lo = '0'), '50', 10);
  end loop;
end $$;
select pgpm.regrain_step('public.s272', :'src', '50', 10) as step50 \gset
select child_oid as copy50 from pgpm.part
 where parent_table = 'public.s272'::regclass and not attached and lo = '50' and hi = '100' \gset

-- ======================================================================================================
-- STAGE B: the stranger cannot rewind the sequence, and the swap keeps every row
-- ======================================================================================================
create function pg_temp.w272_ids(p_rel regclass) returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  execute format('select array_agg(id order by id) from %s', p_rel) into v;
  return v;
end $f$;
select is(pg_temp.w272_ids(:'copy50'::regclass), array[50,51,52,53,54,55,56,57,58,59]::bigint[],
  'LIVENESS: the copy of [50, 100) is part-way (ids 50..59)');

update public.s272 set note = 'u10' where id = 10;   -- behind the cursor
set role w272_stranger;
select pg_temp.w272_setval(:'seq'::oid::regclass::text) as setval_by_stranger \gset
reset role;
update public.s272 set note = 'u90' where id = 90;   -- ahead of it

select is(:'setval_by_stranger'::text, '42501',
  'a role holding nothing on s272 is refused setval on the regrain delta''s pgpm_seq sequence');
select is((select array_agg(id::text order by id) from public.s272_pgpm_regrain_delta),
  array['10', '10', '90', '90'],
  'LIVENESS: the delta holds the two changes'' captured keys, old and new row each');
select is((select array_agg(pgpm_seq) from (select pgpm_seq from public.s272_pgpm_regrain_delta
                                              group by pgpm_seq having count(*) > 1) d),
  null, 'the four captured rows carry four distinct pgpm_seq values');

-- ======================================================================================================
-- STAGE C: handed to w272_new mid-regrain, the sequence follows the delta and stays owner-only
-- ======================================================================================================
do $$ declare r record; begin
  execute 'alter table public.s272 owner to w272_new';
  for r in select inhrelid::regclass as t from pg_inherits where inhparent = 'public.s272'::regclass loop
    execute format('alter table %s owner to w272_new', r.t);
  end loop;
end $$;
select pgpm.regrain_step('public.s272', :'src', '50', 10) as handed_tick \gset
select matches(:'handed_tick'::text, '^(reconciled|copied):[0-9]+$',
  'LIVENESS: the next tick, as the superuser, goes on (it reconciles or copies rather than skipping or refusing)');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'delta'::oid) || '/'
          || (select pg_get_userbyid(relowner)::text from pg_class where oid = :'seq'::oid),
  'w272_new/w272_new', 'the tick re-owned the delta, and its pgpm_seq sequence went with it');
select is(pg_temp.w272_scratch_seq_grants('public.s272'),
  array[:'seq'::oid::regclass::text || ':'],
  'after the hand-over the delta''s pgpm_seq sequence still grants nothing beyond its owner''s');

-- drive the run to its swap
do $$ declare v text; begin
  for i in 1 .. 200 loop
    v := pgpm.regrain_step('public.s272', (select child_name from pgpm.part
                                            where parent_table = 'public.s272'::regclass and attached and lo = '0'), '50', 10);
    exit when v like 'swapped:%';
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.s272'::regclass and action = 'regrain' and lo = '0')
          and to_regclass('public.' || :'src') is null,
  'LIVENESS: the regrain swapped and dropped the source');
select is((select array_agg(g order by g) from generate_series(60, 89) g
            where not exists (select 1 from public.s272 where id = g)),
  null, 'rows 60..89, which nothing changed, are still in the table after the swap');
select is((select array_agg(id || ':' || note order by id) from public.s272 where id in (10, 90)),
  array['10:u10', '90:u90'], 'both changes survived the swap, the one behind the cursor and the one ahead of it');

-- the roles are cluster-wide: leave none behind
reset role;
alter default privileges in schema public revoke all on sequences from w272_stranger;
drop table public.s272 cascade;
drop sequence public.s272_witness_seq;
drop owned by w272_owner, w272_stranger, w272_new;
drop role w272_owner;
drop role w272_stranger;
drop role w272_new;

select * from finish();
