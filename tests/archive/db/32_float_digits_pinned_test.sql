-- Floats are archived at full precision whatever extra_float_digits the archiving session has (issue #781).
--
-- Every text render the archive writes a float through follows the session's extra_float_digits: the two
-- NDJSON encoders' row_to_json (archive._encode_upload_ndjson_single, behind pgpm.archive_to_s3_ndjson, and
-- archive.to_s3) and the Parquet writer's array_to_json for an array column (archive._pq_encode_column_data,
-- behind both Parquet encoders). Under extra_float_digits = 0, the pre-PG12 default that ALTER ROLE or ALTER
-- DATABASE still sets on some clusters and that a pg_cron tick inherits, a float8 is printed to 15
-- significant digits and a float4 to 6, so the object held values that were NOT the rows' values: the ledger
-- recorded the chunk archived, archive.to_s3's content fingerprint hashed the same rounded text on both
-- sides and passed, and retire() then dropped the only exact copy. Each of the three functions now pins
-- extra_float_digits = 1 (shortest-exact, the PostgreSQL 12+ default, so an object written from a default
-- session is byte for byte what it was) the way archive._object_stem pins TimeZone and DateStyle (#551).
--
-- The contract is checked by identity: each object's rows are read back as float8/float4 and compared with
-- the table's own values, row by row; each Parquet file is compared byte for byte with the file the same
-- rows give at the default setting. The witnesses show the setting is live in the session that archives
-- (and still set after each call, so the pin is scoped to the call) and that it does round the fixture.
--
-- Fixture, asymmetric: rows 1 and 3 hold floats that 15 (float8) and 6 (float4) significant digits cannot
-- represent, row 2 only values every setting prints exactly, so a defect shows as {1,3}, never as {} or
-- {1,2,3}. Every key this file writes is cleared and witnessed absent first, because the bucket outlives a
-- test database; keys carry current_database().
select plan(16);

create schema t32;

-- S3 through the module's signer, the instrument here and not the subject
create function t32.req(p_method text, p_key text) returns http_response
language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin')
$$;
-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below
create function t32.clear(p_key text) returns int language sql as $$
  select (t32.req('DELETE', p_key)).status * 0 + (t32.req('GET', p_key)).status
$$;
-- an NDJSON object's rows, each float read back through its own type's input function (exact at any
-- extra_float_digits), or an error when there is no object
create function t32.obj(p_key text) returns table(id bigint, f float8, r real, a float8[]) language plpgsql as $$
declare v http_response := t32.req('GET', p_key);
begin
  if v.status <> 200 then raise exception 'GET % -> HTTP %', p_key, v.status; end if;
  return query
    select (l::jsonb ->> 'id')::bigint, (l::jsonb ->> 'f')::float8, (l::jsonb ->> 'r')::real,
           (select array_agg(e::float8 order by o) from jsonb_array_elements_text(l::jsonb -> 'a') with ordinality x(e, o))
      from regexp_split_to_table(v.content, e'\n') l where l <> '';
end $$;

create table t32.fl (id bigint primary key, f float8 not null, r real not null, a float8[] not null);
insert into t32.fl values
  (1, 0.1::float8 + 0.2::float8, 1.0000001::real, array[0.1::float8 + 0.2::float8, 1.5]),
  (2, 1.5, 2.5, array[1.5::float8]),
  (3, 123456789.12345679, 16777215::real, array[123456789.12345679::float8]);
call pgpm.transmute('t32.fl', 'id', 10000::bigint);
select current_database() || '-t32/' as p \gset
select archive.configure('t32.fl', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as child from pgpm.part where parent_table = 't32.fl'::regclass and lo = '0' \gset
select :'p' || 't32.fl_0.ndjson' as k_auto \gset
select :'p' || 't32.' || :'child' || '.ndjson' as k_sync \gset

select is((select array_agg(id order by id) from t32.fl), array[1, 2, 3]::bigint[],
  'LIVENESS: [0, 10000) holds rows 1, 2 and 3');
select is(array[t32.clear(:'k_auto'), t32.clear(:'k_sync')], array[404, 404],
  'LIVENESS: no object at either NDJSON key before the exports');

-- ======================= the session a tick or an operator archives from =======================

set extra_float_digits = 0;
select is(current_setting('extra_float_digits'), '0', 'LIVENESS: the archiving session has extra_float_digits = 0');
select is((select array_agg(id order by id) from t32.fl t
            where (row_to_json(t)::jsonb ->> 'f')::float8 <> t.f
               or (row_to_json(t)::jsonb ->> 'r')::real <> t.r
               or (select array_agg(e::float8 order by o)
                     from jsonb_array_elements_text(array_to_json(t.a)::jsonb) with ordinality x(e, o)) <> t.a),
  array[1, 3]::bigint[],
  'LIVENESS: in this session row_to_json and array_to_json round rows 1 and 3, and only them');
reset extra_float_digits;
select is((select array_agg(id order by id) from t32.fl t
            where (row_to_json(t)::jsonb ->> 'f')::float8 = t.f and (row_to_json(t)::jsonb ->> 'r')::real = t.r),
  array[1, 2, 3]::bigint[],
  'LIVENESS: at the default setting every row''s JSON reads back exactly (the instrument is exact)');

-- ======================= NDJSON: the automatic strategy and archive.to_s3 =======================

set extra_float_digits = 0;
select (pgpm.archive_to_s3_ndjson('t32.fl', :'child', '0', '10000')).rows_archived as auto_rows \gset
select archive.to_s3('t32.fl', :'child', '0', '10000');
select is(current_setting('extra_float_digits'), '0',
  'the pin is scoped to the call: the session still has extra_float_digits = 0 after both exports');
reset extra_float_digits;

select is(:'auto_rows'::bigint, 3::bigint, 'LIVENESS: pgpm.archive_to_s3_ndjson archived three rows');
select is((select array_agg(id order by id) from t32.obj(:'k_auto')), array[1, 2, 3]::bigint[],
  'LIVENESS: the strategy''s object holds rows 1, 2 and 3');
select is((select array_agg(o.id order by o.id) from t32.obj(:'k_auto') o join t32.fl t using (id)
            where o.f <> t.f or o.r <> t.r or o.a <> t.a),
  null::bigint[],
  'pgpm.archive_to_s3_ndjson: every row''s float8, float4 and float8[] in the object equal the row''s (rows 1 and 3 not rounded)');
select is((select array_agg(id order by id) from t32.obj(:'k_sync')), array[1, 2, 3]::bigint[],
  'LIVENESS: archive.to_s3''s object holds rows 1, 2 and 3');
select is((select array_agg(o.id order by o.id) from t32.obj(:'k_sync') o join t32.fl t using (id)
            where o.f <> t.f or o.r <> t.r or o.a <> t.a),
  null::bigint[],
  'archive.to_s3: every row''s float8, float4 and float8[] in the object equal the row''s (rows 1 and 3 not rounded)');
select ok(position('0.30000000000000004' in (t32.req('GET', :'k_sync')).content) > 0,
  'archive.to_s3''s object carries row 1''s float8 as its shortest exact text, 0.30000000000000004');

-- ======================= Parquet: a float8[] column, through array_to_json =======================

-- The Parquet types the writer supports: float4 is not one of them, so the Parquet half reads (id, a).
create table t32.arr (id bigint primary key, a float8[] not null);
insert into t32.arr select id, a from t32.fl;
select archive._pq_to_parquet('t32.arr', false) as pq_whole_dflt \gset
select archive._pq_to_parquet_range('t32.arr', 'id', '0', '100', false) as pq_range_dflt \gset

select ok(position(convert_to('[0.30000000000000004,1.5]', 'UTF8') in :'pq_whole_dflt'::bytea) > 0,
  'LIVENESS: at the default setting the file carries row 1''s array as [0.30000000000000004,1.5]');

set extra_float_digits = 0;
select archive._pq_to_parquet('t32.arr', false) as pq_whole_0 \gset
select archive._pq_to_parquet_range('t32.arr', 'id', '0', '100', false) as pq_range_0 \gset
select is(current_setting('extra_float_digits'), '0',
  'LIVENESS: the Parquet encodes ran with extra_float_digits = 0 in the session');
reset extra_float_digits;

select is(:'pq_whole_0'::bytea, :'pq_whole_dflt'::bytea,
  'archive._pq_to_parquet: under extra_float_digits = 0 the file is byte for byte the default session''s');
select is(:'pq_range_0'::bytea, :'pq_range_dflt'::bytea,
  'archive._pq_to_parquet_range: under extra_float_digits = 0 the file is byte for byte the default session''s');

select * from finish();
