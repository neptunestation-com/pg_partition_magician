-- untransmute hands back the indexes and index-backed constraints made on the managed table since the
-- conversion under the names the managed table gave them (issue #830).
--
-- ADD CONSTRAINT ... UNIQUE and CREATE [UNIQUE] INDEX on a partitioned table clone onto every partition
-- under an auto-name of the partition's (nx221_p<label>_code_k_key). The DETACH keeps those names and the
-- DROP takes the parent's, which held the names every statement uses, and #789's reverse renamed back only
-- the reused key, found by its pgpm_key_<oid> identity. So after a reverse ON CONFLICT ON CONSTRAINT
-- <the constraint's name> failed with 42704 and DROP INDEX <the index's name> found nothing.
--
-- Now every index of the monolith attached under one of the parent's is handed that index's name, found by
-- that identity before the DETACH removes it, with two deliberate exceptions, each with its own part here:
--   (A) nx221: three made since the conversion (a UNIQUE constraint, a plain index, a bare unique index),
--       each a different kind, so a reverse that renames only constraints or only indexes fails one; and
--       a secondary index transmute carried (step 9b, whose parent copy is <name>_pgpm), which must keep
--       the table's own name rather than take the copy's.
--   (B) lg221: the shape a conversion from before #789 left, its parent's key auto-named lg221_pkey1 and
--       the monolith keeping the original lg221_pkey. That key keeps its name, as #789 decided, while an
--       index made since the conversion on the same table is still handed its own.
-- bench/untransmute_index_names.sh runs this file against three mutants, one per rule, so it is also
-- required to FAIL there.
create extension if not exists pgtap;
select plan(16);

-- ==================== (A) indexes and constraints made on the managed table ====================
create table public.nx221 (k bigint primary key, code int not null, v text not null, w text);
create index nx221_w_idx on public.nx221 (w);
insert into public.nx221 select g, g * 10, 'v' || g, 'w' || g from generate_series(1, 7) g;
select oid as w_idx from pg_class where relname = 'nx221_w_idx' and relnamespace = 'public'::regnamespace \gset
call pgpm.transmute('public.nx221', 'k', 100::bigint, p_obtain => 2);
select monolith_oid as nx_mon from pgpm.config where parent_table = 'public.nx221'::regclass \gset
-- the operator's migrations, run against the managed table after the conversion
alter table public.nx221 add constraint nx221_code_uq unique (code, k);
create index nx221_v_idx on public.nx221 (v);
create unique index nx221_vk_uidx on public.nx221 (v, k);

-- the monolith's copy of each, by identity: the index attached under the parent's of that name
create temporary table nx_clone as
  select pc.relname::text as parent_name, h.inhrelid as clone_oid, mc.relname::text as clone_name
    from pg_inherits h join pg_class pc on pc.oid = h.inhparent join pg_class mc on mc.oid = h.inhrelid
   where pc.relname in ('nx221_code_uq', 'nx221_v_idx', 'nx221_vk_uidx', 'nx221_w_idx_pgpm')
     and (select indrelid from pg_index where indexrelid = h.inhrelid) = :nx_mon;
select is((select array_agg(parent_name order by parent_name) from nx_clone),
  array['nx221_code_uq', 'nx221_v_idx', 'nx221_vk_uidx', 'nx221_w_idx_pgpm'],
  'A LIVENESS: each of the parent''s indexes has its copy on the monolith');
select ok((select bool_and(clone_name <> parent_name) from nx_clone where parent_name <> 'nx221_w_idx_pgpm'),
  'A LIVENESS: the three made since the conversion sit on the monolith under names that are not the parent''s');
select is((select clone_oid from nx_clone where parent_name = 'nx221_w_idx_pgpm'), :w_idx::oid,
  'A LIVENESS: the carried index''s copy is the table''s original nx221_w_idx');
select lives_ok($$ insert into public.nx221 values (3, 30, 'dup', null) on conflict on constraint nx221_code_uq do nothing $$,
  'A LIVENESS: ON CONFLICT ON CONSTRAINT nx221_code_uq works on the managed table');

select is(pgpm.untransmute('public.nx221')::text, 'nx221', 'A LIVENESS: nx221 is restored');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.nx221'::regclass),
  array['nx221_code_uq', 'nx221_pkey', 'nx221_v_idx', 'nx221_vk_uidx', 'nx221_w_idx'],
  'A: the restored table''s indexes carry the names the managed table''s did, and the carried one its own');
