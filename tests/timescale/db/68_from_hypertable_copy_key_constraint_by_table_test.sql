-- from_hypertable_copy named the key index it pre-builds after the wrong constraint (issue #1266, F6-02). With
-- p_track_changes the copy builds the reused key's index on its destination under <conname>_pgpm_new, which the
-- cutover adopts instead of building the key again (#175: one key-index build instead of two). It took the
-- conname from `pg_constraint where conindid = <the key's index>` alone. An INCOMING foreign key that
-- references the key carries the same conindid, so when its catalog row came first the copy built
-- <fk name>_pgpm_new; the cutover asked for <key name>_pgpm_new, did not find it, built the key a second time,
-- and the copy's index survived the swap as a stray redundant UNIQUE index, carried by transmute onto the
-- parent and every partition. The copy now asks for the hypertable's own key: conrelid = the hypertable and
-- contype 'p' or 'u', as well as the index.
--
-- The cutover made the same read in the other direction (part C). It carries, as a secondary index, every
-- index of the hypertable that "no constraint sits on", and asked that of the index alone. An incoming foreign
-- key sits on whichever unique index PostgreSQL resolved its columns to, which is a BARE unique index when one
-- on the same columns is older than the key. That index then counted as a key's, no loop built it, and the
-- migrated table lost it silently (transmute alone carries it). The cutover now asks whether one of the
-- hypertable's OWN primary key or unique constraints sits on the index, the set its key loop builds.
--
-- ASYMMETRIC FIXTURE. Part A's key is a PRIMARY KEY (50 rows, ids 1 to 50, one incoming key); part B's is a
-- UNIQUE constraint on a table with no primary key (30 rows, ids 101 to 130, one incoming key, and a secondary
-- index of its own). In each, RENAME CONSTRAINT on the key rewrites its catalog row, so the incoming key's row
-- comes first in a bare read of the constraints on the key's index. Part C's table (20 rows, ids 201 to 220,
-- an append-only copy) has a bare unique index on (ts, id) older than its primary key on (id, ts), a plain
-- index, and an incoming key that PostgreSQL resolved to the bare index.
-- WITNESSES: both constraints sit on the key's index and a bare read meets the incoming key first (the state
-- the defect needs); C's incoming key sits on the bare index and not on the key's; the cutover migrated every
-- row by id and handed the table to transmute; the incoming key was restored against the new parent. The
-- checks name the index the copy built, by oid, the one key index the migrated parent carries, and (C) each
-- index the migrated parent carries with the columns of the one that was lost.
select plan(19);

-- PART A: a primary key, referenced by an incoming foreign key.
create table public.a68 (id int not null, ts timestamptz not null, v int, constraint a68_pk primary key (id, ts));
select create_hypertable('public.a68', 'ts', chunk_time_interval => interval '1 day');
insert into public.a68 select g, '2026-10-01'::timestamptz + make_interval(hours => g), g from generate_series(1, 50) g;
create table public.a68_ref (rid int primary key, id int, ts timestamptz,
  constraint a68_ref_fk foreign key (id, ts) references public.a68 (id, ts));
insert into public.a68_ref values (1, 5, '2026-10-01'::timestamptz + interval '5 hours');
alter table public.a68 rename constraint a68_pk to a68_pkey;
select indexrelid as a_key_idx from pg_index where indrelid = 'public.a68'::regclass and indisprimary \gset

select is((select array_agg(conname::text order by conname) from pg_constraint where conindid = :a_key_idx),
          array['a68_pkey', 'a68_ref_fk'],
          'LIVENESS: A''s primary key index backs both its own key and the incoming foreign key');
select is((select conname::text from pg_constraint where conindid = :a_key_idx limit 1), 'a68_ref_fk',
          'LIVENESS: a bare read of the constraints on A''s key index meets the incoming foreign key first');

call pgpm.from_hypertable_copy('public.a68', 'ts', true);

select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = to_regclass('public.a68_pgpm_dest')),
          array['a68_pkey_pgpm_new'],
          'A''s tracking copy pre-built the primary key''s index under the primary key''s temp name, and nothing else');
select i.indexrelid as a_pre_idx from pg_index i where i.indrelid = to_regclass('public.a68_pgpm_dest') \gset

call pgpm.from_hypertable_cutover('public.a68', 'ts', interval '1 day', p_paused => false);

select ok((select array_agg(id order by id) from public.a68) = (select array_agg(g order by g) from generate_series(1, 50) g)
          and exists (select 1 from pgpm.config where parent_table = 'public.a68'::regclass),
          'LIVENESS: A''s cutover migrated rows 1 to 50 and handed the table to transmute');
select is((select c.conname::text from pg_constraint c where c.conindid = :a_pre_idx and c.contype = 'p'),
          'pgpm_key_' || :a_pre_idx,
          'the index A''s copy built is the migrated table''s key index (adopted, not rebuilt)');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.a68'::regclass and i.indisunique),
          array['a68_pkey'],
          'A''s migrated parent carries one unique index, its primary key (no stray copy-built duplicate)');
select is((select c.confrelid::regclass::text from pg_constraint c
            where c.conrelid = 'public.a68_ref'::regclass and c.conname = 'a68_ref_fk' and c.contype = 'f'),
          'a68', 'LIVENESS: A''s incoming foreign key was restored against the migrated parent');

-- PART B: a unique constraint on a table with no primary key, referenced by an incoming foreign key.
create table public.b68 (id int not null, ts timestamptz not null, v int,
  constraint b68_k unique (id, ts));
