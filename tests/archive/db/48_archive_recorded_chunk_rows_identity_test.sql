-- An archive_fn strategy writes over the object pgpm.archive_ledger records a chunk at only when its read finds
-- the rows the chunk recorded, by their identity and not their number (#1069, pass 10 F5-03).
--
-- THE DEFECT. #975's archive._refuse_recorded_chunk_overwrite admitted a call at a recorded chunk's key when
-- the range matched and the read's row COUNT equalled the ledger's rows_archived. That is a proxy for "the rows
-- the chunk recorded" only while the chunk's write-blocked partition lives. After retire() dropped it (the
-- object is then the only copy), a partition re-created over the range by plain DDL, holding the same number of
-- DIFFERENT rows, let a direct pgpm.archive_to_s3_ndjson / _parquet call PUT those rows over the only copy.
--
-- THE CONTRACT. Every write a strategy makes records, on the key's whole-key claim, a digest of the rows it
-- wrote, rendered under pinned settings so it does not depend on the caller's session. A later call at a key the
-- ledger records a chunk at is written only when its read's digest is the recorded one; a different set of rows
-- is refused before the PUT, and so is a key whose claim records no digest (a chunk archived before the digest
-- existed), since nothing then shows the read's rows are the chunk's.
--
-- IDENTITY AND ASYMMETRY. The NDJSON chunk holds 90 rows and its re-created range 90 rows that ALL differ; the
-- Parquet chunk holds 70 and its re-created range 70 of which ONE differs, so a check that looked at any single
-- row, or at the count, would not pass both. Each refusal is followed by reading the object back (the NDJSON one
-- by its rows' ids and payloads, the Parquet one by its bytes), and each object is first shown to hold what its
-- chunk recorded (LIVENESS). CONTROLS: a re-run of the live chunk from a session in another time zone and from
-- another search_path (t48.nd carries a regclass, which a search_path reaching its schema renders unqualified),
-- and a re-run after retire() over a range holding exactly the chunk's rows again, are all written, so the
-- refusal is about the rows, not about the caller's session, and not a blanket one after retire().
-- bench/archive_recorded_chunk_rows_identity.sh runs this file against the module's mutants.
set client_min_messages = warning;
select plan(37);

create schema t48;

create function t48.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- what an NDJSON object holds, as 'id:payload' items sorted by id (null when there is no object)
create function t48.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t48.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
-- an object's bytes (null when there is none)
create function t48.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t48.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;
-- a strategy's answer for [lo, hi) of a table as '<rows> <key>', or the error it raised
create function t48.try(p_fmt text, p_parent text, p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  execute format('select * from pgpm.archive_to_s3_%s(%L, %L, %L, %L)', p_fmt, p_parent, 'unused', p_lo, p_hi) into r;
  return r.rows_archived || ' ' || r.s3_key;
exception when others then
  return sqlerrm;
end $$;
-- the 'id:payload' items ids p_from..p_to were seeded with
create function t48.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;
-- the rows a table's range [0, 100) is seeded with: id, its payload, and an instant a session's zone renders
create function t48.seed(p_tag text, p_n int) returns table(id bigint, payload text, at timestamptz) language sql immutable as $$
  select g::bigint, p_tag || g, timestamptz '2024-01-01 00:00:00+00' + g * interval '1 minute' from generate_series(1, p_n) g $$;

select current_database() || '/t48/' || txid_current() || '/' as p \gset

-- Two id grids of step 100, retention 100, each with one chunk below the horizon: [0, 100) holds ids 1..90 of
-- t48.nd (archived as NDJSON) and ids 1..70 of t48.pq (as Parquet). A frontier at 450 puts the horizon at 300.
-- retain_batch = 0 holds retire() off until the live half of the test is done.
-- every NDJSON row also names a relation, as a regclass, whose text output follows the session's search_path
create table t48.target ();
create table t48.nd (id bigint primary key, payload text not null, at timestamptz not null,
                     ref regclass not null default 't48.target');
insert into t48.nd select * from t48.seed('n', 90);
call pgpm.transmute('t48.nd', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t48.nd values (450, 'frontier', '2024-06-01 00:00:00+00');
select archive.configure('t48.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 't48.nd'::regclass;
select pgpm.set_archive_fn('t48.nd', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

create table t48.pq (id bigint primary key, payload text not null, at timestamptz not null);
insert into t48.pq select * from t48.seed('q', 70);
call pgpm.transmute('t48.pq', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t48.pq values (450, 'frontier', '2024-06-01 00:00:00+00');
select archive.configure('t48.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 't48.pq'::regclass;
select pgpm.set_archive_fn('t48.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

create temp table t48_child as
  select parent_table::text as parent, child_name from pgpm.part
   where parent_table in ('t48.nd'::regclass, 't48.pq'::regclass) and lo = '0';

call pgpm.maintain('t48.nd');
call pgpm.maintain('t48.pq');

select (select s3_key from pgpm.archive_ledger where parent_table = 't48.nd'::regclass and lo = '0') as knd,
       (select s3_key from pgpm.archive_ledger where parent_table = 't48.pq'::regclass and lo = '0') as kpq \gset
create temp table t48_pq_tick as
  select t48.bytes(:'kpq') as b, (select etag from pgpm.archive_ledger where parent_table = 't48.pq'::regclass and lo = '0') as etag;

-- ======================================================================================================
-- Setup witnesses
-- ======================================================================================================
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived, '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t48.nd'::regclass, 't48.pq'::regclass)),
  't48.nd [0, 100) 90; t48.pq [0, 100) 70',
  'LIVENESS: maintain() archived [0, 100) of each table as one chunk, ledgered with its row count');
select is(t48.rows(:'knd'), t48.expect('n', 1, 90),
  'LIVENESS: the NDJSON chunk''s object holds exactly ids 1..90 of t48.nd');
select ok((select octet_length(b) > 0 and md5(b) = btrim(etag, '"') from t48_pq_tick),
  'LIVENESS: the Parquet chunk''s object holds the bytes its PUT wrote (their md5 is the ledgered ETag)');

-- ======================================================================================================
-- CONTROL: the re-run of a live chunk is admitted, whatever the caller's session renders
-- ======================================================================================================
-- the documented re-run, from a session whose zone renders t48.*.at another way than the tick's did
set timezone = 'Asia/Karachi';
select is(t48.try('ndjson', 't48.nd', '0', '100'), '90 ' || :'knd',
  'CONTROL: a re-run of the live chunk''s own [0, 100) from another time zone is written (90 rows, the same key)');
select is(t48.try('parquet', 't48.pq', '0', '100'), '70 ' || :'kpq',
  'CONTROL: the same for the Parquet strategy (70 rows, the same key)');
reset timezone;
-- and from a session whose search_path reaches t48, where every row's regclass renders as target, not t48.target
set search_path = t48, public;
select is((select row_to_json(n.*) ->> 'ref' from t48.nd n where n.id = 1), 'target',
  'LIVENESS: under search_path t48 the chunk''s rows render their regclass unqualified (target, not t48.target)');
select is(t48.try('ndjson', 't48.nd', '0', '100'), '90 ' || :'knd',
  'CONTROL: a re-run of the live chunk''s own [0, 100) from that search_path is written (90 rows, the same key)');
reset search_path;
select is(t48.rows(:'knd'), t48.expect('n', 1, 90),
  'CONTROL: the re-run left the NDJSON object holding exactly ids 1..90');
-- the Parquet object as the re-run left it, which is what retire() leaves as the only copy
create temp table t48_pq_rerun as select t48.bytes(:'kpq') as b;
select ok((select octet_length(b) > 0 from t48_pq_rerun),
  'CONTROL: the re-run left a Parquet object at the key');

-- ======================================================================================================
-- retire() drops the partitions; the objects are the only copies
-- ======================================================================================================
update pgpm.config set retain_batch = null where parent_table in ('t48.nd'::regclass, 't48.pq'::regclass);
call pgpm.maintain('t48.nd');
call pgpm.maintain('t48.pq');

select is((select count(*)::int from t48_child c where to_regclass('t48.' || quote_ident(c.child_name)) is null), 2,
  'LIVENESS: retire() dropped both archived partitions, so each object is the only copy of its chunk''s rows');
select is((select count(*)::int from t48.nd where id < 100) + (select count(*)::int from t48.pq where id < 100), 0,
  'LIVENESS: no row of either chunk is left in its table');

-- Partitions re-created over the retired range by plain DDL, holding as many rows as each chunk recorded:
-- t48.nd 90 rows of which every payload differs, t48.pq 70 rows of which only id 70's payload differs.
create table t48.nd_redo partition of t48.nd for values from (0) to (100);
insert into t48.nd select id, 'X' || id, at from t48.seed('n', 90);
create table t48.pq_redo partition of t48.pq for values from (0) to (100);
insert into t48.pq select id, case when id = 70 then 'Q70' else payload end, at from t48.seed('q', 70);

select is((select count(*)::int from t48.nd where id >= 0 and id < 100), 90,
  'LIVENESS: [0, 100) of t48.nd now reads 90 rows, the number the chunk recorded');
select is((select string_agg(id || ':' || payload, ',' order by id) from t48.nd where id >= 0 and id < 100), t48.expect('X', 1, 90),
  'LIVENESS: and none of them is a row the chunk recorded (ids 1..90, every payload X)');
select is((select count(*)::int from t48.pq where id >= 0 and id < 100), 70,
  'LIVENESS: [0, 100) of t48.pq now reads 70 rows, the number the chunk recorded');
select is((select string_agg(id::text, ',' order by id) from t48.pq p
            where p.id >= 0 and p.id < 100
              and not exists (select 1 from t48.seed('q', 70) s where s.id = p.id and s.payload = p.payload and s.at = p.at)),
  '70', 'LIVENESS: and exactly one of them, id 70, is not a row the chunk recorded');

-- ======================================================================================================
-- #1069: the same number of other rows is refused
-- ======================================================================================================
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t48.nd', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 100) of t48.nd to the object key ' || :'knd'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 90 row(s) there, and the read found 90 row(s) in it now, but not the rows the chunk recorded%',
  'archive_to_s3_ndjson refuses the retired chunk''s own [0, 100) over 90 other rows, naming the recorded chunk and the key');
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t48.pq', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_parquet refuses to write [0, 100) of t48.pq to the object key ' || :'kpq'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 70 row(s) there, and the read found 70 row(s) in it now, but not the rows the chunk recorded%',
  'archive_to_s3_parquet refuses it over 70 rows of which one differs');
select is(t48.rows(:'knd'), t48.expect('n', 1, 90),
  'the NDJSON object the retired chunk was archived to still holds exactly ids 1..90 with their own payloads');
select ok(t48.bytes(:'kpq') = (select b from t48_pq_rerun),
  'the Parquet object the retired chunk was archived to still holds the bytes its last admitted write left');

-- ======================================================================================================
-- CONTROL: the chunk's own rows again are the chunk, so they are written
-- ======================================================================================================
delete from t48.nd where id >= 0 and id < 100;
insert into t48.nd select * from t48.seed('n', 90);
update t48.pq set payload = 'q70' where id = 70;
select is((select string_agg(id || ':' || payload, ',' order by id) from t48.nd where id >= 0 and id < 100), t48.expect('n', 1, 90),
  'LIVENESS: [0, 100) of t48.nd holds exactly the chunk''s rows again');
select is(t48.try('ndjson', 't48.nd', '0', '100'), '90 ' || :'knd',
  'CONTROL: a call whose read finds exactly the chunk''s rows is written (90 rows, the same key)');
select is(t48.try('parquet', 't48.pq', '0', '100'), '70 ' || :'kpq',
  'CONTROL: the same for the Parquet strategy, once id 70 is the chunk''s row again');
select is(t48.rows(:'knd'), t48.expect('n', 1, 90),
  'CONTROL: the NDJSON object still holds exactly ids 1..90 with their own payloads');
select ok(t48.bytes(:'kpq') = (select b from t48_pq_rerun),
  'CONTROL: the Parquet object written from the chunk''s own rows is byte for byte the one the live re-run wrote');

-- ======================================================================================================
-- A chunk whose claim records no digest (archived before it existed) is not written over
-- ======================================================================================================
-- What an upgrade leaves: install seeds the whole-key claim of every key the ledger records
-- (archive._claim_archived_keys), and such a claim has no digest.
delete from archive.object_key_claim where object_key = :'knd';
select is(archive._claim_archived_keys(), 1,
  'LIVENESS: the install seed claims the NDJSON chunk''s key again, as it claims a key archived before this release');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t48.nd', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 100) of t48.nd to the object key ' || :'knd'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 90 row(s) there, and no digest of the rows written there is recorded%',
  'a call at a recorded chunk whose claim records no digest is refused, even with the chunk''s rows');
-- the refused call left no digest behind: the same call is refused again
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t48.nd', 'unused', '0', '100') $$,
  '%and no digest of the rows written there is recorded%',
  'and a refusal records none, so the next call is refused the same way');
select is(t48.rows(:'knd'), t48.expect('n', 1, 90),
  'the NDJSON object is untouched by the refused calls');

-- ======================================================================================================
-- A column named after the digest's row alias does not shadow the row (#821's shape, review P1-02)
-- ======================================================================================================
-- The Parquet digest reads its snapshot under the alias s and the NDJSON one its parent under the alias t. A bare
-- alias resolves as a COLUMN first, so a table with a column of that name would have its digest taken of that
-- column, or raise on every tick, and never be archived or retired. One table of each, asymmetric (60 rows as
-- Parquet with a column s, 40 as NDJSON with a column t), archived and retired by maintain() alone.
create table t48.ps (id bigint primary key, s text not null);
insert into t48.ps select g, 's' || g from generate_series(1, 60) g;
call pgpm.transmute('t48.ps', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t48.ps values (450, 'frontier');
select archive.configure('t48.ps', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t48.ps', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
create table t48.nt (id bigint primary key, t text not null);
insert into t48.nt select g, 't' || g from generate_series(1, 40) g;
call pgpm.transmute('t48.nt', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t48.nt values (450, 'frontier');
select archive.configure('t48.nt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t48.nt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
create temp table t48_alias_child as
  select parent_table::text as parent, child_name from pgpm.part
   where parent_table in ('t48.ps'::regclass, 't48.nt'::regclass) and lo = '0';
call pgpm.maintain('t48.ps');
call pgpm.maintain('t48.nt');
call pgpm.maintain('t48.ps');
call pgpm.maintain('t48.nt');

select is((select string_agg(c.relname || '.' || a.attname, ',' order by c.relname)
             from pg_attribute a join pg_class c on c.oid = a.attrelid
            where a.attrelid in ('t48.ps'::regclass, 't48.nt'::regclass) and a.attname in ('s', 't') and not a.attisdropped),
  'nt.t,ps.s', 'LIVENESS: t48.ps has a column named s and t48.nt one named t, the digests'' row aliases');
select is((select count(*)::int from t48_alias_child), 2,
  'LIVENESS: each table had a partition at [0, 100) for the tick to archive');
select is((select count(*)::int from pgpm.part where parent_table in ('t48.ps'::regclass, 't48.nt'::regclass)
             and child_name in (select child_name from t48_alias_child) and pgpm._is_write_blocked(parent_table, child_name))
          + (select count(*)::int from t48_alias_child c where to_regclass('t48.' || quote_ident(c.child_name)) is null), 2,
  'LIVENESS: the tick ran on both: each [0, 100) partition was write-blocked or is already gone');
select is((select array_agg(parent_table::text || ':' || coalesce(method, '') order by parent_table::text) from pgpm.log
            where parent_table in ('t48.ps'::regclass, 't48.nt'::regclass) and action = 'skip_archive'),
  null::text[], 'neither tick logged skip_archive');
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived, '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t48.ps'::regclass, 't48.nt'::regclass) and lo = '0'),
  't48.nt [0, 100) 40; t48.ps [0, 100) 60',
  'the tick archived [0, 100) of each: 60 rows as Parquet with a column s, 40 as NDJSON with a column t');
select is(
  (select string_agg(l.parent_table::text || ' ' || (k.rows_digest ~ '^[0-9a-f]{32}$')::text, '; ' order by l.parent_table::text)
     from pgpm.archive_ledger l join archive.object_key_claim k on k.object_key = l.s3_key
    where l.parent_table in ('t48.ps'::regclass, 't48.nt'::regclass) and l.lo = '0'),
  't48.nt true; t48.ps true',
  'and each chunk''s key records a digest of its rows');
select is((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 't'), ',' order by (l::jsonb ->> 'id')::bigint)
             from regexp_split_to_table((t48.req('GET', (select s3_key from pgpm.archive_ledger where parent_table = 't48.nt'::regclass and lo = '0'))).content, e'\n') l
            where l <> ''),
  (select string_agg(g || ':t' || g, ',' order by g) from generate_series(1, 40) g),
  'the NDJSON object holds exactly ids 1..40, each with its own t');
select is((select count(*)::int from t48_alias_child c where to_regclass('t48.' || quote_ident(c.child_name)) is null), 2,
  'and retire() dropped both archived partitions on that record');

-- ======================================================================================================
-- The record maintain() wrote is the record still there
-- ======================================================================================================
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived || ' ' || (s3_key = case parent_table when 't48.nd'::regclass then :'knd' else :'kpq' end)::text,
                     '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t48.nd'::regclass, 't48.pq'::regclass) and lo = '0'),
  't48.nd [0, 100) 90 true; t48.pq [0, 100) 70 true',
  'GUARD: the ledger''s record of each chunk is what maintain() wrote; no direct call changed it');

select * from finish();
