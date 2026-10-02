-- from_hypertable builds the destination's indexes by identity, under names that fit whole, and refuses up
-- front a grid whose monolith name transmute would refuse after the swap (issues #735 and #707).
--
-- (A) #735. The index pre-builds (the cutover's key and secondary loops, and the copy's reused-key build
-- when tracking) rewrote pg_get_indexdef with '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+'. A quoted name
-- holding a space does not match `[^ ]+`, so the statement ran UNREWRITTEN and tried to build a second
-- "f6 metrics_pkey" on the SOURCE: 'relation already exists', every time, after the whole online copy,
-- though the preflight had accepted the table. Now the definition's own prefix (the index's name and its
-- table's, as pg_get_indexdef quotes them) is matched exactly and replaced whole, as the core's #669 fix
-- does for transmute's carried indexes.
--
-- (B) #707, first half. The temp names were left(<name> || '_pgpm_new', 63). For a 63-byte key name that
-- cut IS the name: the copy's tracked build died on 'already exists', and the append-only cutover found the
-- source's own index under the temp name, skipped its build, and failed adopting an index the DROP had
-- taken. A name that does not fit whole now takes pgpm_new_<index oid>, the core's #655 form.
--
-- (C) #707, second half. The cutover hands the plain table to transmute only after its swap has committed,
-- and transmute names the monolith <rel>_p<lo>_to_<hi>: on a daily grid that is the table name plus 26
-- bytes, so a 38 to 48 byte name (inside this module's own 48-byte budget, #552) was refused there, with the
-- hypertable already gone. The cutover, and from_hypertable before its copy, now ask _part_name for that
-- name up front and refuse before anything changes.
--
-- WHAT THE HARNESS ALLOWS. run_timescale fails the track on any `ERROR:` line, so the successful copies and
-- cutovers are top-level CALLs (a failure there fails the file), and every refusal is wrapped by
-- throws_like with its message pinned: a procedure that does NOT refuse dies at its first COMMIT inside the
-- wrapper with 2D000 and rolls back into the state a refusal leaves, so only the message tells them apart.
-- ASYMMETRIC FIXTURES: 30 rows plus one appended in the window, 20 plus one updated and one appended, 36
-- refused then migrated on a coarser grid, so a lost row and an extra one cannot cancel.
-- bench/hypertable_index_names.sh runs this file against the mutations that put each defect back.
-- Autocommit, disposable-db.
select plan(19);

-- ==================== (A) #735: index and table names holding a space ====================
create table public."f6 metrics" (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public."f6 metrics"', 'ts', chunk_time_interval => interval '1 day',
                         create_default_indexes => false);
create index "f6 by v" on public."f6 metrics" (v);
insert into public."f6 metrics"
select g, date_trunc('hour', now()) - interval '3 days' + g * interval '1 hour', 'r' || g from generate_series(1, 30) g;
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public."f6 metrics"'::regclass),
  array['f6 by v', 'f6 metrics_pkey'],
  'LIVENESS: the hypertable''s key index and secondary index both have names holding a space');

call pgpm.from_hypertable_copy('public."f6 metrics"', 'ts');
insert into public."f6 metrics" values (31, date_trunc('hour', now()) - interval '1 hour', 'r31');   -- in the window
call pgpm.from_hypertable_cutover('public."f6 metrics"', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public."f6 metrics"'::regclass), 'p',
  'the append-only cutover converts a hypertable whose index names hold a space');
select is((select array_agg(id || ':' || v order by id) from public."f6 metrics"),
  (select array_agg(g || ':r' || g order by g) from generate_series(1, 31) g),
  'with its 30 copied rows and the one appended in the window, each with its own value');
