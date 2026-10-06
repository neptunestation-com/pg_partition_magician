-- An archive_fn strategy never writes over the object pgpm.archive_ledger records a chunk at unless the call
-- reproduces that chunk (#975, pass 9 F5-03 and F5-04).
--
-- THE DEFECT. A chunk's object key is derived from its lo alone, and #969's direct-call guard
-- (archive._refuse_empty_range) refused only an empty or inverted range SHAPE, while archive._owned_key's
-- whole-key claim admits the same parent and kind. Nothing asked what the ledger already recorded at the key
-- the call would write. So a direct pgpm.archive_to_s3_ndjson / _parquet call:
--   F5-04  on a live, already-archived partition, with the chunk's lo and a hi below the recorded one, PUT a
--          subset over the chunk's object while the ledger still recorded [lo, hi) there; retire() then dropped
--          the partition and the rest of the rows had no copy anywhere;
--   F5-03  after retire() had dropped the partition, with the chunk's own [lo, hi) (what #969's refusal tells
--          the caller to pass), read no row and PUT an EMPTY object over the only copy of the retired rows.
--
-- THE CONTRACT. Before either strategy PUTs, the ledger is consulted for the key the PUT will write. Where it
-- records a chunk there, the call proceeds only when it reproduces that chunk: the same [lo, hi), compared as
-- the grid's native type, and the read finding the rows the chunk recorded. Anything else is refused, naming
-- the recorded chunk and the key. A key the ledger records nothing at is written as before.
--
-- IDENTITY. Every refusal is followed by reading the objects back: the NDJSON one by its rows' ids and payloads,
-- the Parquet one by its bytes. Fixtures are asymmetric (90 rows in the NDJSON chunk, 70 in the Parquet one),
-- and each object is first proven to hold what its chunk recorded (the LIVENESS lines), so "the object still
-- holds it" is a statement about a write that was refused, not about one that never had anything to replace.
-- CONTROLS: a re-run that reproduces a live chunk is admitted, and a key the ledger records nothing at is
-- written, so the refusal is about the recorded chunk and not a blanket one.
-- bench/archive_recorded_chunk.sh runs this file against the module's mutants.
set client_min_messages = warning;
select plan(26);

create schema t42;