select create_hypertable('public.b68', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false);
create index b68_v_idx on public.b68 (v);
insert into public.b68 select g, '2026-10-01'::timestamptz + make_interval(hours => g - 100), g from generate_series(101, 130) g;
create table public.b68_ref (rid int primary key, id int, ts timestamptz,
  constraint b68_ref_fk foreign key (id, ts) references public.b68 (id, ts));
insert into public.b68_ref values (1, 107, '2026-10-01'::timestamptz + interval '7 hours'),
                                  (2, 112, '2026-10-01'::timestamptz + interval '12 hours');
alter table public.b68 rename constraint b68_k to b68_id_ts_key;
select conindid as b_key_idx from pg_constraint where conrelid = 'public.b68'::regclass and contype = 'u' \gset

select is((select array_agg(conname::text order by conname) from pg_constraint where conindid = :b_key_idx),
          array['b68_id_ts_key', 'b68_ref_fk'],
          'LIVENESS: B''s unique constraint index backs both its own key and the incoming foreign key');
select is((select conname::text from pg_constraint where conindid = :b_key_idx limit 1), 'b68_ref_fk',
          'LIVENESS: a bare read of the constraints on B''s key index meets the incoming foreign key first');

call pgpm.from_hypertable_copy('public.b68', 'ts', true);

select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = to_regclass('public.b68_pgpm_dest')),
          array['b68_id_ts_key_pgpm_new'],
          'B''s tracking copy pre-built the unique constraint''s index under its temp name, and nothing else');
select i.indexrelid as b_pre_idx from pg_index i where i.indrelid = to_regclass('public.b68_pgpm_dest') \gset

call pgpm.from_hypertable_cutover('public.b68', 'ts', interval '1 day', p_paused => false);

select ok((select array_agg(id order by id) from public.b68) = (select array_agg(g order by g) from generate_series(101, 130) g)
          and exists (select 1 from pgpm.config where parent_table = 'public.b68'::regclass),
          'LIVENESS: B''s cutover migrated rows 101 to 130 and handed the table to transmute');
select is((select c.conname::text from pg_constraint c where c.conindid = :b_pre_idx and c.contype = 'u'),
          'pgpm_key_' || :b_pre_idx,
          'the index B''s copy built is the migrated table''s key index (adopted, not rebuilt)');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.b68'::regclass and i.indisunique),
          array['b68_id_ts_key'],
          'B''s migrated parent carries one unique index, its unique constraint (no stray copy-built duplicate)');
select is((select c.confrelid::regclass::text from pg_constraint c
            where c.conrelid = 'public.b68_ref'::regclass and c.conname = 'b68_ref_fk' and c.contype = 'f'),
          'b68', 'LIVENESS: B''s incoming foreign key was restored against the migrated parent');

-- PART C: a bare unique index the incoming foreign key was resolved to, beside the primary key. The bare index
-- is the older of the two, so PostgreSQL takes it for a key that lists the columns; its own column order
-- (ts, id) is what the table would lose with it.
create table public.c68 (id int not null, ts timestamptz not null, v int);
select create_hypertable('public.c68', 'ts', chunk_time_interval => interval '1 day', create_default_indexes => false);
create unique index c68_ts_id_uq on public.c68 (ts, id);
alter table public.c68 add constraint c68_pkey primary key (id, ts);
create index c68_v_idx on public.c68 (v);
insert into public.c68 select g, '2026-10-01'::timestamptz + make_interval(hours => g - 200), g from generate_series(201, 220) g;
create table public.c68_ref (rid int primary key, id int, ts timestamptz,
  constraint c68_ref_fk foreign key (id, ts) references public.c68 (id, ts));
insert into public.c68_ref values (1, 203, '2026-10-01'::timestamptz + interval '3 hours'),
                                  (2, 209, '2026-10-01'::timestamptz + interval '9 hours'),
                                  (3, 214, '2026-10-01'::timestamptz + interval '14 hours');

select is((select c.conindid::regclass::text from pg_constraint c
            where c.conrelid = 'public.c68_ref'::regclass and c.conname = 'c68_ref_fk' and c.contype = 'f'),
          'c68_ts_id_uq',
          'LIVENESS: C''s incoming foreign key sits on the bare unique index, not on the primary key''s');

call pgpm.from_hypertable_copy('public.c68', 'ts', false);
call pgpm.from_hypertable_cutover('public.c68', 'ts', interval '1 day', p_paused => false);

select ok((select array_agg(id order by id) from public.c68) = (select array_agg(g order by g) from generate_series(201, 220) g)
          and exists (select 1 from pgpm.config where parent_table = 'public.c68'::regclass),
          'LIVENESS: C''s cutover migrated rows 201 to 220 and handed the table to transmute');
select is((select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = 'public.c68'::regclass),
          array['c68_pkey', 'c68_ts_id_uq_pgpm', 'c68_v_idx_pgpm'],
          'C''s migrated parent carries its primary key, the bare unique index the incoming key sat on, and its plain index');
select is((select i.indisunique::text || ' (' || string_agg(a.attname::text, ', ' order by k.ord) || ')'
             from pg_index i
             cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
             join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
            where i.indrelid = 'public.c68'::regclass and i.indexrelid = to_regclass('public.c68_ts_id_uq_pgpm')
            group by i.indisunique),
          'true (ts, id)',
          'the index C carried is the bare one as it was: unique, on (ts, id)');
select is((select c.confrelid::regclass::text from pg_constraint c
            where c.conrelid = 'public.c68_ref'::regclass and c.conname = 'c68_ref_fk' and c.contype = 'f'),
          'c68', 'LIVENESS: C''s incoming foreign key was restored against the migrated parent');

select * from finish();
