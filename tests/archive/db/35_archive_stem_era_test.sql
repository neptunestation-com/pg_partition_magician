-- Two chunks of one table must never share an object key, BC chunks included (issue #823).
--
-- archive._object_stem rendered a time kind's lo in UTC and kept only its digits, and the ISO rendering of a
-- BC instant is '2024-01-01 00:00:00+00 BC': the era is one of the characters thrown away, so 2024-01-01 BC
-- and 2024-01-01 AD stemmed alike and two chunks of ONE table got ONE key. The second PUT replaced the
-- first while each call reported its own chunk archived, and the ledger would vouch for both. pgpm reaches
-- such a pair by itself (a transmuted monolith holding BC and AD rows is cut into chunks whose lo values are
-- a BC grid floor and an AD row value; a daily regrain of BC and AD cells does it with cell bounds), and
-- docs/reference.md already gives BC partitions their own `_bc` labels for the same reason.
--
-- The digits-only projection lost a second distinction too: a fraction of a second. '00:00:00.1+00' and the
-- five-digit year '20240-10-10 00:00:01+00' both left 20240101000000100. The stem now keeps the decimal
-- point and the era, so a fraction is told from a longer year and BC from AD, and a whole-second AD instant
-- with a four-digit year, every stem written so far in practice, is unchanged: 2024010100000000.
--
-- Part A asserts the stem itself, exactly, including from a session whose zone and DateStyle differ (the
-- function pins both, #551). Parts B and C archive a BC day and an AD day of one table through each
-- transport, the finder's reproduction: asymmetric (two rows BC, one AD), so an object replaced by the
-- other chunk's cannot pass an identity check. The prefix carries current_database() because the bucket
-- outlives a test database, and every key is cleared and witnessed absent first.
select plan(25);

create schema t35;

create function t35.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

create function t35.clear(p_key text) returns int language plpgsql as $$
begin
  perform t35.req('DELETE', p_key);
  return (t35.req('GET', p_key)).status;
end $$;

-- The ids an NDJSON object holds, in order (null when there is no object): identity, not a count.
create function t35.ids(p_key text) returns bigint[] language plpgsql as $$
declare v http_response := t35.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

create function t35.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t35.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

-- ======================= PART A: the stem =======================

select is(archive._object_stem('time', '2024-01-01 00:00:00+00'), '2024010100000000',
  'a whole-second AD lo with a four-digit year stems as it always has');
select is(archive._object_stem('time', '2024-01-01 00:00:00+00 BC'), '2024010100000000BC',
  'a BC lo keeps its era in the stem');
select isnt(archive._object_stem('time', '2024-01-01 00:00:00+00 BC'), archive._object_stem('time', '2024-01-01 00:00:00+00'),
  '2024-01-01 BC and 2024-01-01 AD stem apart');
select is(archive._object_stem('time', '0044-03-15 12:00:00+00 BC'), '0044031512000000BC',
  'a BC year below 1000 keeps its padding and its era');
select is(archive._object_stem('time', '2024-01-01 00:00:00.1+00'), '20240101000000.100',
  'a fractional lo keeps its decimal point');
select is(archive._object_stem('time', '20240-10-10 00:00:01+00'), '20240101000000100',
  'LIVENESS: a five-digit year stems to the digits a fraction used to collapse onto');
select isnt(archive._object_stem('time', '2024-01-01 00:00:00.1+00'), archive._object_stem('time', '20240-10-10 00:00:01+00'),
  'a tenth of a second in 2024 and a whole second in 20240 stem apart');
select is(archive._object_stem('id', '-10000'), '-10000', 'an id lo is still kept whole (#502)');

set timezone = 'Asia/Karachi';
set datestyle = 'SQL, DMY';
select isnt('2024-01-01 00:00:00+00 BC'::timestamptz::text, '2024-01-01 00:00:00+00 BC',
  'LIVENESS: this session renders the BC instant in another zone and DateStyle');
select is(archive._object_stem('time', '2024-01-01 00:00:00+00 BC'), '2024010100000000BC',
  'the BC stem does not depend on the session''s zone or DateStyle');
reset timezone;
reset datestyle;

-- ======================= PART B: a BC day and an AD day of one table, NDJSON =======================

create table t35.ev (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into t35.ev values (1, '2024-01-01 01:00:00+00 BC'), (2, '2024-01-01 02:00:00+00 BC'), (3, '2024-01-01 01:00:00+00');
call pgpm.transmute('t35.ev', 'ts', interval '1 day');
select current_database() || '/t35/' as p \gset
select archive.configure('t35.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as child from pgpm.part where parent_table = 't35.ev'::regclass order by lo::timestamptz limit 1 \gset

select is((select array_agg(id order by id) from t35.ev), array[1, 2, 3]::bigint[],
  'LIVENESS: the table holds rows 1 and 2 (BC) and 3 (AD)');
select is(t35.clear(:'p' || 't35.ev_2024010100000000BC.ndjson'), 404, 'LIVENESS: no object at the BC day''s key');
select is(t35.clear(:'p' || 't35.ev_2024010100000000.ndjson'), 404, 'LIVENESS: no object at the AD day''s key');
select (pgpm.archive_to_s3_ndjson('t35.ev', :'child', '2024-01-01 00:00:00+00 BC', '2024-01-02 00:00:00+00 BC')).* \gset bc_
select (pgpm.archive_to_s3_ndjson('t35.ev', :'child', '2024-01-01 00:00:00+00', '2024-01-02 00:00:00+00')).* \gset ad_
select is(:'bc_rows_archived'::bigint, 2::bigint, 'LIVENESS: the BC day''s chunk reported two rows archived');
select is(:'ad_rows_archived'::bigint, 1::bigint, 'LIVENESS: the AD day''s chunk reported one row archived');
select is(:'bc_s3_key', :'p' || 't35.ev_2024010100000000BC.ndjson', 'the BC day''s chunk is keyed with its era');
select is(:'ad_s3_key', :'p' || 't35.ev_2024010100000000.ndjson', 'the AD day''s chunk keeps the key it always had');
select is(t35.ids(:'bc_s3_key'), array[1, 2]::bigint[], 'the object the BC chunk reported holds exactly rows 1 and 2');
select is(t35.ids(:'ad_s3_key'), array[3]::bigint[], 'the object the AD chunk reported holds exactly row 3');

-- ======================= PART C: the same pair, Parquet =======================

select is(t35.clear(:'p' || 't35.ev_2024010100000000BC.parquet'), 404, 'LIVENESS: no Parquet object at the BC day''s key');
select is(t35.clear(:'p' || 't35.ev_2024010100000000.parquet'), 404, 'LIVENESS: no Parquet object at the AD day''s key');
select (pgpm.archive_to_s3_parquet('t35.ev', :'child', '2024-01-01 00:00:00+00 BC', '2024-01-02 00:00:00+00 BC')).* \gset pbc_
select encode(t35.bytes(:'pbc_s3_key'), 'hex') as pbc_hex \gset
select (pgpm.archive_to_s3_parquet('t35.ev', :'child', '2024-01-01 00:00:00+00', '2024-01-02 00:00:00+00')).* \gset pad_
select is(:'pbc_rows_archived'::bigint, 2::bigint, 'LIVENESS: the BC day''s Parquet chunk reported two rows archived');
select is(:'pad_rows_archived'::bigint, 1::bigint, 'LIVENESS: the AD day''s Parquet chunk reported one row archived');
select is(:'pbc_s3_key', :'p' || 't35.ev_2024010100000000BC.parquet', 'the BC day''s Parquet chunk is keyed with its era');
select is(encode(t35.bytes(:'pbc_s3_key'), 'hex'), :'pbc_hex',
  'the BC day''s Parquet file is unchanged, byte for byte, after the AD day''s upload');

select * from finish();
