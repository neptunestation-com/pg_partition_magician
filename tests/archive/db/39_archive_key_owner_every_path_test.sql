-- Every object key the archive module writes names ONE relation, on every path that writes one (issue
-- #872, bullet 5; the class of #822 and #711).
--
-- #822 gave the automatic path's chunk keys an owner: archive.object_key_owner records which relation a key
-- base belongs to, and any other relation that computes the same base gets its oid in the key, so it can
-- never PUT over an object an earlier relation wrote. The synchronous exports did not get it.
-- archive._child_object_key keyed archive.to_s3 and archive.to_s3_parquet by <prefix><schema>.<child><ext>
-- and both PUT unconditionally, so after the documented to_s3-then-drop workflow (and
-- pgpm.forget_missing()), a new table that took the dropped table's name exported its same-named
-- partition OVER the dropped table's export, the only copy of those rows.
--
-- Now one function assembles every key and takes the claim, and every path asks it. This file is the
-- behavioural half of that lever: each path that writes an object (the two synchronous exports, the
-- NDJSON one plain and compressed, and the two archive_fn transports) exports a relation, the relation
-- is dropped and forgotten, a namesake exports the same partition, and the first relation's object is
-- asserted still there by identity: its exact key, and its rows or its bytes. The namesake's object is
-- asserted at its own exact key, the oid shape. Part 0 is the catalog half: every archive function that
-- PUTs an object takes its key from the key helpers, so a new PUT site that builds its own key fails
-- here even before anyone writes a namesake case for it. (scripts/check_archive_object_keys.py is the
-- source-level half: the key is assembled in exactly one function.)
--
-- Fixtures are asymmetric, so a replaced object cannot pass an identity check: each first relation holds
-- rows 1:old and 2:old, each namesake row 1:new. The prefix carries current_database() because the bucket
-- outlives a test database, and every key is cleared and witnessed absent before the work that writes it.
set client_min_messages = warning;
select plan(45);

create schema t39;

create function t39.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t39.clear(p_key text) returns int language plpgsql as $$
begin
  perform t39.req('DELETE', p_key);
  return (t39.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t39.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t39.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/16, so a gzip or Parquet object compares byte for byte.
create function t39.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t39.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

-- A managed table named t39.<p_name>, one [0, 10000) partition holding p_rows; returns nothing. The two
-- generations of each name are built by this one function, so they differ only in their rows.
create function t39.mk(p_name name, p_rows text[]) returns void language plpgsql as $$
begin
  execute format('create table t39.%I (id bigint primary key, payload text not null)', p_name);
  execute format('insert into t39.%I select i, ($1)[i] from generate_subscripts($1, 1) i', p_name) using p_rows;
end $$;

-- The documented retirement of a table: drop it, let pgpm.forget_missing() clear it, drop its connection
-- settings. Returns the partitions forget_missing() reported forgotten for it.
create function t39.retire_table(p_name name) returns int language plpgsql as $$
declare v_oid oid := format('t39.%I', p_name)::regclass::oid; v_n int;
begin
  execute format('drop table t39.%I cascade', p_name);
  select f.partitions_forgotten into v_n from pgpm.forget_missing() f where f.parent_oid = v_oid;
  delete from archive.config c where c.parent_table::oid = v_oid;
  return v_n;
end $$;

select current_database() || '/t39/' as p \gset

-- ======================= PART 0: every PUT site takes its key from the key helpers =======================

select ok(array['_encode_upload_ndjson_single', '_encode_upload_parquet', 'to_s3', 'to_s3_parquet']::name[]
            <@ (select array_agg(p.proname) from pg_proc p
                 where p.pronamespace in ('archive'::regnamespace, 'pgpm'::regnamespace) and p.prosrc like '%''PUT''%'),
  'LIVENESS: the catalog scan finds the four functions known to PUT an object');
select is((select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
            where p.pronamespace in ('archive'::regnamespace, 'pgpm'::regnamespace) and p.prosrc like '%''PUT''%'
              and p.prosrc not like '%archive.\_object\_key(%' and p.prosrc not like '%archive.\_child\_object\_key(%'),
          null::text[],
  'every function that PUTs an object takes its key from archive._object_key or archive._child_object_key');

-- ======================= PART A: archive.to_s3, plain NDJSON =======================

select t39.mk('ev', array['old', 'old']);
call pgpm.transmute('t39.ev', 'id', 10000::bigint);
select archive.configure('t39.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.ev'::regclass::oid as a1_oid \gset
select child_name as a_child from pgpm.part where parent_table = 't39.ev'::regclass and lo = '0' \gset
select is(t39.clear(:'p' || 't39.' || :'a_child' || '.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.ndjson before the first table exports');
select archive.to_s3('t39.ev', :'a_child', '0', '10000');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.ndjson'), '1:old,2:old',
  'archive.to_s3: the first relation to export a child keeps the shape it always had, <prefix><schema>.<child>.ndjson');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't39.' || :'a_child'), :a1_oid::oid,
  'archive.to_s3: the export claimed <prefix>t39.<child> for the first table');

select ok(t39.retire_table('ev') > 0, 'LIVENESS: forget_missing() cleared the dropped first table');
select t39.mk('ev', array['new']);
call pgpm.transmute('t39.ev', 'id', 10000::bigint);
select archive.configure('t39.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.ev'::regclass::oid as a2_oid \gset
select isnt(:a2_oid::oid, :a1_oid::oid, 'LIVENESS: the table that took the name is a different relation');
select is((select child_name from pgpm.part where parent_table = 't39.ev'::regclass and lo = '0'), :'a_child'::name,
  'LIVENESS: its [0, 10000) partition has the first table''s child name');
select is(t39.clear(:'p' || 't39.' || :'a_child' || '.' || :'a2_oid' || '.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.ndjson before the namesake exports');
select archive.to_s3('t39.ev', :'a_child', '0', '10000');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.' || :'a2_oid' || '.ndjson'), '1:new',
  'archive.to_s3: the namesake''s export is at its own key, <prefix>t39.<child>.<oid>.ndjson, holding its row 1:new');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.ndjson'), '1:old,2:old',
  'archive.to_s3: the dropped table''s export, the only copy of rows 1:old and 2:old, is still at its key');

-- ======================= PART B: archive.to_s3, compressed =======================

select t39.mk('gz', array['old', 'old']);
call pgpm.transmute('t39.gz', 'id', 10000::bigint);
select archive.configure('t39.gz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p', p_compress => true);
select 't39.gz'::regclass::oid as b1_oid \gset
select child_name as b_child from pgpm.part where parent_table = 't39.gz'::regclass and lo = '0' \gset
-- what each generation's object must be, byte for byte: one gzip member over its NDJSON lines
select encode(archive._pq_gzip_compress_dynamic(convert_to(
         '{"id":1,"payload":"old"}' || e'\n' || '{"id":2,"payload":"old"}' || e'\n', 'UTF8')), 'hex') as b_old_hex \gset
select encode(archive._pq_gzip_compress_dynamic(convert_to('{"id":1,"payload":"new"}' || e'\n', 'UTF8')), 'hex') as b_new_hex \gset
select is(t39.clear(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.ndjson.gz before the first table exports');
select archive.to_s3('t39.gz', :'b_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 'hex'), :'b_old_hex',
  'archive.to_s3 compressed: the first relation''s object is the gzip of rows 1:old and 2:old at <prefix>t39.<child>.ndjson.gz');

select ok(t39.retire_table('gz') > 0, 'LIVENESS: forget_missing() cleared the dropped first compressed table');
select t39.mk('gz', array['new']);
call pgpm.transmute('t39.gz', 'id', 10000::bigint);
select archive.configure('t39.gz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p', p_compress => true);
select 't39.gz'::regclass::oid as b2_oid \gset
select is((select child_name from pgpm.part where parent_table = 't39.gz'::regclass and lo = '0'), :'b_child'::name,
  'LIVENESS: the compressed namesake''s partition has the first table''s child name');
select is(t39.clear(:'p' || 't39.' || :'b_child' || '.' || :'b2_oid' || '.ndjson.gz'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.ndjson.gz before the namesake exports');
select archive.to_s3('t39.gz', :'b_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.' || :'b2_oid' || '.ndjson.gz'), 'hex'), :'b_new_hex',
  'archive.to_s3 compressed: the namesake''s object is the gzip of its row 1:new, at <prefix>t39.<child>.<oid>.ndjson.gz');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 'hex'), :'b_old_hex',
  'archive.to_s3 compressed: the dropped table''s object is still at its key, byte for byte');

-- ======================= PART C: archive.to_s3_parquet =======================

select t39.mk('pq', array['old', 'old']);
call pgpm.transmute('t39.pq', 'id', 10000::bigint);
select archive.configure('t39.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.pq'::regclass::oid as c1_oid \gset
select child_name as c_child from pgpm.part where parent_table = 't39.pq'::regclass and lo = '0' \gset
select encode(archive._pq_to_parquet(format('t39.%I', :'c_child')::regclass, false), 'hex') as c_old_hex \gset
select is(t39.clear(:'p' || 't39.' || :'c_child' || '.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.parquet before the first table exports');
select archive.to_s3_parquet('t39.pq', :'c_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.parquet'), 'hex'), :'c_old_hex',
  'archive.to_s3_parquet: the first relation''s file is at <prefix>t39.<child>.parquet, byte for byte');

select ok(t39.retire_table('pq') > 0, 'LIVENESS: forget_missing() cleared the dropped first Parquet table');
select t39.mk('pq', array['new']);
call pgpm.transmute('t39.pq', 'id', 10000::bigint);
select archive.configure('t39.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.pq'::regclass::oid as c2_oid \gset
select is((select child_name from pgpm.part where parent_table = 't39.pq'::regclass and lo = '0'), :'c_child'::name,
  'LIVENESS: the Parquet namesake''s partition has the first table''s child name');
select encode(archive._pq_to_parquet(format('t39.%I', :'c_child')::regclass, false), 'hex') as c_new_hex \gset
select isnt(:'c_new_hex'::text, :'c_old_hex'::text, 'LIVENESS: the two generations encode to different Parquet files');
select is(t39.clear(:'p' || 't39.' || :'c_child' || '.' || :'c2_oid' || '.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.parquet before the namesake exports');
select archive.to_s3_parquet('t39.pq', :'c_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.' || :'c2_oid' || '.parquet'), 'hex'), :'c_new_hex',
  'archive.to_s3_parquet: the namesake''s file is at its own key, <prefix>t39.<child>.<oid>.parquet');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.parquet'), 'hex'), :'c_old_hex',
  'archive.to_s3_parquet: the dropped table''s file is still at its key, byte for byte');

