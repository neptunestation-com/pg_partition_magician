-- An archive object key must never be reusable by a different relation (issue #822).
--
-- archive._object_key named a chunk <prefix><schema>.<table>_<stem><ext>: the parent's CURRENT name and the
-- chunk's lo, and both transports PUT it unconditionally. A name is not an identity. The runbook's path for
-- a table past untransmute is "drop the table and run pgpm.forget_missing()", which deletes the dropped
-- table's pgpm.archive_ledger rows, so the bucket object is then the ONLY copy of the rows retire() dropped.
-- A new managed table taking the same name and prefix archived its own [0, 10000) to the same key, and the
-- PUT replaced that copy with the new table's rows.
--
-- Now the database remembers which relation each key base (<prefix><schema>.<table>) belongs to, in
-- archive.object_key_owner, a table nothing deletes from: forget_missing() and a DROP leave it alone. The
-- relation that claimed a base keeps the shape it always had, so every key an existing table writes is
-- unchanged; any other relation that later computes the same base gets its oid in the key,
-- <prefix><schema>.<table>.<oid>_<stem><ext>, a shape no claimed key can take. Install seeds the claims from
-- the keys pgpm.archive_ledger already records, so a table archived before the registry existed is covered
-- too, and that seeding is asserted here (Part C) by re-running it the way a re-install does.
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the first table holds rows 1
-- and 2, the one that takes its name holds row 1 with a different payload. The prefix carries
-- current_database() because the bucket outlives a test database, and every candidate key is cleared and
-- witnessed absent before the work that would write it.
select plan(33);

create schema t34;

create function t34.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t34.clear(p_key text) returns int language plpgsql as $$
begin
  perform t34.req('DELETE', p_key);
  return (t34.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t34.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t34.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/16, so a Parquet object compares byte for byte.
create function t34.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t34.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

select current_database() || '/t34/' as p \gset

-- ======================= PART A: NDJSON, the documented drop + forget_missing path =======================

create table t34.evt (id bigint primary key, payload text not null);
insert into t34.evt values (1, 'old'), (2, 'old');
call pgpm.transmute('t34.evt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.evt values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('t34.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.evt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't34.evt'::regclass::oid as a_oid \gset
select is(t34.clear(:'p' || 't34.evt_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t34.evt_0.ndjson before the first table archives');
call pgpm.maintain('t34.evt');
select is((select array_agg(id order by id) from t34.evt where id < 10000), null::bigint[],
  'LIVENESS: retire() dropped the first table''s [0, 10000)');
select is((select s3_key from pgpm.archive_ledger where parent_table = :a_oid::oid::regclass and lo = '0'),
          :'p' || 't34.evt_0.ndjson',
  'the first relation to archive under a name keeps the shape it always had: <prefix><schema>.<table>_<stem>');
select is(t34.rows(:'p' || 't34.evt_0.ndjson'), '1:old,2:old',
  'LIVENESS: that object holds the first table''s rows 1:old and 2:old');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't34.evt'), :a_oid::oid,
  'the key base <prefix>t34.evt is recorded as the first table''s');

drop table t34.evt cascade;
select is((select partitions_forgotten from pgpm.forget_missing() where parent_oid = :a_oid::oid) > 0, true,
  'LIVENESS: forget_missing() cleared the dropped table, as the runbook directs');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = :a_oid::oid::regclass), 0,
  'LIVENESS: no ledger row is left for the dropped table; the bucket object is all that remains of rows 1 and 2');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't34.evt'), :a_oid::oid,
  'forget_missing() leaves the claim on <prefix>t34.evt with the dropped table');

