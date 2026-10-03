-- A tracking from_hypertable_copy of a RENAMED hypertable builds its key index by the destination's identity
-- (issue #872, bullet 4).
--
-- A tracking copy pre-builds the reused key's index on its destination under the temp name <conname>_pgpm_new,
-- and the cutover adopts it (#175). The name is schema-wide and a key keeps its name across ALTER TABLE ...
-- RENAME, so a tracking copy taken under the table's old name and abandoned (its <old>_pgpm_dest still holds
-- <conname>_pgpm_new) made the renamed table's copy die 'relation ... already exists' before copying a row.
-- The cutover had learnt in #768 to adopt only an index ON its destination and to build under the oid form
-- otherwise; the copy had not. Both now ask pgpm._from_hypertable_key_tmp, which picks, of the usual name and
-- the oid form, one already on the destination, else one nothing holds, so the copy builds under the oid form
-- and the cutover ADOPTS that index (by its oid, not rebuilt) rather than building a second one or dying on
-- the name.
--
-- ASYMMETRIC FIXTURE. z45 holds ids 1..20 except the multiples of 3 (14 rows); the abandoned copy took them
-- all, and the renamed table then gains id 31 and loses id 2 before its own copy, so a destination built from
-- the stale copy, or one that missed the late writes, holds a different id set.
-- WITNESSES: the stale index sits on the old copy and the renamed key kept its name; the stale copy is left
-- exactly as it was.
select plan(10);

create table public.z45 (id bigint not null, ts timestamptz not null, v int not null, primary key (id, ts));
select create_hypertable('public.z45', 'ts', chunk_time_interval => interval '1 day');
insert into public.z45 select g, now() - g * interval '3 hours', g * 10 from generate_series(1, 20) g where g % 3 <> 0;
call pgpm.from_hypertable_copy('public.z45', 'ts', p_track_changes => true);   -- abandoned, never cut over
alter table public.z45 rename to z45b;
insert into public.z45b values (31, now() - interval '1 hour', 310);
delete from public.z45b where id = 2;
select 'public.z45_pkey_pgpm_new'::regclass::oid as stale_idx \gset
select conindid as key_idx from pg_constraint where conrelid = 'public.z45b'::regclass and contype = 'p' \gset

select is((select i.indrelid::regclass::text from pg_index i where i.indexrelid = :'stale_idx'::oid),
          'z45_pgpm_dest', 'LIVENESS: the abandoned copy''s key index z45_pkey_pgpm_new sits on the old copy z45_pgpm_dest');
select is((select conname::text from pg_constraint where conrelid = 'public.z45b'::regclass and contype = 'p'),
          'z45_pkey', 'LIVENESS: the renamed hypertable''s key kept its name, so it asks for the temp name the stale copy holds');

call pgpm.from_hypertable_copy('public.z45b', 'ts', p_track_changes => true);

select is((select c.relname::text from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indrelid = to_regclass('public.z45b_pgpm_dest') and i.indisunique),
          'pgpm_new_' || :'key_idx', 'the renamed table''s copy built its key index on its own destination, under the oid form');
select i.indexrelid::oid as copy_idx from pg_index i
 where i.indrelid = to_regclass('public.z45b_pgpm_dest') and i.indisunique \gset
select is((select array_agg(id order by id) from public.z45b_pgpm_dest),
          array[1, 4, 5, 7, 8, 10, 11, 13, 14, 16, 17, 19, 20, 31]::bigint[],
          'and copied the renamed table''s rows, the late insert in and the late delete out');

call pgpm.from_hypertable_cutover('public.z45b', 'ts', interval '1 day', p_paused => true);

select is((select relkind::text from pg_class where oid = 'public.z45b'::regclass), 'p',
          'z45b was migrated to a partitioned table');
select is((select array_agg(id order by id) from public.z45b),
          array[1, 4, 5, 7, 8, 10, 11, 13, 14, 16, 17, 19, 20, 31]::bigint[], 'z45b holds exactly its rows');
select is((select i.indisprimary::text || '/' || (i.indrelid = (select tableoid from public.z45b where id = 1))::text
                  || '/' || (select inhparent::regclass::text from pg_inherits where inhrelid = i.indexrelid)
             from pg_index i where i.indexrelid = :'copy_idx'::oid),
          'true/true/z45_pkey', 'the cutover adopted the copy''s index as the key rather than building another');
select is((select count(*)::int from pg_index where indrelid = (select tableoid from public.z45b where id = 1) and indisunique),
          1, 'and the migrated monolith carries one unique index, not a second built beside it');
select throws_ok($$ insert into public.z45b select id, ts, -1 from public.z45b where id = 4 $$, '23505', NULL,
          'and its primary key is enforced');
select is((select i.indrelid::regclass::text || '/' || (select relname::text from pg_class where oid = :'stale_idx'::oid)
             from pg_index i where i.indexrelid = :'stale_idx'::oid),
          'z45_pgpm_dest/z45_pkey_pgpm_new', 'the stale copy''s index is left where it was, under its name');

select * from finish();