select is(
  (select string_agg(c.relname::text || ':' || c.relkind::text, ',' order by c.relname)
     from pg_index i join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public."f6 metrics"'::regclass and not i.indisprimary),
  'f6 by v_pgpm:I',
  'and the secondary index rebuilt under its own name is carried onto the parent');

create table public."f6 tracked" (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public."f6 tracked"', 'ts', chunk_time_interval => interval '1 day');
insert into public."f6 tracked"
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 't' || g from generate_series(1, 20) g;
call pgpm.from_hypertable_copy('public."f6 tracked"', 'ts', p_track_changes => true);
select is(
  (select indrelid::regclass::text from pg_index where indexrelid = to_regclass('public."f6 tracked_pkey_pgpm_new"')),
  '"f6 tracked_pgpm_dest"',
  'the tracked copy builds the reused key''s index on the DESTINATION, under its whole temp name');
update public."f6 tracked" set v = 'u7' where id = 7;
insert into public."f6 tracked" values (21, date_trunc('hour', now()) - interval '30 minutes', 't21');
call pgpm.from_hypertable_cutover('public."f6 tracked"', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public."f6 tracked"'::regclass), 'p',
  'the tracked cutover converts it too');
select is((select array_agg(id || ':' || v order by id) from public."f6 tracked"),
  (select array_agg(g || ':' || case when g = 7 then 'u7' else 't' || g end order by g) from generate_series(1, 21) g),
  'with the update and the append made in the window reconciled');

-- ==================== (B) #707: a 63-byte key name keeps a whole temp name ====================
select rpad('c5b_append_key_', 63, 'k') as k63a, rpad('c5b_tracked_key_', 63, 'k') as k63t \gset
select is(octet_length(:'k63a') || '|' || (left(:'k63a' || '_pgpm_new', 63) = :'k63a'), '63|true',
  'LIVENESS: the key name is 63 bytes, so the old cut temp name was the key''s own name');
create table public.c5b_wide (device_id bigint not null, ts timestamptz not null, v text,
                              constraint :"k63a" unique (device_id, ts));
select create_hypertable('public.c5b_wide', 'ts', chunk_time_interval => interval '1 day');
insert into public.c5b_wide
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'w' || g from generate_series(1, 12) g;
call pgpm.from_hypertable_copy('public.c5b_wide', 'ts');
insert into public.c5b_wide values (13, date_trunc('hour', now()) - interval '20 minutes', 'w13');
call pgpm.from_hypertable_cutover('public.c5b_wide', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.c5b_wide'::regclass), 'p',
  'the append-only cutover converts a hypertable whose key name is 63 bytes');
select is((select array_agg(device_id || ':' || v order by device_id) from public.c5b_wide),
  (select array_agg(g || ':w' || g order by g) from generate_series(1, 13) g),
  'with its 12 copied rows and the one appended in the window');
-- The migrated table is the partitioned parent, which carries the key under its own name since #789; the
-- monolith's copy, the index the cutover built, is the one attached under it.
select is(
  (select p.conname::text from pg_constraint p join pg_constraint c on c.conparentid = p.oid
    where p.conrelid = 'public.c5b_wide'::regclass and p.contype = 'u'
      and c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.c5b_wide'::regclass)),
  :'k63a', 'and the key is adopted under its own 63-byte name on the migrated table');

create table public.c5b_wide_t (device_id bigint not null, ts timestamptz not null, v text,
                                constraint :"k63t" unique (device_id, ts));
select create_hypertable('public.c5b_wide_t', 'ts', chunk_time_interval => interval '1 day');
insert into public.c5b_wide_t
select g, date_trunc('hour', now()) - interval '2 days' + g * interval '1 hour', 'x' || g from generate_series(1, 9) g;
call pgpm.from_hypertable_copy('public.c5b_wide_t', 'ts', p_track_changes => true);
select is(
  (select i.indrelid::regclass::text from pg_index i
    where i.indexrelid = to_regclass('public.pgpm_new_'
            || (select conindid from pg_constraint where conname = :'k63t' and conrelid = 'public.c5b_wide_t'::regclass))),
  'c5b_wide_t_pgpm_dest',
  'the tracked copy builds the 63-byte key''s index on the destination as pgpm_new_<index oid>');
delete from public.c5b_wide_t where device_id = 4;
insert into public.c5b_wide_t values (10, date_trunc('hour', now()) - interval '10 minutes', 'x10');
call pgpm.from_hypertable_cutover('public.c5b_wide_t', 'ts', interval '1 day');
select is((select array_agg(device_id || ':' || v order by device_id) from public.c5b_wide_t),
  (select array_agg(g || ':x' || g order by g) from generate_series(1, 10) g where g <> 4),
  'and its tracked cutover migrates it with the delete and the append made in the window');

-- ==================== (C) #707: a monolith name transmute would refuse is refused up front ====================
select rpad('c5b_handoff_', 40, 'h') as l40 \gset
select mk_keyed_hypertable(:'l40', 36, '1 day', '3 days');
select is(octet_length(:'l40' || '_p2026_09_01_to_2026_09_02') || '|' || (select count(*) from public.:l40),
  '66|36', 'LIVENESS: a 40-byte hypertable of 36 rows, whose daily monolith name would be 66 bytes');
select throws_like(
  format($$ call pgpm.from_hypertable('public.%I', 'ts', interval '1 day') $$, :'l40'),
  'pg_partition_magician: cannot migrate hypertable % with p_interval 1 day -- refused before anything is changed%' || :'l40' || '_p%_to_% is 66 bytes%',
  'from_hypertable refuses the daily grid before its copy, naming the monolith name and its length');
select is(to_regclass(format('public.%I', :'l40' || '_pgpm_dest'))::text, null,
  'so no destination was built');
call pgpm.from_hypertable_copy(format('public.%I', :'l40')::regclass, 'ts');
select throws_like(
  format($$ call pgpm.from_hypertable_cutover('public.%I', 'ts', interval '1 day') $$, :'l40'),
  'pg_partition_magician: cannot migrate hypertable % with p_interval 1 day -- refused before anything is changed%is 66 bytes%',
  'the cutover refuses it in its own right, before its pre-drain and swap');
select is(
  (select relkind::text from pg_class where oid = format('public.%I', :'l40')::regclass)
    || '|' || exists (select 1 from timescaledb_information.hypertables where hypertable_name = :'l40')
    || '|' || (to_regclass(format('public.%I', :'l40' || '_pgpm_dest')) is not null),
  'r|true|true', 'and the hypertable is still a hypertable beside its copy');
call pgpm.from_hypertable_cutover(format('public.%I', :'l40')::regclass, 'ts', interval '1 month');
select is(
  (select relkind::text from pg_class where oid = format('public.%I', :'l40')::regclass)
    || '|' || (select array_agg(device_id order by device_id) from public.:l40)::text,
  'p|' || (select array_agg(g::bigint order by g) from generate_series(1, 36) g)::text,
  'LIVENESS: on a monthly grid, whose monolith name fits, the same table migrates with its 36 rows');

select * from finish();