create table t34.evt (id bigint primary key, payload text not null);
insert into t34.evt values (1, 'new');
call pgpm.transmute('t34.evt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.evt values (45000, 'frontier');
select archive.configure('t34.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.evt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't34.evt'::regclass::oid as b_oid \gset
select isnt(:b_oid::oid, :a_oid::oid, 'LIVENESS: the table that took the name is a different relation');
select is(t34.clear(:'p' || 't34.evt.' || :'b_oid' || '_0.ndjson'), 404,
  'LIVENESS: no object at <prefix>t34.evt.<oid>_0.ndjson before the second table archives');
call pgpm.maintain('t34.evt');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 't34.evt'::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the second table archived its own [0, 10000), one row');

select is((select s3_key from pgpm.archive_ledger where parent_table = 't34.evt'::regclass and lo = '0'),
          :'p' || 't34.evt.' || :'b_oid' || '_0.ndjson',
  'the second relation under the name is keyed with its oid: <prefix>t34.evt.<oid>_0.ndjson');
select is(t34.rows(:'p' || 't34.evt_0.ndjson'), '1:old,2:old',
  'the dropped table''s only copy of rows 1:old and 2:old is still at its key');
select is(t34.rows((select s3_key from pgpm.archive_ledger where parent_table = 't34.evt'::regclass and lo = '0')), '1:new',
  'the object the second table''s ledger row names holds exactly its row 1:new');

-- ======================= PART B: Parquet, the same path =======================

create table t34.pq (id bigint primary key, payload text not null);
insert into t34.pq values (1, 'old'), (2, 'old');
call pgpm.transmute('t34.pq', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.pq values (45000, 'frontier');
select archive.configure('t34.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't34.pq'::regclass::oid as pa_oid \gset
select is(t34.clear(:'p' || 't34.pq_0.parquet'), 404, 'LIVENESS: no object at <prefix>t34.pq_0.parquet before the first table archives');
call pgpm.maintain('t34.pq');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :pa_oid::oid::regclass and lo = '0'), 2::bigint,
  'LIVENESS: the first Parquet table archived its two rows in [0, 10000)');
select is((select s3_key from pgpm.archive_ledger where parent_table = :pa_oid::oid::regclass and lo = '0'),
          :'p' || 't34.pq_0.parquet',
  'the first Parquet table keeps the shape it always had');
select encode(t34.bytes(:'p' || 't34.pq_0.parquet'), 'hex') as pa_hex \gset
select is(:'pa_hex' <> '', true, 'LIVENESS: the first Parquet table''s file is in the bucket');

drop table t34.pq cascade;
select is((select partitions_forgotten from pgpm.forget_missing() where parent_oid = :pa_oid::oid) > 0, true,
  'LIVENESS: forget_missing() cleared the dropped Parquet table');

create table t34.pq (id bigint primary key, payload text not null);
insert into t34.pq values (1, 'new');
call pgpm.transmute('t34.pq', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.pq values (45000, 'frontier');
select archive.configure('t34.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't34.pq'::regclass::oid as pb_oid \gset
select is(t34.clear(:'p' || 't34.pq.' || :'pb_oid' || '_0.parquet'), 404,
  'LIVENESS: no object at <prefix>t34.pq.<oid>_0.parquet before the second Parquet table archives');
call pgpm.maintain('t34.pq');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 't34.pq'::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the second Parquet table archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't34.pq'::regclass and lo = '0'),
          :'p' || 't34.pq.' || :'pb_oid' || '_0.parquet',
  'the second Parquet table is keyed with its oid');
select is(encode(t34.bytes(:'p' || 't34.pq_0.parquet'), 'hex'), :'pa_hex',
  'the dropped Parquet table''s file is still at its key, byte for byte');
select isnt(encode(t34.bytes(:'p' || 't34.pq.' || :'pb_oid' || '_0.parquet'), 'hex'), :'pa_hex',
  'the second Parquet table''s file is its own, not a copy of the first');

-- ======================= PART C: a table archived before the registry existed =======================
-- An installation upgraded to this release has ledger rows and no claims. Install seeds a claim for every
-- key base the ledger records, owned by the relation that recorded it first; that is re-run here after
-- deleting the claim, which is exactly the state such an installation starts from.

create table t34.up (id bigint primary key, payload text not null);
insert into t34.up values (1, 'old'), (2, 'old');
call pgpm.transmute('t34.up', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.up values (45000, 'frontier');
select archive.configure('t34.up', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.up', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't34.up'::regclass::oid as ua_oid \gset
select is(t34.clear(:'p' || 't34.up_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t34.up_0.ndjson before the first table archives');
call pgpm.maintain('t34.up');
select is((select s3_key from pgpm.archive_ledger where parent_table = :ua_oid::oid::regclass and lo = '0'),
          :'p' || 't34.up_0.ndjson',
  'LIVENESS: the first table recorded <prefix>t34.up_0.ndjson in its ledger');
delete from archive.object_key_owner where key_base = :'p' || 't34.up';
select is((select count(*)::int from archive.object_key_owner where key_base = :'p' || 't34.up'), 0,
  'LIVENESS: no claim on <prefix>t34.up, the state of an installation that predates the registry');
select archive._claim_archived_key_bases();
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't34.up'), :ua_oid::oid,
  'install seeds the claim on <prefix>t34.up from the key the first table''s ledger row records');

drop table t34.up cascade;
select is((select partitions_forgotten from pgpm.forget_missing() where parent_oid = :ua_oid::oid) > 0, true,
  'LIVENESS: forget_missing() cleared the dropped table');
create table t34.up (id bigint primary key, payload text not null);
insert into t34.up values (1, 'new');
call pgpm.transmute('t34.up', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t34.up values (45000, 'frontier');
select archive.configure('t34.up', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t34.up', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't34.up'::regclass::oid as ub_oid \gset
select is(t34.clear(:'p' || 't34.up.' || :'ub_oid' || '_0.ndjson'), 404,
  'LIVENESS: no object at <prefix>t34.up.<oid>_0.ndjson before the second table archives');
call pgpm.maintain('t34.up');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 't34.up'::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the second table archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't34.up'::regclass and lo = '0'),
          :'p' || 't34.up.' || :'ub_oid' || '_0.ndjson',
  'a name whose claim was seeded from the ledger is keyed with the new table''s oid');
select is(t34.rows(:'p' || 't34.up_0.ndjson'), '1:old,2:old',
  'the table archived before the registry existed still has rows 1:old and 2:old at its key');

select * from finish();
