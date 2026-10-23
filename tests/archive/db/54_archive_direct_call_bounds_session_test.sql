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
-- Now each encoder reads the bounds ONCE, as the canonical text of what the GRID reads them as
-- (archive._grid_bound: pgpm._native_text, the reading pgpm applies to an archive_fn's covered_hi (#977), on
-- the grid's clock, config.partition_tz, with the caller's DateStyle, and on a date column the start of the day
-- the instant falls in, which is what a date makes of a bound), and the empty-range check, the read, the
-- recorded-chunk check and the key all take that text. Offset-less text is read in partition_tz, never the
-- caller's TimeZone: read in the caller's zone (the first cut of this fix, V-01 of its verification),
-- '2024-01-02' on a date-column day grid was 05:00Z from New York, a key no cell starts at, while the date
-- column read the whole 2 January cell, and the same chunk got the cell's own key from UTC. The key is asserted
-- EXACTLY, from sessions chosen so that another reading of the text would name another instant, and each object
-- by its rows.
--
-- Parts G to I are the second cut's (round 2 of the verification). The empty-range check (#969) was still
-- asked of the caller's text in the caller's session, so a range the session read as holding something and
-- the grid read as empty or inverted was admitted and PUT an empty object at a live cell's key (G: an
-- offset-less hi that is the lo on the grid's clock; G2: two wall times either side of a DST gap). On a date
-- grid the key was the stem of the lo's instant while the read covered the day it falls in (H). And the
-- recorded-chunk check reads the ledger's bounds the way the call's own were read (I).
--
-- Fixtures are asymmetric: the range as the session reads it holds two or three rows, and the range the
-- stem's reading names holds one or two others, so an object at the wrong key, or the right key over the
-- wrong rows, cannot pass an identity check. Every candidate key is cleared and witnessed absent first,
-- because the bucket outlives a test database; the prefix carries current_database(). Every "nothing was
-- written at the key" is paired with a CONTROL that the same lo, with a hi the grid reads later, writes there.
select plan(77);

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

