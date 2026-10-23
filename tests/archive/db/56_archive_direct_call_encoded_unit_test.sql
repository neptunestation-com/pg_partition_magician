-- A direct archive_fn strategy call reads its bounds once, as the grid reads them (#814, archive._grid_bound), and
-- the empty-range check (#969), the read, the recorded-chunk check and the object key all take that one reading.
-- On a date column the reading was the day the bound falls in, because a date keeps a bound's day and drops the
-- rest. A uuidv7 or text_time column drops the rest too: the read compares the column with pgpm._encode of each
-- bound, and the encoding keeps the bound's unit (a millisecond for uuidv7, ULID and cuid, a second for ObjectId
-- and KSUID) and drops what is below it. That was read only for a date column (issue #1369), so on a uuidv7 grid
-- [2024-01-02 00:00:00, 00:00:00.0005) passed the empty-range check, both bounds encoded to one uuid, the read
-- (col >= u and col < u) found no row, and the call PUT an empty object at lo's chunk key and reported 0 rows,
-- although a row whose instant is lo lies in the range. And a lo inside a unit was keyed by the instant
-- (<table>_20240102000000.000500) while the read began at the unit's start, a key no tick gives that chunk.
--
-- The contract: on a uuidv7 or text_time grid a bound is the start of the unit it falls in, as the column reads
-- it, so a range inside one unit is refused as empty, before anything is read or sent, and a lo inside a unit is
-- keyed by the unit's start, the key a tick gives the chunk the read covers. Part A is uuidv7 through the NDJSON
-- strategy, part B the same through the Parquet one, part C an ObjectId-shaped text_time key (a second's unit).
-- Each object is stated by identity (which rows, by payload), its key cleared and witnessed absent first, since
-- the bucket outlives the test database; the prefix carries the database's name.
select plan(31);

create schema t56;
select 't56-' || current_database() || '/' as p \gset

create function t56.req(p_method text, p_key text) returns int language sql as $$
  select (archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                    'text/plain', '', 'minioadmin', 'minioadmin')).status $$;
-- the payloads an NDJSON object holds, in order, or what the store answered
create function t56.held(p_key text) returns text language plpgsql as $$
declare r record;
begin
  r := archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                 'text/plain', '', 'minioadmin', 'minioadmin');
  if r.status <> 200 then return 'HTTP ' || r.status; end if;
  return coalesce((select string_agg(l::json ->> 'payload', ',' order by l::json ->> 'payload')
                     from regexp_split_to_table(r.content, e'\n') l where l <> ''), '(empty)');
end $$;
-- one direct strategy call: its key and row count, or its refusal
create function t56.arch(p_fn text, p_parent regclass, p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  execute format('select * from pgpm.%I($1, null, $2, $3)', p_fn) into r using p_parent, p_lo, p_hi;
  return r.s3_key || ' ' || r.rows_archived;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

-- ======================= PART A: uuidv7, NDJSON =======================
-- A and C at 00:00:00.000 (one millisecond, the key's unit), D at 00:00:00.001, B later the same day
create table t56.u (id uuid primary key, payload text);
insert into t56.u values
  ('018cc778-5000-7000-8000-00000000000a', 'A'), ('018cc778-5000-7000-8000-00000000000c', 'C'),
  ('018cc778-5001-7000-8000-00000000000d', 'D'), ('018cc8a3-e800-7000-8000-00000000000b', 'B');
call pgpm.transmute('t56.u', 'id', interval '1 day', p_paused => true);
select archive.configure('t56.u', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select :'p' || 't56.u_2024010200000000.ndjson' as ku \gset
select :'p' || 't56.u_20240102000000.000500.ndjson' as ku_inside \gset

select is((select control_kind from pgpm.config where parent_table = 't56.u'::regclass), 'uuidv7',
  'LIVENESS: (A) the table is a uuidv7 grid');
select is(pgpm._uuid_to_ts('018cc778-5000-7000-8000-00000000000a'), '2024-01-02 00:00:00+00'::timestamptz,
  'LIVENESS: (A) row A''s instant is 2024-01-02 00:00:00Z, inside [00:00:00, 00:00:00.0005)');
select ok(pgpm._native_gt('uuidv7', '2024-01-02 00:00:00.0005+00', '2024-01-02 00:00:00+00'),
  'LIVENESS: (A) [00:00:00, 00:00:00.0005) is not empty as instants');
select is(pgpm._encode('uuidv7', '2024-01-02 00:00:00.0005+00'), pgpm._encode('uuidv7', '2024-01-02 00:00:00+00'),
  'LIVENESS: (A) but the column reads both bounds as one uuid (the encoding keeps the millisecond)');
select is(t56.req('DELETE', :'ku') * 0 + t56.req('GET', :'ku'), 404, 'LIVENESS: (A) nothing at lo''s chunk key before the call');
select is(t56.req('DELETE', :'ku_inside') * 0 + t56.req('GET', :'ku_inside'), 404,
  'LIVENESS: (A) nor at the key of the instant inside the millisecond');

-- a range inside one millisecond is refused as empty, naming the bounds as the column reads them
select ok(t56.arch('archive_to_s3_ndjson', 't56.u', '2024-01-02 00:00:00+00', '2024-01-02 00:00:00.0005+00')
            like 'ERROR: pg_partition_magician: archive_to_s3_ndjson refuses the range [%, %) of t56.u -- it is empty or inverted%',
  'A: [00:00:00, 00:00:00.0005) on a uuidv7 grid is refused as an empty range');
select is(t56.req('GET', :'ku'), 404, 'A: and nothing is PUT at lo''s chunk key');

-- a lo inside a millisecond is the millisecond's start: keyed as a tick keys that chunk, holding the rows it read
select is(t56.arch('archive_to_s3_ndjson', 't56.u', '2024-01-02 00:00:00.0005+00', '2024-01-02 00:00:00.0015+00'),
  :'ku' || ' 2', 'A: [00:00:00.0005, 00:00:00.0015) is keyed by the millisecond the read starts at, two rows');
select is(t56.held(:'ku'), 'A,C', 'A: and that object holds rows A and C (not D, at the next millisecond, nor B)');
select is(t56.req('GET', :'ku_inside'), 404, 'A: nothing is keyed by the instant inside the millisecond');
select is(t56.req('DELETE', :'ku'), 204, 'LIVENESS: (A) the object is cleared');

-- control: a range on the millisecond grid writes the same key, and takes D in
select is(t56.arch('archive_to_s3_ndjson', 't56.u', '2024-01-02 00:00:00+00', '2024-01-02 00:00:00.002+00'),
  :'ku' || ' 3', 'LIVENESS: (A) [00:00:00, 00:00:00.002) writes three rows at the same key (control)');
select is(t56.held(:'ku'), 'A,C,D', 'LIVENESS: (A) rows A, C and D (control)');
select is(t56.req('DELETE', :'ku'), 204, 'LIVENESS: (A) the control object is cleared');

-- ======================= PART B: uuidv7, Parquet =======================
select :'p' || 't56.u_2024010200000000.parquet' as kp \gset
select is(t56.req('DELETE', :'kp') * 0 + t56.req('GET', :'kp'), 404, 'LIVENESS: (B) nothing at lo''s Parquet key before the call');
select ok(t56.arch('archive_to_s3_parquet', 't56.u', '2024-01-02 00:00:00+00', '2024-01-02 00:00:00.0005+00')
            like 'ERROR: pg_partition_magician: archive_to_s3_parquet refuses the range [%, %) of t56.u -- it is empty or inverted%',
  'B: the Parquet strategy refuses [00:00:00, 00:00:00.0005) as an empty range');
select is(t56.req('GET', :'kp'), 404, 'B: and nothing is PUT at lo''s Parquet key');
select is(t56.arch('archive_to_s3_parquet', 't56.u', '2024-01-02 00:00:00.0005+00', '2024-01-02 00:00:00.0015+00'),
  :'kp' || ' 2', 'B: a lo inside a millisecond is keyed by the millisecond''s start, two rows');
select is(t56.req('DELETE', :'kp'), 204, 'LIVENESS: (B) the object is there, and cleared');

-- ======================= PART C: text_time, ObjectId-shaped (a second's unit) =======================
create function t56.oid(p_ts timestamptz, n int) returns text language sql as $$
  select pgpm._ts_to_text_time(p_ts, '', 8, 16, 's', null) || lpad(to_hex(n), 16, '0') $$;
create table t56.o (id text collate "C" primary key, payload text);
insert into t56.o values
  (t56.oid('2024-01-02 00:00:00+00', 1), 'X'), (t56.oid('2024-01-02 00:00:00+00', 2), 'Y'),
  (t56.oid('2024-01-02 00:00:01+00', 3), 'Z'), (t56.oid('2024-01-02 06:00:00+00', 4), 'W');
call pgpm.transmute('t56.o', 'id', interval '1 day', p_paused => true,
                    p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
select archive.configure('t56.o', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select :'p' || 't56.o_2024010200000000.ndjson' as ko \gset
select is((select control_kind || ' ' || text_time_unit from pgpm.config where parent_table = 't56.o'::regclass), 'text_time s',
  'LIVENESS: (C) the table is a text_time grid whose unit is a second');
select is(pgpm._encode('text_time', '2024-01-02 00:00:00.75+00', '', 8, 16, 's'),
          pgpm._encode('text_time', '2024-01-02 00:00:00.25+00', '', 8, 16, 's'),
  'LIVENESS: (C) the column reads 00:00:00.25 and 00:00:00.75 as one boundary (the encoding keeps the second)');
select is(t56.req('DELETE', :'ko') * 0 + t56.req('GET', :'ko'), 404, 'LIVENESS: (C) nothing at the second''s chunk key before the call');
select ok(t56.arch('archive_to_s3_ndjson', 't56.o', '2024-01-02 00:00:00.25+00', '2024-01-02 00:00:00.75+00')
            like 'ERROR: pg_partition_magician: archive_to_s3_ndjson refuses the range [%, %) of t56.o -- it is empty or inverted%',
  'C: [00:00:00.25, 00:00:00.75) on a second-unit text_time grid is refused as an empty range');
select is(t56.req('GET', :'ko'), 404, 'C: and nothing is PUT at the second''s chunk key');
select is(t56.arch('archive_to_s3_ndjson', 't56.o', '2024-01-02 00:00:00.5+00', '2024-01-02 00:00:01.5+00'),
  :'ko' || ' 2', 'C: [00:00:00.5, 00:00:01.5) is keyed by the second the read starts at, two rows');
select is(t56.held(:'ko'), 'X,Y', 'C: and that object holds rows X and Y (not Z, at the next second, nor W)');
select is(t56.req('DELETE', :'ko'), 204, 'LIVENESS: (C) the object is cleared');
-- control: the second's own range takes the same rows to the same key
select is(t56.arch('archive_to_s3_ndjson', 't56.o', '2024-01-02 00:00:00+00', '2024-01-02 00:00:01+00'),
  :'ko' || ' 2', 'LIVENESS: (C) [00:00:00, 00:00:01) writes two rows at the same key (control)');
select is(t56.held(:'ko'), 'X,Y', 'LIVENESS: (C) rows X and Y (control)');
select is(t56.req('DELETE', :'ko'), 204, 'LIVENESS: (C) the control object is cleared');

select * from finish();
