-- from_hypertable_cutover took another table's index for its key's (issue #768, F6-09). A tracking copy
-- pre-builds the reused key's index on its destination under the temp name <conname>_pgpm_new, and the
-- cutover skips building one when that name is taken, to adopt the copy's (#175). It asked only whether the
-- NAME resolved, anywhere in the schema, never whether the index was on THIS cutover's destination. A key
-- keeps its name when its table is renamed, so after a tracking copy of z44 that was never cut over (its
-- z44_pgpm_dest kept z44_pkey_pgpm_new) and ALTER TABLE z44 RENAME TO z44b, migrating z44b skipped its own
-- key build and failed adopting the stale index ('does not belong to table "z44b"') after the whole copy.
-- Since #1083 the migration's own copy drops that abandoned copy by its record first, so here the name is
-- held by an operator's index on a table of their own, which pgpm never drops.
-- The cutover now adopts an index under the temp name only when it is on the destination (pg_index.indrelid),
-- and builds its own under the oid form of the temp name when something else holds it.
--
-- ASYMMETRIC FIXTURE. z44 has a primary key AND a unique constraint, and only the primary key's temp name is
-- held by the operator's index, so one key is built under
-- the fallback name and the other under its usual one. A second hypertable, t44, is copied with tracking and
-- cut over normally, so the copy's own index is still the one adopted (by its oid, not rebuilt).
-- WITNESSES: the operator's index sits on their table and the renamed key kept its name; each migration
-- completed with every row by id; the operator's index is left exactly as it was.
select plan(12);

create table public.z44 (id bigint not null, ts timestamptz not null, v int not null, primary key (id, ts),
                         constraint z44_v_key unique (v, ts));
select create_hypertable('public.z44', 'ts', chunk_time_interval => interval '1 day');
insert into public.z44 select g, now() - g * interval '3 hours', g * 10 from generate_series(1, 20) g;
create table public.z44_old (id bigint not null, ts timestamptz not null);
insert into public.z44_old values (4, now());
create unique index z44_pkey_pgpm_new on public.z44_old (id, ts);   -- the operator's, under the key's temp name
alter table public.z44 rename to z44b;
select 'public.z44_pkey_pgpm_new'::regclass::oid as stale_idx \gset

select is((select i.indrelid::regclass::text from pg_index i where i.indexrelid = 'public.z44_pkey_pgpm_new'::regclass),
          'z44_old', 'LIVENESS: the operator''s index z44_pkey_pgpm_new sits on z44_old');
select is((select string_agg(conname, ',' order by conname) from pg_constraint
            where conrelid = 'public.z44b'::regclass and contype in ('p', 'u')),
          'z44_pkey,z44_v_key', 'LIVENESS: the renamed hypertable''s keys kept their names');
select is(to_regclass('public.z44_v_key_pgpm_new'), null::regclass,
          'LIVENESS: nothing holds the unique constraint''s temp name');

call pgpm.from_hypertable('public.z44b', 'ts', interval '1 day', p_paused => true);

select is((select relkind::text from pg_class where oid = 'public.z44b'::regclass), 'p',
          'z44b was migrated to a partitioned table');
select is((select string_agg(id::text || ':' || v::text, ',' order by id) from public.z44b),
          (select string_agg(g::text || ':' || (g * 10)::text, ',' order by g) from generate_series(1, 20) g),
          'z44b holds ids 1..20 with their values');
-- the swap's plain table is transmute's monolith now: it took both keys, and the parent the primary one
select is((select conname::text from pg_constraint where conrelid = 'public.z44b'::regclass and contype = 'p')
          || '/' || (select string_agg(contype::text || ':' || (pg_get_constraintdef(oid) ~ '^(PRIMARY KEY|UNIQUE) \((id, ts|v, ts)\)$')::text,
                                       ',' order by contype) from pg_constraint
                      where conrelid = (select tableoid from public.z44b where id = 1) and contype in ('p', 'u')),
          'z44_pkey/p:true,u:true', 'the migrated parent''s key is z44_pkey, and its monolith holds both keys the swap adopted');
select throws_ok($$ insert into public.z44b select id, ts, -1 from public.z44b where id = 4 $$, '23505', NULL,
          'and its primary key is enforced');
select is((select i.indrelid::regclass::text from pg_index i where i.indexrelid = :'stale_idx'::oid)
          || '/' || (select relname::text from pg_class where oid = :'stale_idx'::oid),
          'z44_old/z44_pkey_pgpm_new', 'the operator''s index is left where it was, under its name');

-- the copy's own pre-built key index is still the one adopted
create table public.t44 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.t44', 'ts', chunk_time_interval => interval '1 day');
insert into public.t44 select g, now() - g * interval '5 hours', g from generate_series(1, 7) g;
call pgpm.from_hypertable_copy('public.t44', 'ts', p_track_changes => true);
select i.indexrelid::oid as copy_idx from pg_index i
 where i.indexrelid = 'public.t44_pkey_pgpm_new'::regclass and i.indrelid = 'public.t44_pgpm_dest'::regclass \gset
select isnt(:'copy_idx'::oid, null, 'LIVENESS: the tracking copy built t44''s key index on its destination');
call pgpm.from_hypertable_cutover('public.t44', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.t44'::regclass), 'p',
          'LIVENESS: t44 was migrated to a partitioned table');
select is((select string_agg(id::text, ',' order by id) from public.t44), '1,2,3,4,5,6,7',
          'LIVENESS: t44 holds ids 1..7');
select is((select i.indisprimary::text || '/' || (i.indrelid = (select tableoid from public.t44 where id = 1))::text
                  || '/' || (select inhparent::regclass::text from pg_inherits where inhrelid = i.indexrelid)
             from pg_index i where i.indexrelid = :'copy_idx'::oid),
          'true/true/t44_pkey', 'the cutover adopted the copy''s index as the key rather than building another: it is the monolith''s primary key, under t44_pkey');

select * from finish();