-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/16, so a Parquet object reads back as the bytes that were PUT.
create function t54.object(p_parent regclass, p_key text) returns bytea
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp record;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then return null; end if;
  return text_to_bytea(v_resp.content);
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
-- by its rows, as the NDJSON one is (#1376): byte for byte the file of the 2 January cell, ids 1 and 2
select ok(t54.object('t54.pq', :'p' || 't54.pq_2024010200000000.parquet')
          = archive._pq_to_parquet_range('t54.pq', 'ts', '2024-01-02 00:00:00+00', '2024-01-03 00:00:00+00',
                                         (select compress from archive.config where parent_table = 't54.pq'::regclass)),
  'the Parquet object at the 2 January key is byte for byte the file of the 2 January rows, ids 1 and 2');
select is(t54.status('t54.pq', 'GET', :'p' || 't54.pq_2024020100000000.parquet'), 404,
  'nothing was written at the 1 February chunk''s key');

-- ======================= PART C: offset-less bounds from a New York session =======================
-- Offset-less text is read on the grid's clock (partition_tz, UTC here), not the caller's zone: '2024-01-02
-- 00:00:00' is 00:00Z to the grid and 05:00Z to a New York session. Ids 1 and 2 sit inside both readings of the
-- day, id 5 (02:00Z on 2 January) only inside the grid's, id 4 (03:00Z on 3 January) only inside New York's.

create table t54.nz (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into t54.nz values (1, '2024-01-02 12:00:00+00'), (2, '2024-01-02 13:00:00+00'),
                          (4, '2024-01-03 03:00:00+00'), (5, '2024-01-02 02:00:00+00');
set timezone = 'UTC';
call pgpm.transmute('t54.nz', 'ts', interval '1 day', p_paused => true);
reset timezone;
select archive.configure('t54.nz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.nz', :'p' || 't54.nz_2024010205000000.ndjson'), 404, 'LIVENESS: no object at t54.nz''s 05:00Z key');
select is(t54.clear('t54.nz', :'p' || 't54.nz_2024010200000000.ndjson'), 404, 'LIVENESS: no object at t54.nz''s 00:00Z key');
select is((select partition_tz from pgpm.config where parent_table = 't54.nz'::regclass), 'UTC',
  'LIVENESS: t54.nz''s grid runs on UTC, so its day cells start at 00:00Z');
select is((select array_agg(id order by id) from t54.nz where ts >= '2024-01-02 00:00:00+00' and ts < '2024-01-03 00:00:00+00'),
  array[1, 2, 5]::bigint[], 'LIVENESS: the range as the grid reads it holds ids 1, 2 and 5');

set timezone = 'America/New_York';
select is(pgpm._ts_text('2024-01-02 00:00:00'::timestamptz), '2024-01-02 00:00:00-05',
  'LIVENESS: a New York session reads 2024-01-02 00:00:00 as 05:00Z, so its own reading would differ from the grid''s');
select is((select array_agg(id order by id) from t54.nz where ts >= '2024-01-02 00:00:00' and ts < '2024-01-03 00:00:00'),
  array[1, 2, 4]::bigint[], 'LIVENESS: the range as this session reads it holds ids 1, 2 and 4');

select (pgpm.archive_to_s3_ndjson('t54.nz', null, '2024-01-02 00:00:00', '2024-01-03 00:00:00')).* \gset nz_
reset timezone;

select is(:'nz_s3_key'::text, :'p' || 't54.nz_2024010200000000.ndjson',
  'the object is keyed by the 00:00Z the grid reads, not the 05:00Z the caller''s zone reads');
select is(t54.ids('t54.nz', :'p' || 't54.nz_2024010200000000.ndjson'), array[1, 2, 5]::bigint[],
  'the object at the 00:00Z key holds exactly ids 1, 2 and 5, the rows of the range the key names');
select is(t54.status('t54.nz', 'GET', :'p' || 't54.nz_2024010205000000.ndjson'), 404,
  'nothing was written at the 05:00Z key');

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

-- ======================= PART E: a date-column day grid from New York and from UTC, NDJSON =======================
-- A date column's grid runs on UTC (partition_tz), and its read truncates a bound to the date, so '2024-01-02'
-- reads the whole 2 January cell from any session. The key must name that cell's start, 00:00Z, from every
-- session: read in the caller's zone, New York's call was keyed 05:00Z (V-01), a key no cell starts at.

create table t54.dd (id bigint not null, d date not null, primary key (d, id));
insert into t54.dd values (1, '2024-01-02'), (2, '2024-01-02'), (3, '2024-01-03');
call pgpm.transmute('t54.dd', 'd', interval '1 day', p_paused => true);
select archive.configure('t54.dd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.dd', :'p' || 't54.dd_2024010200000000.ndjson'), 404, 'LIVENESS: no object at t54.dd''s 2 January cell key');
select is(t54.clear('t54.dd', :'p' || 't54.dd_2024010205000000.ndjson'), 404, 'LIVENESS: no object at t54.dd''s 05:00Z key');
select is((select partition_tz from pgpm.config where parent_table = 't54.dd'::regclass), 'UTC',
  'LIVENESS: a date grid runs on UTC, so 2 January''s cell starts at 00:00Z and none starts at 05:00Z');

set timezone = 'America/New_York';
select is(pgpm._ts_text('2024-01-02'::timestamptz), '2024-01-02 00:00:00-05',
  'LIVENESS: a New York session reads 2024-01-02 as 05:00Z');
select (pgpm.archive_to_s3_ndjson('t54.dd', null, '2024-01-02', '2024-01-03')).* \gset ddny_
reset timezone;
select is(:'ddny_rows_archived'::bigint, 2::bigint, 'LIVENESS: the New York call read the whole 2 January cell (ids 1 and 2)');

select is(:'ddny_s3_key'::text, :'p' || 't54.dd_2024010200000000.ndjson',
  'the 2 January cell archived from New York is keyed by the cell''s start, 00:00Z');
select is(t54.status('t54.dd', 'GET', :'p' || 't54.dd_2024010205000000.ndjson'), 404,
  'nothing lands at a 05:00Z key no cell of the day grid starts at');