create function t42.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- what an NDJSON object holds, as 'id:payload' items sorted by id (null when there is no object)
create function t42.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t42.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
-- an object's bytes (null when there is none), as tests/archive/db/40 reads a binary object
create function t42.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t42.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;
-- a strategy's answer for [lo, hi) of a table as '<rows> <key>', or the error it raised
create function t42.try(p_fmt text, p_parent text, p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  execute format('select * from pgpm.archive_to_s3_%s(%L, %L, %L, %L)', p_fmt, p_parent, 'unused', p_lo, p_hi) into r;
  return r.rows_archived || ' ' || r.s3_key;
exception when others then
  return sqlerrm;
end $$;
-- the 'id:payload' items a table's ids p_from..p_to were seeded with
create function t42.expect(p_tag text, p_from int, p_to int) returns text language sql immutable as $$
  select string_agg(g || ':' || p_tag || g, ',' order by g) from generate_series(p_from, p_to) g $$;

select current_database() || '/t42/' || txid_current() || '/' as p \gset

-- Two id grids of step 100, retention 100, each with one chunk below the horizon: [0, 100) holds ids 1..90 of
-- t42.nd (archived as NDJSON) and ids 1..70 of t42.pq (as Parquet). A frontier at 450 puts the horizon at 300.
-- retain_batch = 0 holds retire() off until the live half of the test is done; archive_batch keeps its default
-- of 1, so the first tick archives the oldest partition, [0, 100), alone.
create table t42.nd (id bigint primary key, payload text not null);
insert into t42.nd select g, 'n' || g from generate_series(1, 90) g;
call pgpm.transmute('t42.nd', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t42.nd values (450, 'frontier');
select archive.configure('t42.nd', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 't42.nd'::regclass;
select pgpm.set_archive_fn('t42.nd', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

create table t42.pq (id bigint primary key, payload text not null);
insert into t42.pq select g, 'q' || g from generate_series(1, 70) g;
call pgpm.transmute('t42.pq', 'id', 100::bigint, p_retain => 100::bigint, p_paused => false);
insert into t42.pq values (450, 'frontier');
select archive.configure('t42.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
update pgpm.config set retain_batch = 0 where parent_table = 't42.pq'::regclass;
select pgpm.set_archive_fn('t42.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

create temp table t42_child as
  select parent_table::text as parent, child_name from pgpm.part
   where parent_table in ('t42.nd'::regclass, 't42.pq'::regclass) and lo = '0';

call pgpm.maintain('t42.nd');
call pgpm.maintain('t42.pq');

select (select s3_key from pgpm.archive_ledger where parent_table = 't42.nd'::regclass and lo = '0') as knd,
       (select s3_key from pgpm.archive_ledger where parent_table = 't42.pq'::regclass and lo = '0') as kpq \gset
create temp table t42_pq_before as
  select t42.bytes(:'kpq') as b, (select etag from pgpm.archive_ledger where parent_table = 't42.pq'::regclass and lo = '0') as etag;

-- ======================================================================================================
-- Setup witnesses
-- ======================================================================================================
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived, '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t42.nd'::regclass, 't42.pq'::regclass)),
  't42.nd [0, 100) 90; t42.pq [0, 100) 70',
  'LIVENESS: maintain() archived [0, 100) of each table as one chunk, ledgered with its row count');
select is(t42.rows(:'knd'), t42.expect('n', 1, 90),
  'LIVENESS: the NDJSON chunk''s object holds exactly ids 1..90 of t42.nd');
select ok((select octet_length(b) > 0 and md5(b) = btrim(etag, '"') from t42_pq_before),
  'LIVENESS: the Parquet chunk''s object holds the bytes its PUT wrote (their md5 is the ledgered ETag)');
select is(archive._object_key('t42.nd'::regclass, :'p', 'id', '0', '.ndjson') || ' ' || archive._object_key('t42.pq'::regclass, :'p', 'id', '0', '.parquet'),
  :'knd' || ' ' || :'kpq',
  'LIVENESS: a call with lo 0 addresses those very objects, whatever its hi (the key is derived from lo alone)');
select is((select count(*)::int from t42_child c where to_regclass('t42.' || quote_ident(c.child_name)) is not null), 2,
  'LIVENESS: both archived partitions are still there (retire() is held off)');

-- ======================================================================================================
-- F5-04: a live, archived chunk; a range that is not the chunk's
-- ======================================================================================================
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t42.pq', 'unused', '0', '50') $$,
  'pg_partition_magician: archive_to_s3_parquet refuses to write [0, 50) of t42.pq to the object key ' || :'kpq'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 70 row(s) there%',
  'F5-04: archive_to_s3_parquet refuses [0, 50) over the chunk [0, 100), naming the recorded chunk and the key');
-- [0, 95) of t42.nd holds every row the chunk recorded, so only the range tells it from the chunk
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t42.nd', 'unused', '0', '95') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 95) of t42.nd to the object key %: %this call''s range is not that chunk''s%',
  'F5-04: a range that reads the same rows but is not the chunk''s is refused too (the ledger would describe another write)');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t42.nd', 'unused', '0', '200') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 200) of t42.nd to the object key %',
  'F5-04: so is a range past the chunk''s hi');

-- last, so the identity check below reads what this one call would have left
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t42.nd', 'unused', '0', '50') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 50) of t42.nd to the object key ' || :'knd'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 90 row(s) there%',
  'F5-04: archive_to_s3_ndjson refuses [0, 50) over the chunk [0, 100), naming the recorded chunk and the key');
select is(t42.rows(:'knd'), t42.expect('n', 1, 90),
  'F5-04: the NDJSON object still holds exactly ids 1..90 after the refused calls');
select ok(t42.bytes(:'kpq') = (select b from t42_pq_before),
  'F5-04: the Parquet object still holds the bytes its PUT wrote after the refused call');

