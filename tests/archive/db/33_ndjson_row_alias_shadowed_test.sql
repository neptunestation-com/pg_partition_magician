-- The NDJSON encoders archive the WHOLE ROW whatever the table's columns are called (issue #821).
--
-- Both NDJSON encoders (archive._encode_upload_ndjson_single, behind pgpm.archive_to_s3_ndjson, and
-- archive.to_s3, in its pages and in its conservation fingerprint) aliased the table `t` and rendered each
-- row as row_to_json(t). PostgreSQL resolves a bare name as a COLUMN before it tries it as a whole-row
-- reference, so on a table with a column named t the expression was row_to_json(<that column>):
--
--   * a composite column t: each line held only that column's fields ({"a":7,"b":8}, no id, no payload),
--     rows_archived counted the rows, the ledger recorded the chunk and retire() dropped the only complete
--     copy. archive.to_s3 fingerprinted the same text on both sides, so its conservation check passed;
--   * a timestamptz column t, the usual time-series shape (here the control column itself): every encode
--     raised "function row_to_json(timestamp with time zone) does not exist", a wedge on every tick.
--
-- Each site now renders row_to_json(t.*), a whole-row reference no column can shadow (`t.*` resolves
-- against the FROM item's alias, never a column).
--
-- The contract is checked by identity: every line of every object carries exactly the table's columns,
-- and each row's values read back equal the row's. Witnesses show the shadowing is live in this database
-- (a bare row_to_json(t) over each fixture renders the column, or raises) and that each path did the work
-- (rows ledgered, the partition retired, the exports returned).
--
-- Fixtures, asymmetric: in t33.cmp rows 1 and 2 are in the archived chunk and row 45000 is not; in t33.ts
-- the chunk [00:00Z, 01:00Z) holds ids 1 and 2 and the table also holds id 3, ten hours later. Every key
-- this file writes is cleared and witnessed absent first, because the bucket outlives a test database;
-- keys carry current_database().
select plan(22);
set timezone = 'UTC';
set client_min_messages = warning;

create schema t33;

-- S3 through the module's signer, the instrument here and not the subject
create function t33.req(p_method text, p_key text) returns http_response
language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin')
$$;
-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below
create function t33.clear(p_key text) returns int language sql as $$
  select (t33.req('DELETE', p_key)).status * 0 + (t33.req('GET', p_key)).status
$$;
-- an NDJSON object's lines as jsonb; nothing when there is no object
create function t33.lines(p_key text) returns setof jsonb language plpgsql as $$
declare v http_response := t33.req('GET', p_key);
begin
  if v.status <> 200 then return; end if;
  return query select l::jsonb from regexp_split_to_table(v.content, e'\n') l where l <> '';
end $$;
-- the distinct top-level keys across an object's lines, sorted: a line that is not the row has other keys
create function t33.keys(p_key text) returns text[] language sql as $$
  select array_agg(distinct k order by k) from t33.lines(p_key) d, jsonb_object_keys(d) k
$$;

-- ======================= a composite column named t =======================

create type t33.pair as (a int, b int);
create table t33.cmp (id bigint primary key, t t33.pair, payload text not null);
insert into t33.cmp values (1, (7, 8), 'keep-one'), (2, (9, 10), 'keep-two');
call pgpm.transmute('t33.cmp', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t33.cmp values (45000, (0, 0), 'frontier');
select current_database() || '-t33/' as p \gset
select archive.configure('t33.cmp', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t33.cmp', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select child_name as cmp_child from pgpm.part where parent_table = 't33.cmp'::regclass and lo = '0' \gset
select :'p' || 't33.cmp_0.ndjson' as k_cmp_auto \gset
select :'p' || 't33.' || :'cmp_child' || '.ndjson' as k_cmp_sync \gset
-- what the object must hold: each row of [0, 10000), rendered from the table, never from the encoder
create temp table cmp_want as select id, (t).a, (t).b, payload from t33.cmp where id < 10000;

select is((select array_agg(id order by id) from cmp_want), array[1, 2]::bigint[],
  'LIVENESS: [0, 10000) of t33.cmp holds rows 1 and 2');
select is((select array_agg(row_to_json(t)::text order by id) from t33.cmp t where id < 10000),
  array['{"a":7,"b":8}', '{"a":9,"b":10}'],
  'LIVENESS: in this database a bare row_to_json(t) over t33.cmp renders the column t, not the row');
select is(array[t33.clear(:'k_cmp_auto'), t33.clear(:'k_cmp_sync')], array[404, 404],
  'LIVENESS: no object at either of t33.cmp''s NDJSON keys before the exports');

-- archive.to_s3 first, while the child is still there; then the tick, which archives and retires it
select lives_ok(format('select archive.to_s3(%L, %L, %L, %L)', 't33.cmp', :'cmp_child', '0', '10000'),
  'archive.to_s3 exports t33.cmp''s [0, 10000) (its conservation check passes)');
select is(t33.keys(:'k_cmp_sync'), array['id', 'payload', 't'],
  'archive.to_s3: every line of t33.cmp''s object carries exactly the columns id, t and payload');
select is((select array_agg(format('%s|%s|%s|%s', d ->> 'id', d -> 't' ->> 'a', d -> 't' ->> 'b', d ->> 'payload')
                            order by (d ->> 'id')::bigint) from t33.lines(:'k_cmp_sync') d),
          (select array_agg(format('%s|%s|%s|%s', id, a, b, payload) order by id) from cmp_want),
  'archive.to_s3: t33.cmp''s object holds rows 1 and 2, each with its own t and payload');

call pgpm.maintain('t33.cmp');

select is((select rows_archived from pgpm.archive_ledger where parent_table = 't33.cmp'::regclass and lo = '0'), 2::bigint,
  'LIVENESS: the tick archived and ledgered t33.cmp''s [0, 10000) as two rows');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't33.cmp'::regclass and lo = '0'), :'k_cmp_auto',
  'LIVENESS: the ledger names the object at the chunk''s key');
select is((select array_agg(id order by id) from t33.cmp), array[45000]::bigint[],
  'LIVENESS: retire() dropped [0, 10000), so the object is the only copy of rows 1 and 2');
select is(t33.keys(:'k_cmp_auto'), array['id', 'payload', 't'],
  'pgpm.archive_to_s3_ndjson: every line of t33.cmp''s object carries exactly the columns id, t and payload');
select is((select array_agg(format('%s|%s|%s|%s', d ->> 'id', d -> 't' ->> 'a', d -> 't' ->> 'b', d ->> 'payload')
                            order by (d ->> 'id')::bigint) from t33.lines(:'k_cmp_auto') d),
          (select array_agg(format('%s|%s|%s|%s', id, a, b, payload) order by id) from cmp_want),
  'pgpm.archive_to_s3_ndjson: t33.cmp''s object holds rows 1 and 2, each with its own t and payload');

-- ======================= a timestamptz column named t, the control column =======================

create table t33.ts (t timestamptz not null, id int not null, payload text not null, primary key (t, id));
insert into t33.ts values
  ('2024-01-01 00:10:00+00', 1, 'one'), ('2024-01-01 00:20:00+00', 2, 'two'), ('2024-01-01 10:30:00+00', 3, 'three');
call pgpm.transmute('t33.ts', 't', interval '1 hour');
select archive.configure('t33.ts', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select tableoid::regclass as ts_child_rel from t33.ts where id = 1 \gset
select relname as ts_child from pg_class where oid = :'ts_child_rel'::regclass \gset
select pgpm._ts_text('2024-01-01 00:00:00+00') as ts_lo, pgpm._ts_text('2024-01-01 01:00:00+00') as ts_hi \gset
select :'p' || 't33.ts_2024010100000000.ndjson' as k_ts_auto \gset
select :'p' || 't33.' || :'ts_child' || '.ndjson' as k_ts_sync \gset
-- each row as the object must hold it, read from the table: the chunk's for the strategy, the child's for to_s3
create temp table ts_chunk as select id, t, payload from t33.ts where t >= :'ts_lo' and t < :'ts_hi';
create temp table ts_child as select id, t, payload from t33.ts where tableoid = :'ts_child_rel'::regclass;

select is((select array_agg(id order by id) from ts_chunk), array[1, 2],
  'LIVENESS: t33.ts''s chunk [00:00Z, 01:00Z) holds ids 1 and 2, and not id 3');
select ok((select count(*) from ts_child) >= 2 and (select bool_and(id in (select id from ts_child)) from ts_chunk),
  'LIVENESS: the child archive.to_s3 is pointed at holds the chunk''s rows');
select throws_like($$select row_to_json(t) from t33.ts t$$, '%row_to_json(timestamp with time zone) does not exist%',
  'LIVENESS: in this database a bare row_to_json(t) over t33.ts binds the timestamptz column t, and raises');
select is(array[t33.clear(:'k_ts_auto'), t33.clear(:'k_ts_sync')], array[404, 404],
  'LIVENESS: no object at either of t33.ts''s NDJSON keys before the exports');

create temp table ts_auto of pgpm.archive_result;
select lives_ok(format('insert into ts_auto select * from pgpm.archive_to_s3_ndjson(%L, %L, %L, %L)',
                       't33.ts', :'ts_child', :'ts_lo', :'ts_hi'),
  'pgpm.archive_to_s3_ndjson archives t33.ts''s chunk (it does not raise on the column t)');
select is((select array[s3_key, rows_archived::text] from ts_auto), array[:'k_ts_auto', '2'],
  'pgpm.archive_to_s3_ndjson reports two rows archived at t33.ts''s chunk key');
select is(t33.keys(:'k_ts_auto'), array['id', 'payload', 't'],
  'pgpm.archive_to_s3_ndjson: every line of t33.ts''s object carries exactly the columns t, id and payload');
select is((select array_agg(format('%s|%s|%s', d ->> 'id', (d ->> 't')::timestamptz, d ->> 'payload')
                            order by (d ->> 'id')::int) from t33.lines(:'k_ts_auto') d),
          (select array_agg(format('%s|%s|%s', id, t, payload) order by id) from ts_chunk),
  'pgpm.archive_to_s3_ndjson: t33.ts''s object holds ids 1 and 2, each with its own t and payload');

select lives_ok(format('select archive.to_s3(%L, %L, %L, %L)', 't33.ts', :'ts_child', :'ts_lo', :'ts_hi'),
  'archive.to_s3 exports t33.ts''s child (it does not raise on the column t)');
select is(t33.keys(:'k_ts_sync'), array['id', 'payload', 't'],
  'archive.to_s3: every line of t33.ts''s object carries exactly the columns t, id and payload');
select is((select array_agg(format('%s|%s|%s', d ->> 'id', (d ->> 't')::timestamptz, d ->> 'payload')
                            order by (d ->> 'id')::int) from t33.lines(:'k_ts_sync') d),
          (select array_agg(format('%s|%s|%s', id, t, payload) order by id) from ts_child),
  'archive.to_s3: t33.ts''s object holds every row of the child, each with its own t and payload');

select * from finish();