set timezone = 'UTC';
select (pgpm.archive_to_s3_ndjson('t54.dd', null, '2024-01-02', '2024-01-03')).* \gset ddutc_
reset timezone;
select is(:'ddutc_s3_key'::text, :'ddny_s3_key'::text,
  'the same cell gets the same key from a UTC session as from a New York one');
select is(t54.ids('t54.dd', :'p' || 't54.dd_2024010200000000.ndjson'), array[1, 2]::bigint[],
  'the object at the cell''s key holds exactly ids 1 and 2');

-- ======================= PART F: a naive-timestamp day grid from New York and from UTC, Parquet =======================
-- The Parquet encoder takes no date column, so its half runs on a timestamp (without time zone) column, the other
-- naive kind: its grid runs on UTC as well, and '2024-01-02' is the 2 January cell's start on the grid's clock.

create table t54.dp (id bigint not null, t timestamp not null, primary key (t, id));
insert into t54.dp values (1, '2024-01-02 12:00'), (2, '2024-01-02 13:00'), (3, '2024-01-03 12:00');
call pgpm.transmute('t54.dp', 't', interval '1 day', p_paused => true);
select archive.configure('t54.dp', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.dp', :'p' || 't54.dp_2024010200000000.parquet'), 404, 'LIVENESS: no object at t54.dp''s 2 January cell key');
select is(t54.clear('t54.dp', :'p' || 't54.dp_2024010205000000.parquet'), 404, 'LIVENESS: no object at t54.dp''s 05:00Z key');

set timezone = 'America/New_York';
select (pgpm.archive_to_s3_parquet('t54.dp', null, '2024-01-02', '2024-01-03')).* \gset dpny_
reset timezone;
select is(:'dpny_rows_archived'::bigint, 2::bigint, 'LIVENESS: the New York Parquet call read ids 1 and 2 of the 2 January cell');

select is(:'dpny_s3_key'::text, :'p' || 't54.dp_2024010200000000.parquet',
  'the 2 January cell archived to Parquet from New York is keyed by the cell''s start, 00:00Z');
select is(t54.status('t54.dp', 'GET', :'p' || 't54.dp_2024010205000000.parquet'), 404,
  'nothing lands at a 05:00Z Parquet key no cell starts at');

set timezone = 'UTC';
select (pgpm.archive_to_s3_parquet('t54.dp', null, '2024-01-02', '2024-01-03')).* \gset dputc_
reset timezone;
select is(:'dputc_s3_key'::text, :'dpny_s3_key'::text,
  'the same cell gets the same Parquet key from a UTC session as from a New York one');

-- The strategy's key and row count, or the error it raised: one value for a call that must be carried out.
create function t54.try(p_fmt text, p_parent regclass, p_lo text, p_hi text) returns text
language plpgsql as $$
declare r pgpm.archive_result;
begin
  if p_fmt = 'ndjson' then r := pgpm.archive_to_s3_ndjson(p_parent, null, p_lo, p_hi);
  else r := pgpm.archive_to_s3_parquet(p_parent, null, p_lo, p_hi); end if;
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end;
$$;

-- ======================= PART G: a range that is empty on the grid's clock, NDJSON =======================
-- #969 refuses an empty or inverted range, because the key is derived from lo alone and an empty read PUTs an
-- empty object at the chunk's key. "Empty" is judged on the reading the call goes on to read (per-PR
-- verification round 2, V-01). On a grid whose clock is Asia/Kolkata a UTC caller's
-- ['2024-01-02 18:30:00+00', '2024-01-03') holds ids 1 and 2 as the session reads it, and is empty on the
-- grid's clock: the offset-less hi is 00:00 in Kolkata, which is 18:30Z on 2 January, the lo. The cell the
-- key names holds ids 1 and 2; id 3 is in the next one.

