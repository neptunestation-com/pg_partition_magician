-- from_hypertable's change tracking and its append-only catch-up read a key's INCLUDE columns as no part of the
-- key (issue #1413, bullet 1): the hypertable twin of what #1398 fixed in regrain.
--
-- THE DEFECT. pg_index.indkey lists an index's key columns and then its INCLUDE columns; only the first
-- indnkeyatts are the key. from_hypertable_copy built the tracked key, the delta's columns and the capture's
-- value lists from the whole of indkey, and asked every one of those columns to be NOT NULL; the cutover picked
-- the append-only catch-up's key, and built its anti-join, the same way. So:
--   a PRIMARY KEY (id, ts) INCLUDE (note) with a nullable note was refused by the tracking copy as 'a key with
--   a nullable column', although id and ts are NOT NULL; and with a NOT NULL INCLUDE column the delta and every
--   reconcile carried it as a key column;
--   the append-only cutover skipped that primary key as nullable, fell back to the keyless catch-up's strict
--   `>`, missed a row that landed exactly at the copy watermark, and its conservation check refused the swap.
-- Now each of the four reads takes the first indnkeyatts columns alone.
--
-- ASYMMETRIC FIXTURES. a372: PRIMARY KEY (id, ts) INCLUDE (note), note nullable and NULL on the odd ids, 20 rows
-- (ids 1 to 20), tracked; after the copy id 4's note is set, id 7 deleted and id 21 inserted. b372: PRIMARY
-- KEY (id, ts) INCLUDE (tag), tag NOT NULL, 6 rows (ids 31 to 36), tracked; one update (id 33's tag). c372:
-- PRIMARY KEY (id, ts) INCLUDE (note), note nullable, 8 rows (ids 51 to 58), append-only; after the copy two
-- rows land, id 59 exactly at the copy watermark and id 60 past it. Every outcome is asserted by row.
-- WITNESSES: each key really has an INCLUDE column, its key columns really are NOT NULL, a372's and c372's
-- INCLUDE column really holds NULLs, and id 59 really sits at c372's copy watermark.
-- bench/hypertable_include_columns_not_key.sh runs this file against the mutants that read the whole of
-- indkey again (hypertable_copy_key_reads_include, hypertable_catchup_key_reads_include); it must FAIL there.
select plan(14);

create table public.a372 (ts timestamptz not null, id bigint not null, note text,
  constraint a372_pkey primary key (id, ts) include (note));
select create_hypertable('public.a372', 'ts', chunk_time_interval => interval '1 day');
insert into public.a372 select timestamptz '2024-01-01 00:00+00' + g * interval '3 hours', g,
  case when g % 2 = 0 then 'n' || g end from generate_series(1, 20) g;
create table public.b372 (ts timestamptz not null, id bigint not null, tag text not null,
  constraint b372_pkey primary key (id, ts) include (tag));
select create_hypertable('public.b372', 'ts', chunk_time_interval => interval '1 day');
insert into public.b372 select timestamptz '2024-02-01 00:00+00' + (g - 30) * interval '5 hours', g, 't' || g
  from generate_series(31, 36) g;
create table public.c372 (ts timestamptz not null, id bigint not null, note text,
  constraint c372_pkey primary key (id, ts) include (note));
select create_hypertable('public.c372', 'ts', chunk_time_interval => interval '1 day');
insert into public.c372 select timestamptz '2024-03-01 00:00+00' + (g - 50) * interval '4 hours', g,
  case when g % 3 = 0 then 'c' || g end from generate_series(51, 58) g;

-- ==================== the witnesses: each key has an INCLUDE column, and its key columns are NOT NULL ====================
select is((select string_agg(c.relname || ':' || i.indnatts || '/' || i.indnkeyatts, ',' order by c.relname)
             from pg_index i join pg_class c on c.oid = i.indexrelid
            where i.indexrelid in ('a372_pkey'::regclass, 'b372_pkey'::regclass, 'c372_pkey'::regclass)),
  'a372_pkey:3/2,b372_pkey:3/2,c372_pkey:3/2', 'LIVENESS: each primary key has two key columns and one INCLUDE column');
select is((select count(*)::int from public.a372 where note is null) || ',' || (select count(*)::int from public.c372 where note is null), '10,5',
  'LIVENESS: a372''s and c372''s INCLUDE column holds NULLs (10 and 5 rows)');

-- ==================== A: the tracking copy tracks by the key columns alone ====================
call pgpm.from_hypertable_copy('public.a372', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('public.b372', 'ts', p_track_changes => true);
select is((select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
            where a.attrelid = pgpm._scratch_rel('public.a372', 'hypertable_delta') and a.attnum > 0 and not a.attisdropped
              and a.attname is distinct from pgpm._delta_seq(pgpm._scratch_rel('public.a372', 'hypertable_delta'))),
  'id,ts', 'a372: the tracking copy is not refused for a nullable INCLUDE column, and its delta holds the key columns alone (#1413)');
select is((select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
            where a.attrelid = pgpm._scratch_rel('public.b372', 'hypertable_delta') and a.attnum > 0 and not a.attisdropped
              and a.attname is distinct from pgpm._delta_seq(pgpm._scratch_rel('public.b372', 'hypertable_delta'))),
  'id,ts', 'b372: a NOT NULL INCLUDE column is no column of the delta either');

update public.a372 set note = 'changed' where id = 4;
delete from public.a372 where id = 7;
insert into public.a372 values (timestamptz '2024-01-01 00:00+00' + 21 * interval '3 hours', 21, null);
update public.b372 set tag = 'moved' where id = 33;
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.a372_pgpm_delta), '4,4,7,21',
  'LIVENESS: a372''s capture logged the three writes by their key columns');
select is((select string_agg(id::text, ',' order by id, pgpm_seq) from public.b372_pgpm_delta), '33,33',
  'LIVENESS: b372''s capture logged its update');

call pgpm.from_hypertable_drain_delta('public.a372', 'ts');
select is((select string_agg(id || '=' || coalesce(note, '-'), ',' order by id) from public.a372_pgpm_dest where id between 3 and 8 or id = 21),
  '3=-,4=changed,5=-,6=n6,8=n8,21=-', 'a372: the drain applied the update, the delete and the insert to the copy, by row');
call pgpm.from_hypertable_cutover('public.a372', 'ts', interval '1 day', p_obtain => 2);
call pgpm.from_hypertable_cutover('public.b372', 'ts', interval '1 day', p_obtain => 2);
select is((select string_agg(relkind::text, ',' order by relname) from pg_class where oid in ('public.a372'::regclass, 'public.b372'::regclass)),
  'p,p', 'LIVENESS: a372 and b372 were cut over to partitioned tables');
select is((select string_agg(id || '=' || coalesce(note, '-'), ',' order by id) from public.a372),
  '1=-,2=n2,3=-,4=changed,5=-,6=n6,8=n8,9=-,10=n10,11=-,12=n12,13=-,14=n14,15=-,16=n16,17=-,18=n18,19=-,20=n20,21=-',
  'a372 holds every row as it is now, id 7 gone and id 21 in, after the cutover');
select is((select string_agg(id || '=' || tag, ',' order by id) from public.b372), '31=t31,32=t32,33=moved,34=t34,35=t35,36=t36',
  'b372 holds its six rows, id 33''s new tag in, after the cutover');

-- ==================== B: the append-only catch-up anti-joins by the key columns alone ====================
call pgpm.from_hypertable_copy('public.c372', 'ts');
select max(ts) as wm from public.c372_pgpm_dest \gset
insert into public.c372 values (:'wm', 59, null), (:'wm'::timestamptz + interval '1 hour', 60, 'c60');
select is((select string_agg(id::text, ',' order by id) from public.c372 where ts = :'wm'), '58,59',
  'LIVENESS: id 59 landed exactly at the copy watermark, beside the copied id 58');
select is((select count(*)::int from public.c372_pgpm_dest where id in (59, 60)), 0,
  'LIVENESS: neither late row is in the copy, so only the cutover''s catch-up can carry them');
call pgpm.from_hypertable_cutover('public.c372', 'ts', interval '1 day', p_obtain => 2, p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.c372'::regclass), 'p',
  'the append-only cutover of a key with a nullable INCLUDE column swaps (#1413)');
select is((select string_agg(id || '=' || coalesce(note, '-'), ',' order by id) from public.c372),
  '51=c51,52=-,53=-,54=c54,55=-,56=-,57=c57,58=-,59=-,60=c60',
  'and c372 holds its eight rows and both late ones, id 59 at the watermark included, after the cutover');

select * from finish();
