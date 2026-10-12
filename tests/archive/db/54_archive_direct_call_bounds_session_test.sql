-- A direct call of an archive_fn strategy names its object after the instant it READ (issue #814, the
-- archive bullet; F19-03 of review pass 12).
--
-- pgpm.archive_to_s3_ndjson and pgpm.archive_to_s3_parquet take the chunk's bounds as text. Inside one call
-- that text was parsed several times: by the range read (pgpm._encode), by the empty-range check
-- (archive._refuse_empty_range) and by the recorded-chunk check (archive._refuse_recorded_chunk_overwrite),
-- all in the CALLER's session, and by archive._object_stem, which names the object and pins TimeZone 'UTC'
-- and DateStyle 'ISO, MDY' for its own parse. A tick hands the strategy canonical ISO text with an offset,
-- which every one of those parses reads the same way. A direct call need not: from a 'SQL, DMY' session
-- '02/01/2024 00:00:00+00' is 2 January to the read and 1 February to the stem, so the 2 January rows were
-- PUT at the 1 February chunk's key, and offset-less text from a New York session was read from 05:00Z and
-- keyed from 00:00Z. The object's name misstated its rows, and it sat at the key another chunk is archived to.
--
-- Now each encoder reads the bounds ONCE, as the canonical text of what the calling session reads them as
-- (pgpm._native_text, the reading pgpm applies to an archive_fn's covered_hi, #977), and the read, the
-- recorded-chunk check and the key all take that text. The key is asserted EXACTLY, from sessions chosen so
-- that the stem's own reading of the text would name another instant, and each object by its rows.
--
-- Fixtures are asymmetric: the range as the session reads it holds two or three rows, and the range the
-- stem's reading names holds one or two others, so an object at the wrong key, or the right key over the
-- wrong rows, cannot pass an identity check. Every candidate key is cleared and witnessed absent first,
-- because the bucket outlives a test database; the prefix carries current_database().
select plan(28);

create schema t54;

create function t54.status(p_parent regclass, p_method text, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  return (archive.s3_signed_request(p_method, cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '',
                                    v_key_id, v_secret)).status;
end;
$$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t54.clear(p_parent regclass, p_key text) returns int
language plpgsql as $$
begin
  perform t54.status(p_parent, 'DELETE', p_key);
  return t54.status(p_parent, 'GET', p_key);
end;
$$;

-- The ids an NDJSON object holds, in order (null when there is no object): identity, not a count.
create function t54.ids(p_parent regclass, p_key text) returns bigint[]
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp record;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then return null; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

-- What a session on the default DateStyle and zone reads a bound text as: the reading the stem used to apply.
create function t54.default_reading(p_text text) returns text
language sql stable set timezone = 'UTC' set datestyle = 'ISO, MDY' as $$ select pgpm._ts_text(p_text::timestamptz) $$;

select current_database() || '/t54/' as p \gset

-- Two day-grid tables, one per transport, holding the same rows: ids 1 and 2 on 2 January, 3 on 1 February.
create table t54.nd (id bigint not null, ts timestamptz not null, primary key (ts, id));
create table t54.pq (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into t54.nd values (1, '2024-01-02 12:00:00+00'), (2, '2024-01-02 13:00:00+00'), (3, '2024-02-01 12:00:00+00');
insert into t54.pq select * from t54.nd;
call pgpm.transmute('t54.nd', 'ts', interval '1 day', p_paused => true);
call pgpm.transmute('t54.pq', 'ts', interval '1 day', p_paused => true);
select archive.configure('t54.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('t54.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

-- ======================= PART A: NDJSON from a 'SQL, DMY' session =======================

select is(t54.clear('t54.nd', :'p' || 't54.nd_2024010200000000.ndjson'), 404, 'LIVENESS: no object at t54.nd''s 2 January key');
select is(t54.clear('t54.nd', :'p' || 't54.nd_2024020100000000.ndjson'), 404, 'LIVENESS: no object at t54.nd''s 1 February key');

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz), '2024-01-02 00:00:00+00',
  'LIVENESS: under DateStyle SQL, DMY the session reads 02/01/2024 as 2 January');
select is(t54.default_reading('02/01/2024 00:00:00+00'), '2024-02-01 00:00:00+00',
  'LIVENESS: the same text names 1 February under the default DateStyle, so a second reading of it would differ');
select is((select array_agg(id order by id) from t54.nd where ts >= '02/01/2024 00:00:00+00' and ts < '03/01/2024 00:00:00+00'),
  array[1, 2]::bigint[], 'LIVENESS: the range [02/01/2024, 03/01/2024) as this session reads it holds ids 1 and 2');

select (pgpm.archive_to_s3_ndjson('t54.nd', null, '02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00')).* \gset nd_
reset datestyle;

select is(:'nd_rows_archived'::bigint, 2::bigint, 'the NDJSON call archived the two rows of the range it read');
select is(:'nd_s3_key'::text, :'p' || 't54.nd_2024010200000000.ndjson',
  'the NDJSON object is keyed by the 2 January the call read, not the 1 February the text names elsewhere');
select is(t54.ids('t54.nd', :'p' || 't54.nd_2024010200000000.ndjson'), array[1, 2]::bigint[],
  'the object at the 2 January key holds exactly ids 1 and 2');
select is(t54.status('t54.nd', 'GET', :'p' || 't54.nd_2024020100000000.ndjson'), 404,
  'nothing was written at the 1 February chunk''s key');

-- ======================= PART B: Parquet from a 'SQL, DMY' session =======================

select is(t54.clear('t54.pq', :'p' || 't54.pq_2024010200000000.parquet'), 404, 'LIVENESS: no object at t54.pq''s 2 January key');
select is(t54.clear('t54.pq', :'p' || 't54.pq_2024020100000000.parquet'), 404, 'LIVENESS: no object at t54.pq''s 1 February key');

set datestyle = 'SQL, DMY';
select (pgpm.archive_to_s3_parquet('t54.pq', null, '02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00')).* \gset pq_
reset datestyle;

select is(:'pq_rows_archived'::bigint, 2::bigint, 'the Parquet call archived the two rows of the range it read');
select is(:'pq_s3_key'::text, :'p' || 't54.pq_2024010200000000.parquet',
  'the Parquet object is keyed by the 2 January the call read, not the 1 February the text names elsewhere');
select is(t54.status('t54.pq', 'GET', :'p' || 't54.pq_2024010200000000.parquet'), 200,
  'the Parquet object sits at the 2 January key');
select is(t54.status('t54.pq', 'GET', :'p' || 't54.pq_2024020100000000.parquet'), 404,
  'nothing was written at the 1 February chunk''s key');

-- ======================= PART C: offset-less bounds from a New York session =======================
-- The same text in another zone names another instant: '2024-01-02 00:00:00' is 05:00Z to a New York session
-- and 00:00Z to a UTC one. Ids 1 and 2 sit inside both readings of the day, id 4 (03:00Z on 3 January) only
-- inside New York's, id 5 (02:00Z on 2 January) only inside UTC's.

create table t54.nz (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into t54.nz values (1, '2024-01-02 12:00:00+00'), (2, '2024-01-02 13:00:00+00'),
                          (4, '2024-01-03 03:00:00+00'), (5, '2024-01-02 02:00:00+00');
call pgpm.transmute('t54.nz', 'ts', interval '1 day', p_paused => true);
select archive.configure('t54.nz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.nz', :'p' || 't54.nz_2024010205000000.ndjson'), 404, 'LIVENESS: no object at t54.nz''s 05:00Z key');
select is(t54.clear('t54.nz', :'p' || 't54.nz_2024010200000000.ndjson'), 404, 'LIVENESS: no object at t54.nz''s 00:00Z key');

set timezone = 'America/New_York';
select is(pgpm._ts_text('2024-01-02 00:00:00'::timestamptz), '2024-01-02 00:00:00-05',
  'LIVENESS: a New York session reads 2024-01-02 00:00:00 as 05:00Z');
select is(t54.default_reading('2024-01-02 00:00:00'), '2024-01-02 00:00:00+00',
  'LIVENESS: the same text names 00:00Z in UTC, so a second reading of it would differ');
select is((select array_agg(id order by id) from t54.nz where ts >= '2024-01-02 00:00:00' and ts < '2024-01-03 00:00:00'),
  array[1, 2, 4]::bigint[], 'LIVENESS: the range as this session reads it holds ids 1, 2 and 4');

select (pgpm.archive_to_s3_ndjson('t54.nz', null, '2024-01-02 00:00:00', '2024-01-03 00:00:00')).* \gset nz_
reset timezone;

select is(:'nz_s3_key'::text, :'p' || 't54.nz_2024010205000000.ndjson',
  'the object is keyed by the 05:00Z the call read, not the 00:00Z the text names in UTC');
select is(t54.ids('t54.nz', :'p' || 't54.nz_2024010205000000.ndjson'), array[1, 2, 4]::bigint[],
  'the object at the 05:00Z key holds exactly ids 1, 2 and 4');
select is(t54.status('t54.nz', 'GET', :'p' || 't54.nz_2024010200000000.ndjson'), 404,
  'nothing was written at the 00:00Z key');

-- ======================= PART D: an id grid's bounds spelled with leading zeros =======================
-- The id kind reads its bounds as numbers, so '0100' is the chunk lo 100, whose key a tick writes as _100.

create table t54.id (id bigint primary key);
insert into t54.id values (150), (160), (250);
call pgpm.transmute('t54.id', 'id', 100::bigint, p_paused => true);
select archive.configure('t54.id', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.id', :'p' || 't54.id_100.ndjson'), 404, 'LIVENESS: no object at t54.id''s key for lo 100');
select is(t54.clear('t54.id', :'p' || 't54.id_0100.ndjson'), 404, 'LIVENESS: no object at the key spelled _0100');

select (pgpm.archive_to_s3_ndjson('t54.id', null, '0100', '0200')).* \gset id_

select is(:'id_s3_key'::text, :'p' || 't54.id_100.ndjson', 'the id object is keyed by the lo 100 the call read');
select is(t54.ids('t54.id', :'p' || 't54.id_100.ndjson'), array[150, 160]::bigint[],
  'the object at the key for lo 100 holds exactly ids 150 and 160');
select is(t54.status('t54.id', 'GET', :'p' || 't54.id_0100.ndjson'), 404,
  'nothing was written at a key spelled the way the call spelled its lo');

select * from finish();