create table t54.kz (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into t54.kz values (1, '2024-01-02 20:00:00+00'), (2, '2024-01-02 21:00:00+00'), (3, '2024-01-03 20:00:00+00');
set timezone = 'Asia/Kolkata';
call pgpm.transmute('t54.kz', 'ts', interval '1 day', p_paused => true);
set timezone = 'UTC';
select archive.configure('t54.kz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is((select partition_tz from pgpm.config where parent_table = 't54.kz'::regclass), 'Asia/Kolkata',
  'LIVENESS: (G) t54.kz''s grid runs on Asia/Kolkata');
select is(t54.clear('t54.kz', :'p' || 't54.kz_2024010218300000.ndjson'), 404,
  'LIVENESS: (G) no object at the key of the cell that starts at 18:30Z on 2 January');
select is((select array_agg(id order by id) from t54.kz where ts >= '2024-01-02 18:30:00+00' and ts < '2024-01-03'),
  array[1, 2]::bigint[], 'LIVENESS: (G) the range as this UTC session reads it holds ids 1 and 2, so the session does not read it as empty');
select is(pgpm._ts_text('2024-01-03'::timestamp at time zone 'Asia/Kolkata'), '2024-01-02 18:30:00+00',
  'LIVENESS: (G) on the grid''s clock the offset-less hi 2024-01-03 is 18:30Z on 2 January, the lo: the range is empty there');

select throws_like(
  $$ select * from pgpm.archive_to_s3_ndjson('t54.kz', null, '2024-01-02 18:30:00+00', '2024-01-03') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses the range [2024-01-02 18:30:00+00, 2024-01-02 18:30:00+00) of t54.kz -- it is empty or inverted%',
  '(G) a range empty on the grid''s clock is refused, naming the bounds as the call read them');
select is(t54.status('t54.kz', 'GET', :'p' || 't54.kz_2024010218300000.ndjson'), 404,
  '(G) no empty object was written at the cell''s key');
select is(t54.try('ndjson', 't54.kz', '2024-01-02 18:30:00+00', '2024-01-04'),
  :'p' || 't54.kz_2024010218300000.ndjson rows=2',
  'CONTROL: (G) with a hi the grid reads a day later, the same lo archives the cell''s two rows at that key');
select is(t54.ids('t54.kz', :'p' || 't54.kz_2024010218300000.ndjson'), array[1, 2]::bigint[],
  'CONTROL: (G) the object at the cell''s key holds exactly ids 1 and 2');
reset timezone;

-- ======================= PART G2: a range the grid reads inverted, across a DST gap, Parquet =======================
-- The same judgement where the two clocks ORDER the bounds differently (P1-02): on a 30-minute grid whose clock
-- is America/New_York, 02:30 on 10 March 2024 is inside the spring-forward gap and reads as 03:30 EDT (07:30Z),
-- while 03:00 reads as 03:00 EDT (07:00Z). A UTC session reads ['2024-03-10 02:30:00', '2024-03-10 03:00:00')
-- as a half hour holding ids 2 and 3; the grid reads [07:30Z, 07:00Z). The cell the lo names holds id 1.

create table t54.gp (id bigint not null, ts timestamptz not null, primary key (ts, id));
insert into t54.gp values (1, '2024-03-10 07:40:00+00'), (2, '2024-03-10 02:40:00+00'), (3, '2024-03-10 02:50:00+00');
set timezone = 'America/New_York';
call pgpm.transmute('t54.gp', 'ts', interval '30 minutes', p_paused => true);
set timezone = 'UTC';
select archive.configure('t54.gp', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is((select partition_tz from pgpm.config where parent_table = 't54.gp'::regclass), 'America/New_York',
  'LIVENESS: (G2) t54.gp''s grid runs on America/New_York');
select is(t54.clear('t54.gp', :'p' || 't54.gp_2024031007300000.parquet'), 404,
  'LIVENESS: (G2) no object at the key of the cell [07:30Z, 08:00Z)');
select is((select array_agg(id order by id) from t54.gp where ts >= '2024-03-10 02:30:00' and ts < '2024-03-10 03:00:00'),
  array[2, 3]::bigint[], 'LIVENESS: (G2) the range as this UTC session reads it holds ids 2 and 3');
select is(pgpm._ts_text('2024-03-10 02:30:00'::timestamp at time zone 'America/New_York') || ' / '
          || pgpm._ts_text('2024-03-10 03:00:00'::timestamp at time zone 'America/New_York'),
  '2024-03-10 07:30:00+00 / 2024-03-10 07:00:00+00',
  'LIVENESS: (G2) on the grid''s clock the lo is 07:30Z and the hi 07:00Z, below it');

select throws_like(
  $$ select * from pgpm.archive_to_s3_parquet('t54.gp', null, '2024-03-10 02:30:00', '2024-03-10 03:00:00') $$,
  'pg_partition_magician: archive_to_s3_parquet refuses the range [2024-03-10 07:30:00+00, 2024-03-10 07:00:00+00) of t54.gp -- it is empty or inverted%',
  '(G2) a range the grid reads inverted is refused, naming the bounds as the call read them');
select is(t54.status('t54.gp', 'GET', :'p' || 't54.gp_2024031007300000.parquet'), 404,
  '(G2) no empty object was written at the key of the live cell [07:30Z, 08:00Z)');
select is(t54.try('parquet', 't54.gp', '2024-03-10 03:30:00', '2024-03-10 04:00:00'),
  :'p' || 't54.gp_2024031007300000.parquet rows=1',
  'CONTROL: (G2) the half hour the grid reads as [07:30Z, 08:00Z) archives id 1''s row at that key');
reset timezone;

-- ======================= PART H: a date grid's key names the cell the read covers =======================
-- A date column keeps a bound's day and drops the rest, so a bound that is not a day start still reads whole
-- days (V-02). A Tokyo caller's own midnight with its offset, '2024-01-02 00:00:00+09', is 15:00Z on 1 January:
-- the read covers the whole 1 January cell (id 1), and the key names that cell, not 15:00Z, where no cell
-- starts. And two instants of one day are no range at all to the column: ['2024-01-02 03:00', '2024-01-02 18:00')
-- reads no row, so it is refused as empty. Id 1 on 1 January, ids 2 and 3 on 2 January.

create table t54.dt (id bigint not null, d date not null, primary key (d, id));
insert into t54.dt values (1, '2024-01-01'), (2, '2024-01-02'), (3, '2024-01-02');
call pgpm.transmute('t54.dt', 'd', interval '1 day', p_paused => true);
select archive.configure('t54.dt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select is(t54.clear('t54.dt', :'p' || 't54.dt_2024010100000000.ndjson'), 404, 'LIVENESS: (H) no object at the 1 January cell''s key');
select is(t54.clear('t54.dt', :'p' || 't54.dt_2024010115000000.ndjson'), 404, 'LIVENESS: (H) no object at the 15:00Z key');
select is(t54.clear('t54.dt', :'p' || 't54.dt_2024010200000000.ndjson'), 404, 'LIVENESS: (H) no object at the 2 January cell''s key');
select is(t54.clear('t54.dt', :'p' || 't54.dt_2024010203000000.ndjson'), 404, 'LIVENESS: (H) no object at the 03:00Z key');

set timezone = 'Asia/Tokyo';
select is(to_char('2024-01-02 00:00:00+09'::timestamptz at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), '2024-01-01 15:00',
  'LIVENESS: (H) the lo is 15:00 UTC on 1 January, inside the 1 January cell and not at its start');
select is((select array_agg(id order by id) from t54.dt where d >= '2024-01-01 15:00:00' and d < '2024-01-02 15:00:00'),
  array[1]::bigint[], 'LIVENESS: (H) the date column reads those two bounds as the whole 1 January cell: id 1 alone');
select is(t54.try('ndjson', 't54.dt', '2024-01-02 00:00:00+09', '2024-01-03 00:00:00+09'),
  :'p' || 't54.dt_2024010100000000.ndjson rows=1',
  '(H) the chunk the read covers is keyed by the 1 January cell''s start, from a Tokyo session');
reset timezone;
select is(t54.ids('t54.dt', :'p' || 't54.dt_2024010100000000.ndjson'), array[1]::bigint[],
  '(H) the object at the 1 January cell''s key holds exactly id 1');
select is(t54.status('t54.dt', 'GET', :'p' || 't54.dt_2024010115000000.ndjson'), 404,
  '(H) nothing was written at the 15:00Z key, where no cell starts');

set timezone = 'UTC';
select ok('2024-01-02 18:00:00+00'::timestamptz > '2024-01-02 03:00:00+00'::timestamptz
          and (select array_agg(id) from t54.dt where d >= '2024-01-02 03:00:00' and d < '2024-01-02 18:00:00') is null,
  'LIVENESS: (H) 03:00Z to 18:00Z on 2 January is a range of instants, and no row to the date column');
select throws_like(
  $$ select * from pgpm.archive_to_s3_ndjson('t54.dt', null, '2024-01-02 03:00:00+00', '2024-01-02 18:00:00+00') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses the range [2024-01-02 00:00:00+00, 2024-01-02 00:00:00+00) of t54.dt -- it is empty or inverted%',
  '(H) two instants of one day are refused as an empty range, named as the date column reads them');
select is(t54.status('t54.dt', 'GET', :'p' || 't54.dt_2024010200000000.ndjson') || '/'
          || t54.status('t54.dt', 'GET', :'p' || 't54.dt_2024010203000000.ndjson'), '404/404',
  '(H) no empty object was written at the 2 January cell''s key, nor at the 03:00Z one');
select is(t54.try('ndjson', 't54.dt', '2024-01-02 03:00:00+00', '2024-01-03 18:00:00+00'),
  :'p' || 't54.dt_2024010200000000.ndjson rows=2',
  'CONTROL: (H) with a hi on the next day the same lo archives the 2 January cell''s two rows at the cell''s key');
select is(t54.ids('t54.dt', :'p' || 't54.dt_2024010200000000.ndjson'), array[2, 3]::bigint[],
  'CONTROL: (H) the object at the 2 January cell''s key holds exactly ids 2 and 3');

-- ======================= PART I: the recorded chunk's bounds are read the same way =======================
-- The recorded-chunk check (#975) admits a write at a recorded chunk's key only for the chunk's own [lo, hi).
-- The call's bounds reach it as the grid reads them, so the ledger's are read the same way. They differ from
-- their own reading only on a date grid an install before #769 anchored off 00:00 UTC, where a tick's chunk is
-- recorded [2 January 12:00Z, 3 January 12:00Z) and read, and keyed, as the dates [2 January, 3 January): the
-- ledger row below is the one such a tick writes for the object PART H's control just put at the cell's key.

insert into pgpm.archive_ledger (parent_table, lo, hi, s3_key, rows_archived)
  values ('t54.dt', '2024-01-02 12:00:00+00', '2024-01-03 12:00:00+00', :'p' || 't54.dt_2024010200000000.ndjson', 2);
select is((select lo || ' / ' || hi || ' / ' || rows_archived from pgpm.archive_ledger
            where parent_table = 't54.dt'::regclass and s3_key = :'p' || 't54.dt_2024010200000000.ndjson'),
  '2024-01-02 12:00:00+00 / 2024-01-03 12:00:00+00 / 2',
  'LIVENESS: (I) the ledger records a chunk of 2 rows at the 2 January cell''s key, its bounds at 12:00Z');
select throws_like(
  $$ select * from pgpm.archive_to_s3_ndjson('t54.dt', null, '2024-01-02 12:00:00+00', '2024-01-04 12:00:00+00') $$,
  '%pgpm.archive_ledger records the chunk [2024-01-02 12:00:00+00, 2024-01-03 12:00:00+00) of 2 row(s) there, and this call''s range is not that chunk''s%',
  '(I) another range aimed at the recorded chunk''s key is refused, naming the chunk''s bounds as recorded');
select is(t54.try('ndjson', 't54.dt', '2024-01-02 12:00:00+00', '2024-01-03 12:00:00+00'),
  :'p' || 't54.dt_2024010200000000.ndjson rows=2',
  '(I) the chunk''s own recorded [lo, hi) is its re-run: read, keyed and compared as the dates it covers');
select is(t54.ids('t54.dt', :'p' || 't54.dt_2024010200000000.ndjson'), array[2, 3]::bigint[],
  '(I) the object at the cell''s key still holds exactly ids 2 and 3');
reset timezone;

select * from finish();
