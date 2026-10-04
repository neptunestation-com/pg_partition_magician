-- untransmute hands a PRIMARY KEY made on the managed table since the conversion back under the name the
-- managed table gave it (issue #901).
--
-- ADD PRIMARY KEY on a partitioned table clones onto each partition under an auto-name of the partition's
-- (<monolith>_pkey), the DETACH keeps it, and the DROP takes the parent's, which held the name every
-- statement uses. #830's hand-back renames each such clone to its parent index's name, but it skipped every
-- primary-key index (`not mi.indisprimary`), meant for one case only: a conversion from before #789, whose
-- parent key PostgreSQL auto-named while the monolith kept the table's original key under its original name.
-- So a key added after converting a keyless table came back as <monolith>_pkey and ON CONFLICT ON CONSTRAINT
-- <its name> failed with 42704 on the restored table.
--
-- Now a primary key is handed back when the monolith's copy carries the name PostgreSQL chose for a clone on
-- the monolith (ChooseRelationName(<monolith>, NULL, 'pkey'): <monolith>_pkey, _pkey1, ..., the monolith's
-- name clipped so the whole fits 63 bytes). The original key of a pre-#789 conversion carries the name the
-- table gave it before it was the monolith, so it still keeps it (tests/221 part B holds that). Fixtures,
-- each a different shape so a mutant that hands back one and not another fails a different assertion:
--   (A) ka257: a keyless table, an explicitly named key ka257_pk added since, and a secondary index made since
--       as the witness that the hand-back ran, 5 rows;
--   (B) kb257: a keyed table whose managed key was dropped and replaced by an anonymous one on other columns
--       (the parent's kb257_pkey, the monolith's kb257_p<label>_pkey), 3 rows;
--   (C) a 40-byte table name, so the monolith's clone name is the monolith's clipped to 58 bytes plus _pkey,
--       not the whole name plus _pkey, 2 rows.
-- bench/untransmute_primary_key_name.sh runs this file against two mutants (the pre-fix filter, and the
-- clone-name test without the clip), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(17);

-- ==================== (A) a keyless table, a named key added since ====================
create table public.ka257 (id bigint not null, v int not null, w text);
insert into public.ka257 select g, g * 10, 'w' || g from generate_series(1, 5) g;
call pgpm.transmute('public.ka257', 'id', 100::bigint, p_obtain => 2);
select monolith_oid as ka_mon from pgpm.config where parent_table = 'public.ka257'::regclass \gset
-- the operator's migrations, run against the managed table after the conversion
alter table public.ka257 add constraint ka257_pk primary key (id, v);
create index ka257_w_idx on public.ka257 (w);
select c.conindid as ka_clone, ic.relname as ka_clone_name
  from pg_constraint c join pg_class ic on ic.oid = c.conindid
 where c.conrelid = :ka_mon and c.contype = 'p' \gset
select is((select conname::text from pg_constraint where conrelid = 'public.ka257'::regclass and contype = 'p'),
  'ka257_pk', 'A LIVENESS: the managed table''s primary key is ka257_pk');
select is(:'ka_clone_name'::text, (select relname::text from pg_class where oid = :ka_mon) || '_pkey',
  'A LIVENESS: the monolith''s copy of it carries the clone''s auto-name, <monolith>_pkey');
select lives_ok($$ insert into public.ka257 values (2, 20, 'dup') on conflict on constraint ka257_pk do nothing $$,
  'A LIVENESS: ON CONFLICT ON CONSTRAINT ka257_pk works on the managed table');

select is(pgpm.untransmute('public.ka257')::text, 'ka257', 'A LIVENESS: ka257 is restored');
select is((select c.relname::text from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.ka257'::regclass and not i.indisprimary),
  'ka257_w_idx', 'A LIVENESS: the secondary index made since came back as ka257_w_idx (the hand-back ran)');
select is((select conname::text || ' ' || (conindid = :ka_clone)::text from pg_constraint
            where conrelid = 'public.ka257'::regclass and contype = 'p'),
  'ka257_pk true', 'A: the primary key made since comes back as ka257_pk, the monolith''s own copy renamed in place');
select lives_ok($$ insert into public.ka257 values (2, 20, 'dup') on conflict on constraint ka257_pk do nothing $$,
  'A: ON CONFLICT ON CONSTRAINT ka257_pk runs on the restored table');
select is((select array_agg(id::text || ':' || coalesce(w, '-') order by id) from public.ka257),
  array['1:w1', '2:w2', '3:w3', '4:w4', '5:w5'],
  'A: and the conflicts did nothing, so the restored table holds exactly its five rows');

-- ==================== (B) a keyed table whose key was replaced by an anonymous one ====================
create table public.kb257 (id bigint primary key, v int not null);
insert into public.kb257 select g, g from generate_series(1, 3) g;
call pgpm.transmute('public.kb257', 'id', 100::bigint, p_obtain => 2);
select monolith_oid as kb_mon from pgpm.config where parent_table = 'public.kb257'::regclass \gset
alter table public.kb257 drop constraint kb257_pkey;
alter table public.kb257 add primary key (v, id);
select is((select conname::text from pg_constraint where conrelid = 'public.kb257'::regclass and contype = 'p'),
  'kb257_pkey', 'B LIVENESS: the managed table''s new key took PostgreSQL''s name for it, kb257_pkey');
select is((select ic.relname::text from pg_constraint c join pg_class ic on ic.oid = c.conindid
            where c.conrelid = :kb_mon and c.contype = 'p'),
  (select relname::text from pg_class where oid = :kb_mon) || '_pkey',
  'B LIVENESS: and the monolith''s copy the clone''s auto-name');
select is(pgpm.untransmute('public.kb257')::text, 'kb257', 'B LIVENESS: kb257 is restored');
select is((select conname::text || ' ' || pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.kb257'::regclass and contype = 'p'),
  'kb257_pkey PRIMARY KEY (v, id)', 'B: the replacement key comes back as kb257_pkey, on (v, id)');

-- ==================== (C) a long name: the clone's is the monolith's clipped ====================
create table public.kc257_forty_bytes_of_table_name_abcdefgh (id bigint not null, v int not null);
insert into public.kc257_forty_bytes_of_table_name_abcdefgh values (1, 1), (2, 2);
call pgpm.transmute('public.kc257_forty_bytes_of_table_name_abcdefgh', 'id', 100::bigint, p_obtain => 2);
select monolith_oid as kc_mon from pgpm.config
 where parent_table = 'public.kc257_forty_bytes_of_table_name_abcdefgh'::regclass \gset
alter table public.kc257_forty_bytes_of_table_name_abcdefgh add constraint kc257_pk primary key (id);
select is(octet_length('kc257_forty_bytes_of_table_name_abcdefgh'), 40, 'C LIVENESS: the table''s name is 40 bytes');
select ok(octet_length((select relname from pg_class where oid = :kc_mon)) > 58,
  'C LIVENESS: the monolith''s name is too long for <monolith>_pkey to fit 63 bytes');
select is((select ic.relname::text from pg_constraint c join pg_class ic on ic.oid = c.conindid
            where c.conrelid = :kc_mon and c.contype = 'p'),
  left((select relname::text from pg_class where oid = :kc_mon), 58) || '_pkey',
  'C LIVENESS: so the monolith''s copy is the monolith''s name clipped to 58 bytes, plus _pkey');
select is(pgpm.untransmute('public.kc257_forty_bytes_of_table_name_abcdefgh')::text,
  'kc257_forty_bytes_of_table_name_abcdefgh', 'C LIVENESS: the long-named table is restored');
select is((select conname::text from pg_constraint
            where conrelid = 'public.kc257_forty_bytes_of_table_name_abcdefgh'::regclass and contype = 'p'),
  'kc257_pk', 'C: the key made since comes back as kc257_pk');

select * from finish();