select is((select array_agg(n.parent_name order by n.parent_name) from nx_clone n join pg_class c on c.oid = n.clone_oid
            where c.relname::text = n.parent_name),
  array['nx221_code_uq', 'nx221_v_idx', 'nx221_vk_uidx'],
  'A: each is the monolith''s own copy, renamed in place, not a rebuild');
select is((select relname::text from pg_class where oid = :w_idx), 'nx221_w_idx',
  'A: the carried index is the original under its own name, not its parent copy''s nx221_w_idx_pgpm');
select is((select array_agg(conname::text order by conname) from pg_constraint
            where conrelid = 'public.nx221'::regclass and contype in ('p', 'u')),
  array['nx221_code_uq', 'nx221_pkey'], 'A: the unique constraint is nx221_code_uq again');
select lives_ok($$ insert into public.nx221 values (4, 40, 'dup', null) on conflict on constraint nx221_code_uq do nothing $$,
  'A: ON CONFLICT ON CONSTRAINT nx221_code_uq runs on the restored table');
select is((select array_agg(k::text || ':' || v order by k) from public.nx221),
  array['1:v1', '2:v2', '3:v3', '4:v4', '5:v5', '6:v6', '7:v7'],
  'A: and the conflicts did nothing, so the restored table holds exactly its seven rows');
select lives_ok($$ drop index public.nx221_v_idx $$, 'A: DROP INDEX nx221_v_idx finds the index');
select is((select count(*)::int from pg_index where indrelid = 'public.nx221'::regclass), 4,
  'A: and dropped it, leaving the other four');

-- ==================== (B) a key from a conversion that predates #789 ====================
create table public.lg221 (k bigint primary key, v text not null);
insert into public.lg221 select g, 'l' || g from generate_series(1, 4) g;
select conindid as lg_key from pg_constraint where conrelid = 'public.lg221'::regclass and contype = 'p' \gset
call pgpm.transmute('public.lg221', 'k', 100::bigint, p_obtain => 2);
-- the pre-#789 shape: the parent's key auto-named, the monolith's copy under the original name
alter table public.lg221 rename constraint lg221_pkey to lg221_pkey1;
select format('alter table %s rename constraint %I to lg221_pkey',
              (select monolith_oid from pgpm.config where parent_table = 'public.lg221'::regclass)::regclass, 'pgpm_key_' || :lg_key) as legacy
\gset
:legacy;
create index lg221_v_idx on public.lg221 (v);
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = (select monolith_oid from pgpm.config where parent_table = 'public.lg221'::regclass)
              and i.indisprimary)
           || (select array_agg(conname::text) from pg_constraint where conrelid = 'public.lg221'::regclass and contype = 'p'),
  array['lg221_pkey', 'lg221_pkey1'],
  'B LIVENESS: the monolith''s key is the original lg221_pkey and the parent''s is the auto-named lg221_pkey1');
select is(pgpm.untransmute('public.lg221')::text, 'lg221', 'B LIVENESS: lg221 is restored');
select is((select array_agg(c.relname::text || ' ' || (c.oid = :lg_key)::text order by c.relname)
             from pg_index i join pg_class c on c.oid = i.indexrelid where i.indrelid = 'public.lg221'::regclass),
  array['lg221_pkey true', 'lg221_v_idx false'],
  'B: the original key keeps the name it always had, and the index made since takes the name the managed table gave it');

select * from finish();
