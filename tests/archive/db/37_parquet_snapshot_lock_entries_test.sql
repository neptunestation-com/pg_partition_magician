-- Every Parquet encode materialises its rows into the session temp table pg_temp.archive_pq_snapshot
-- first (archive._pq_snapshot, #462). It used to create that table and drop it again on every encode,
-- and a dropped relation's locks are held to transaction end: the table, its TOAST table and TOAST
-- index, and its two row types, eight entries in the SHARED lock table per encode. pgpm._archive_step
-- runs one encode per chunk for up to archive_batch partitions in ONE transaction, so a tick's lock
-- entries grew with the number of chunks it archived, the cliff #587 removed from the Huffman builder
-- (issue #632, F5-04: twenty Parquet strategy calls in one transaction added 160 entries). The snapshot
-- relation is now reused: an encode of the same shape (every chunk of one parent, which is all one
-- _archive_step encodes) empties it and refills it in one statement, and only a change of shape drops
-- it and builds another.
--
-- The contract: N Parquet encodes of one shape in one transaction add no lock-table entry, through
-- either entry point, compressed or not; and reusing the relation changes no archived byte, even when
-- encodes of two differently shaped tables alternate in one transaction. Each zero is paired with its
-- witnesses: the instrument DOES see a created-and-dropped temp table's held locks (the control, the
-- defect's own mechanism), the encodes measured are real multi-row files, and the interleaved encodes
-- are compared byte for byte with the same encodes each run alone in a transaction of its own (where
-- the relation is necessarily built fresh). The fixture tables are asymmetric (three rows of two
-- columns, two rows of four), so a file built from the wrong table's snapshot cannot pass for either.
select plan(13);

create schema t37;

-- Lock entries held by this backend, one text key per entry, by identity (test 22's instrument).
create function t37.my_locks() returns text[] language sql as $$
  select coalesce(array_agg(k order by k), '{}') from (
    select concat_ws('|', locktype, database, relation, page, tuple, virtualxid, transactionid,
                     classid, objid, objsubid, mode) as k
      from pg_locks where pid = pg_backend_pid()) s
$$;

-- Run p_sql once to warm up, then p_reps more times, all in the caller's one transaction; return the
-- lock entries the p_reps runs added.
create function t37.lock_growth(p_sql text, p_reps int) returns int language plpgsql as $$
declare v_before text[]; v_after text[]; i int;
begin
  execute p_sql;
  v_before := t37.my_locks();
  for i in 1..p_reps loop
    execute p_sql;
  end loop;
  v_after := t37.my_locks();
  return (select count(*) from unnest(v_after) k where k <> all (v_before))::int;
end $$;

-- The control's statement: the defect's mechanism, a temp table created and dropped in one call.
create function t37.temp_round_trip() returns int language plpgsql as $$
begin
  create temp table t37_probe (x int, t text) on commit drop;
  drop table t37_probe;
  return 1;
end $$;

-- A managed table, for the range entry point every strategy uses, and a plain one of another shape.
create table t37.evt (id bigint primary key, payload text not null);
insert into t37.evt values (1, 'one'), (2, 'two'), (3, 'three');
call pgpm.transmute('t37.evt', 'id', 10000::bigint);
create table t37.other (id bigint primary key, amount numeric(10, 2) not null, at timestamptz not null, note text);
insert into t37.other values (7, 12.50, '2024-01-01 00:00:00+00', null), (9, 0.25, '2024-02-01 00:00:00+00', 'n');

-- Each encode alone, in a transaction of its own (every top-level statement here autocommits).
select md5(archive._pq_to_parquet('t37.evt'::regclass, true)) as md_evt \gset
select md5(archive._pq_to_parquet('t37.other'::regclass, true)) as md_other \gset
select md5(archive._pq_to_parquet_range('t37.evt'::regclass, 'id', '0', '10000', false)) as md_range \gset

-- The same encodes interleaved in ONE transaction: evt, other, evt, other, then the range encode.
create function t37.interleaved() returns text[] language plpgsql as $$
begin
  return array[md5(archive._pq_to_parquet('t37.evt'::regclass, true)),
               md5(archive._pq_to_parquet('t37.other'::regclass, true)),
               md5(archive._pq_to_parquet('t37.evt'::regclass, true)),
               md5(archive._pq_to_parquet('t37.other'::regclass, true)),
               md5(archive._pq_to_parquet_range('t37.evt'::regclass, 'id', '0', '10000', false))];
end $$;

-- How many rows the snapshot relation holds right after an encode, in the encode's transaction.
create function t37.rows_left_after_encode() returns bigint language plpgsql as $$
declare n bigint;
begin
  perform archive._pq_to_parquet_range('t37.evt'::regclass, 'id', '0', '10000', true);
  if to_regclass('pg_temp.archive_pq_snapshot') is null then return null; end if;
  execute 'select count(*) from pg_temp.archive_pq_snapshot' into n;
  return n;
end $$;

-- 1-2. The instrument sees this backend's locks, and it sees the defect's mechanism.
select cmp_ok(cardinality(t37.my_locks()), '>', 0,
  'LIVENESS: pg_locks shows this backend''s own lock entries from inside its transaction');
select cmp_ok(t37.lock_growth('select t37.temp_round_trip()', 10), '>=', 10,
  'LIVENESS: ten temp tables created and dropped in one transaction leave their lock entries held to its end '
  '(the defect''s mechanism, so a zero below is not an instrument that sees nothing)');

-- 3-4. What is measured is a real encode.
select is((archive._pq_to_parquet_range_counted('t37.evt'::regclass, 'id', '0', '10000', true)).p_num_rows, 3::bigint,
  'LIVENESS: the range encode measured below reads the chunk''s three rows');
select is(substr(encode(archive._pq_to_parquet_range('t37.evt'::regclass, 'id', '0', '10000', true), 'escape'), 1, 4), 'PAR1',
  'LIVENESS: the range encode returns a Parquet file');

-- 5-7. The zeros: twenty encodes in one transaction, through each entry point.
select is(t37.lock_growth('select archive._pq_to_parquet_range(''t37.evt''::regclass, ''id'', ''0'', ''10000'', true)', 20), 0,
  'twenty compressed range encodes in one transaction (one _archive_step over twenty chunks) add no lock-table entry');
select is(t37.lock_growth('select archive._pq_to_parquet_range(''t37.evt''::regclass, ''id'', ''0'', ''10000'', false)', 20), 0,
  'twenty uncompressed range encodes in one transaction add no lock-table entry');
select is(t37.lock_growth('select archive._pq_to_parquet(''t37.evt''::regclass, true)', 20), 0,
  'twenty whole-relation encodes in one transaction add no lock-table entry');

-- 8. The snapshot is emptied when the encode is done with it, not left holding the chunk to commit.
select is(t37.rows_left_after_encode(), 0::bigint,
  'an encode leaves the snapshot relation empty behind it, in its own transaction');

-- 9-13. Reuse changes no byte, across a change of shape and back.
select isnt(:'md_evt'::text, :'md_other'::text,
  'LIVENESS: the two tables'' files differ, so a file built from the wrong snapshot is detectable');
select is((select count(*) from pg_attribute where attrelid = 't37.other'::regclass and attnum > 0)
          - (select count(*) from pg_attribute where attrelid = 't37.evt'::regclass and attnum > 0), 2::bigint,
  'LIVENESS: the tables differ in shape (four columns against two), so alternating them forces a rebuild');
select is((t37.interleaved())[1:4], array[:'md_evt', :'md_other', :'md_evt', :'md_other']::text[],
  'whole-relation encodes of two tables alternating in one transaction are byte for byte the encodes each run alone');
select is((t37.interleaved())[5], :'md_range'::text,
  'a range encode after them in the same transaction is byte for byte the range encode run alone');
select is(md5(archive._pq_to_parquet_range('t37.evt'::regclass, 'id', '0', '10000', false)), :'md_range'::text,
  'LIVENESS: the range encode is deterministic across transactions');

select * from finish();