-- CONTROL: a re-run that reproduces the live chunk is the documented re-run, and is admitted
select is(t42.try('ndjson', 't42.nd', '0', '100'), '90 ' || :'knd',
  'CONTROL: a re-run of the chunk''s own [0, 100) while its rows are in the table is written (90 rows, the same key)');
select is(t42.try('parquet', 't42.pq', '0', '100'), '70 ' || :'kpq',
  'CONTROL: the same for the Parquet strategy (70 rows, the same key)');
select is(t42.rows(:'knd'), t42.expect('n', 1, 90),
  'CONTROL: the re-run left the NDJSON object holding exactly ids 1..90');
-- the Parquet object as the re-run left it, which is what retire() leaves as the only copy
create temp table t42_pq_rerun as select t42.bytes(:'kpq') as b;
select ok((select octet_length(b) > 0 from t42_pq_rerun),
  'CONTROL: the re-run left a Parquet object at the key');

-- ======================================================================================================
-- F5-03: retire() drops the partitions; the objects are the only copies
-- ======================================================================================================
update pgpm.config set retain_batch = null where parent_table in ('t42.nd'::regclass, 't42.pq'::regclass);
call pgpm.maintain('t42.nd');
call pgpm.maintain('t42.pq');

select is((select count(*)::int from t42_child c where to_regclass('t42.' || quote_ident(c.child_name)) is null), 2,
  'LIVENESS: retire() dropped both archived partitions, so each object is the only copy of its chunk''s rows');
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived || ' ' || (s3_key = case parent_table when 't42.nd'::regclass then :'knd' else :'kpq' end)::text,
                     '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t42.nd'::regclass, 't42.pq'::regclass) and lo = '0'),
  't42.nd [0, 100) 90 true; t42.pq [0, 100) 70 true',
  'LIVENESS: the ledger still records each chunk at its key after the drop');
select is((select count(*)::int from t42.nd where id < 100) + (select count(*)::int from t42.pq where id < 100), 0,
  'LIVENESS: no row of either chunk is left in its table to be re-read');

select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t42.nd', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 100) of t42.nd to the object key ' || :'knd'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 90 row(s) there, and the read found 0 row(s) in it now%',
  'F5-03: archive_to_s3_ndjson refuses the retired chunk''s own [0, 100), whose rows are gone');
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t42.pq', 'unused', '0', '100') $$,
  'pg_partition_magician: archive_to_s3_parquet refuses to write [0, 100) of t42.pq to the object key ' || :'kpq'
  || ': pgpm.archive_ledger records the chunk [0, 100) of 70 row(s) there, and the read found 0 row(s) in it now%',
  'F5-03: archive_to_s3_parquet refuses the retired chunk''s own [0, 100), whose rows are gone');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t42.nd', 'unused', '0', '50') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses to write [0, 50) of t42.nd to the object key %',
  'F5-03: and any other range at that key');

select is(t42.rows(:'knd'), t42.expect('n', 1, 90),
  'F5-03: the NDJSON object the retired chunk was archived to still holds exactly ids 1..90');
select ok(t42.bytes(:'kpq') = (select b from t42_pq_rerun),
  'F5-03: the Parquet object the retired chunk was archived to still holds its bytes');

-- CONTROL: a key the ledger records nothing at is written as before
select is(t42.try('ndjson', 't42.nd', '400', '500'), '1 ' || archive._object_key('t42.nd'::regclass, :'p', 'id', '400', '.ndjson'),
  'CONTROL: a direct call for [400, 500), whose key the ledger records nothing at, is written');
select is(t42.rows(archive._object_key('t42.nd'::regclass, :'p', 'id', '400', '.ndjson')), '450:frontier',
  'CONTROL: and its object holds the frontier row');
select is(
  (select string_agg(parent_table::text || ' [' || lo || ', ' || hi || ') ' || rows_archived, '; ' order by parent_table::text)
     from pgpm.archive_ledger where parent_table in ('t42.nd'::regclass, 't42.pq'::regclass) and lo = '0'),
  't42.nd [0, 100) 90; t42.pq [0, 100) 70',
  'GUARD: the ledger''s record of each chunk is what maintain() wrote; no direct call changed it');

select * from finish();