-- ======================= PART D: the archive_fn NDJSON transport =======================

select t39.mk('an', array['old', 'old']);
call pgpm.transmute('t39.an', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.an values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('t39.an', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.an', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't39.an'::regclass::oid as d1_oid \gset
select is(t39.clear(:'p' || 't39.an_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t39.an_0.ndjson before the first table archives');
call pgpm.maintain('t39.an');
select is((select s3_key from pgpm.archive_ledger where parent_table = :d1_oid::oid::regclass and lo = '0'), :'p' || 't39.an_0.ndjson',
  'archive_to_s3_ndjson: the first relation keeps the shape it always had, <prefix><schema>.<table>_<stem>.ndjson');
select is(t39.rows(:'p' || 't39.an_0.ndjson'), '1:old,2:old',
  'archive_to_s3_ndjson: that object holds the first table''s rows 1:old and 2:old');

select ok(t39.retire_table('an') > 0, 'LIVENESS: forget_missing() cleared the dropped first NDJSON-archived table');
select t39.mk('an', array['new']);
call pgpm.transmute('t39.an', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.an values (45000, 'frontier');
select archive.configure('t39.an', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.an', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't39.an'::regclass::oid as d2_oid \gset
select is(t39.clear(:'p' || 't39.an.' || :'d2_oid' || '_0.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.an.<oid>_0.ndjson before the namesake archives');
call pgpm.maintain('t39.an');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :d2_oid::oid::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the namesake archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = :d2_oid::oid::regclass and lo = '0'),
          :'p' || 't39.an.' || :'d2_oid' || '_0.ndjson',
  'archive_to_s3_ndjson: the namesake is keyed with its oid, <prefix>t39.an.<oid>_0.ndjson');
select is(t39.rows(:'p' || 't39.an.' || :'d2_oid' || '_0.ndjson'), '1:new',
  'archive_to_s3_ndjson: the namesake''s object holds exactly its row 1:new');
select is(t39.rows(:'p' || 't39.an_0.ndjson'), '1:old,2:old',
  'archive_to_s3_ndjson: the dropped table''s only copy of rows 1:old and 2:old is still at its key');

-- ======================= PART E: the archive_fn Parquet transport =======================

select t39.mk('ap', array['old', 'old']);
call pgpm.transmute('t39.ap', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.ap values (45000, 'frontier');
select archive.configure('t39.ap', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.ap', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't39.ap'::regclass::oid as e1_oid \gset
select is(t39.clear(:'p' || 't39.ap_0.parquet'), 404, 'LIVENESS: no object at <prefix>t39.ap_0.parquet before the first table archives');
call pgpm.maintain('t39.ap');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :e1_oid::oid::regclass and lo = '0'), 2::bigint,
  'LIVENESS: the first Parquet-archived table archived its two rows');
select is((select s3_key from pgpm.archive_ledger where parent_table = :e1_oid::oid::regclass and lo = '0'), :'p' || 't39.ap_0.parquet',
  'archive_to_s3_parquet: the first relation keeps the shape it always had, <prefix><schema>.<table>_<stem>.parquet');
select encode(t39.bytes(:'p' || 't39.ap_0.parquet'), 'hex') as e_old_hex \gset
select ok(:'e_old_hex' like '50415231%', 'LIVENESS: the first table''s Parquet file (PAR1) is in the bucket');

select ok(t39.retire_table('ap') > 0, 'LIVENESS: forget_missing() cleared the dropped first Parquet-archived table');
select t39.mk('ap', array['new']);
call pgpm.transmute('t39.ap', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.ap values (45000, 'frontier');
select archive.configure('t39.ap', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.ap', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't39.ap'::regclass::oid as e2_oid \gset
select is(t39.clear(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.ap.<oid>_0.parquet before the namesake archives');
call pgpm.maintain('t39.ap');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :e2_oid::oid::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the Parquet namesake archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = :e2_oid::oid::regclass and lo = '0'),
          :'p' || 't39.ap.' || :'e2_oid' || '_0.parquet',
  'archive_to_s3_parquet: the namesake is keyed with its oid, <prefix>t39.ap.<oid>_0.parquet');
select ok(encode(t39.bytes(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 'hex') like '50415231%'
          and encode(t39.bytes(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 'hex') <> :'e_old_hex',
  'archive_to_s3_parquet: the namesake''s key holds a Parquet file of its own, not a copy of the first');
select is(encode(t39.bytes(:'p' || 't39.ap_0.parquet'), 'hex'), :'e_old_hex',
  'archive_to_s3_parquet: the dropped table''s file is still at its key, byte for byte');

select * from finish();
