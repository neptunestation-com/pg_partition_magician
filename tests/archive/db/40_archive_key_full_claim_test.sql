-- An export's key and a chunk's key never name one object (issue #890, the "Archive object keys" bullet;
-- reproductions F5-02, F12-02 and F9r-01 of review pass 8).
--
-- archive.object_key_owner claims a key BASE (#822, #872). A chunk's key is <prefix><schema>.<table> with
-- tail _<stem><ext>; a synchronous export's is <prefix><schema>.<child> with tail <ext>. For a child named
-- <table>_<stem> the two bases differ, so both claims succeeded, and the two full keys are one string:
-- <prefix>t40.evt + _0.ndjson and <prefix>t40.evt_0 + .ndjson. archive._resolve_child accepts any relation
-- in the parent's schema, tracked or not, so archive.to_s3('t40.evt', 'evt_0', ...) of a relation pgpm
-- never made PUT over the chunk object retire() had left as the only copy of the rows it dropped, while
-- the ledger still pointed at it. The contract: a key is claimed WHOLE as well (archive.object_key_claim,
-- by parent and kind), and a writer that finds its key held by another takes the oid shape instead, or is
-- refused when even that is held. The other writer's object is left as it was.
--
--   Part A  chunk first, then an export of the same parent spelling its key (F12-02, F9r-01)
--   Part B  export first, then a chunk of another table spelling its key (the other way round, F5-02's
--           two parents): the chunk diverts and the export survives
--   Part C  the compressed shapes: a chunk at .ndjson.gz, then a compressed export spelling it, which only
--           a claim naming the whole key, `.gz` included, can see
--   Part D  both shapes held: the export is refused, nothing is PUT, and no claim survives the refusal
--   Part E  install claims every key pgpm.archive_ledger records, so a chunk archived before this release
--           is protected the same way
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: each chunk holds rows 1:old
-- and 2:old, each export rows 7:export and 8:export (or one row, where the shape says so). The prefix
-- carries current_database() because the bucket outlives a test database, and every key is cleared and
-- witnessed absent before the work that writes it.
set client_min_messages = warning;
select plan(32);

create schema t40;

create function t40.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t40.clear(p_key text) returns int language plpgsql as $$
begin
  perform t40.req('DELETE', p_key);
  return (t40.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t40.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t40.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- An object's bytes (null when there is none), as tests/archive/db/39 reads a gzip object.
create function t40.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t40.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

-- Who holds a whole key, as '<relation>/<kind>' (null when nobody does). PL/pgSQL, so the file loads, and
-- fails by assertion, against a module without the whole-key claims.
create function t40.holder(p_key text) returns text language plpgsql as $$
begin
  return (select parent_oid::regclass::text || '/' || kind from archive.object_key_claim where object_key = p_key);
end $$;

select current_database() || '/t40/' as p \gset

-- ======================= PART A: chunk first, then an export spelling its key =======================
create table t40.evt (id bigint primary key, payload text not null);
insert into t40.evt values (1, 'old'), (2, 'old');
call pgpm.transmute('t40.evt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t40.evt values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('t40.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t40.evt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't40.evt'::regclass::oid as evt_oid \gset

select is(t40.clear(:'p' || 't40.evt_0.ndjson') || '/' || t40.clear(:'p' || 't40.evt_0.' || :'evt_oid' || '.ndjson'), '404/404',
  'A fixture: nothing at the chunk key nor at the export''s oid-shaped key before the work');
call pgpm.maintain('t40.evt');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't40.evt'::regclass and lo = '0'),
          :'p' || 't40.evt_0.ndjson',
  'A LIVENESS: the chunk [0, 10000) of t40.evt is recorded at <p>t40.evt_0.ndjson');
select is(t40.rows(:'p' || 't40.evt_0.ndjson') || '/' || coalesce((select string_agg(id::text, ',') from t40.evt where id < 10000), 'none'),
  '1:old,2:old/none',
  'A LIVENESS: the object holds rows 1:old and 2:old, and retire() dropped them, so it is their only copy');
select is(t40.holder(:'p' || 't40.evt_0.ndjson'), 't40.evt/chunk', 'A: the chunk claimed its whole key, as t40.evt''s chunk');

-- a relation in the parent's schema, named like the chunk, that pgpm does not track
create table t40.evt_0 (id bigint primary key, payload text not null);
insert into t40.evt_0 values (7, 'export'), (8, 'export');
select lives_ok($$ select archive.to_s3('t40.evt', 'evt_0', null, null) $$,
  'A LIVENESS: archive.to_s3 of the untracked t40.evt_0 completed');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't40.evt_0'), :'evt_oid'::oid,
  'A LIVENESS: the export claimed the base <p>t40.evt_0, a base of its own, so a base claim alone saw no conflict');

select is(t40.rows(:'p' || 't40.evt_0.ndjson'), '1:old,2:old',
  'A: the chunk object still holds the retired rows 1:old and 2:old after the export whose key spelled it');
select is(t40.rows(:'p' || 't40.evt_0.' || :'evt_oid' || '.ndjson'), '7:export,8:export',
  'A: the export landed at its oid shape, <p>t40.evt_0.<oid>.ndjson, with its own rows');
select is(t40.holder(:'p' || 't40.evt_0.' || :'evt_oid' || '.ndjson'), 't40.evt/export',
  'A: and claimed that key as t40.evt''s export');
select lives_ok($$ select archive.to_s3('t40.evt', 'evt_0', null, null) $$,
  'A: a re-run of the same export finds its key its own and completes');
select is(t40.rows(:'p' || 't40.evt_0.ndjson') || '/' || t40.rows(:'p' || 't40.evt_0.' || :'evt_oid' || '.ndjson'),
  '1:old,2:old/7:export,8:export',
  'A: and still leaves the chunk object as it was, writing its own key again');

-- ======================= PART B: export first, then a chunk of another table spelling its key =======================
-- t40.log exports an untracked relation named ev2_0; t40.ev2 then archives its [0, 10000), whose plain key is
-- the export's.
create table t40.log (id bigint primary key, payload text not null);
insert into t40.log values (45000, 'frontier');
call pgpm.transmute('t40.log', 'id', 10000::bigint, p_paused => true);
select archive.configure('t40.log', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t40.ev2 (id bigint primary key, payload text not null);
insert into t40.ev2 values (1, 'old'), (2, 'old');
call pgpm.transmute('t40.ev2', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
select archive.configure('t40.ev2', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t40.ev2', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't40.ev2'::regclass::oid as ev2_oid \gset
create table t40.ev2_0 (id bigint primary key, payload text not null);
insert into t40.ev2_0 values (7, 'export');

select is(t40.clear(:'p' || 't40.ev2_0.ndjson') || '/' || t40.clear(:'p' || 't40.ev2.' || :'ev2_oid' || '_0.ndjson'), '404/404',
  'B fixture: nothing at the shared key nor at the chunk''s oid-shaped key before the work');
select lives_ok($$ select archive.to_s3('t40.log', 'ev2_0', null, null) $$, 'B LIVENESS: t40.log exported t40.ev2_0');
select is(t40.rows(:'p' || 't40.ev2_0.ndjson'), '7:export', 'B LIVENESS: the export is at <p>t40.ev2_0.ndjson');
select is(t40.holder(:'p' || 't40.ev2_0.ndjson'), 't40.log/export', 'B: and claimed that key as t40.log''s export');

insert into t40.ev2 values (45000, 'frontier');
call pgpm.maintain('t40.ev2');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't40.ev2'::regclass and lo = '0'),
          :'p' || 't40.ev2.' || :'ev2_oid' || '_0.ndjson',
  'B: t40.ev2''s chunk [0, 10000) took the oid shape, <p>t40.ev2.<oid>_0.ndjson, the plain key being the export''s');
select is(t40.rows(:'p' || 't40.ev2.' || :'ev2_oid' || '_0.ndjson') || '/' || coalesce((select string_agg(id::text, ',') from t40.ev2 where id < 10000), 'none'),
  '1:old,2:old/none',
  'B: the chunk object at the oid shape holds rows 1:old and 2:old, and retire() dropped them');
select is(t40.rows(:'p' || 't40.ev2_0.ndjson'), '7:export',
  'B: the export the chunk''s plain key spelled still holds its row 7:export');

-- ======================= PART C: the compressed shapes =======================
create table t40.gz (id bigint primary key, payload text not null);
insert into t40.gz values (1, 'old'), (2, 'old');
call pgpm.transmute('t40.gz', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t40.gz values (45000, 'frontier');
select archive.configure('t40.gz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p', p_compress => true);
select pgpm.set_archive_fn('t40.gz', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't40.gz'::regclass::oid as gz_oid \gset

select is(t40.clear(:'p' || 't40.gz_0.ndjson.gz') || '/' || t40.clear(:'p' || 't40.gz_0.' || :'gz_oid' || '.ndjson.gz'), '404/404',
  'C fixture: nothing at the compressed chunk key nor at the export''s oid-shaped key before the work');
call pgpm.maintain('t40.gz');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't40.gz'::regclass and lo = '0'),
          :'p' || 't40.gz_0.ndjson.gz',
  'C LIVENESS: the compressed chunk [0, 10000) of t40.gz is recorded at <p>t40.gz_0.ndjson.gz');
select t40.bytes(:'p' || 't40.gz_0.ndjson.gz') as gz_chunk \gset
select is(t40.holder(:'p' || 't40.gz_0.ndjson.gz'), 't40.gz/chunk',
  'C: the claim names the whole key the PUT wrote, .gz included');
create table t40.gz_0 (id bigint primary key, payload text not null);
insert into t40.gz_0 values (7, 'export');
select lives_ok($$ select archive.to_s3('t40.gz', 'gz_0', null, null) $$,
  'C LIVENESS: the compressed export of the untracked t40.gz_0 completed');
select ok(:'gz_chunk'::bytea is not null and t40.bytes(:'p' || 't40.gz_0.ndjson.gz') = :'gz_chunk'::bytea,
  'C: the compressed chunk object is byte for byte what it was before the compressed export');
select ok(t40.bytes(:'p' || 't40.gz_0.' || :'gz_oid' || '.ndjson.gz') is not null
          and t40.bytes(:'p' || 't40.gz_0.' || :'gz_oid' || '.ndjson.gz') <> :'gz_chunk'::bytea,
  'C: the compressed export landed at its oid shape, an object of its own');

-- ======================= PART D: both shapes held, refused =======================
-- A relation named evt_10000 exports to <p>t40.evt_10000.ndjson, or <p>t40.evt_10000.<oid>.ndjson; both are
-- claimed here for another writer (oid 1, a chunk), so the export has no key it may write.
create table t40.evt_10000 (id bigint primary key, payload text not null);
insert into t40.evt_10000 values (9, 'refused');
insert into archive.object_key_claim (object_key, parent_oid, kind) values
  (:'p' || 't40.evt_10000.ndjson', 1, 'chunk'), (:'p' || 't40.evt_10000.' || :'evt_oid' || '.ndjson', 1, 'chunk');
select is(t40.clear(:'p' || 't40.evt_10000.ndjson') || '/' || t40.clear(:'p' || 't40.evt_10000.' || :'evt_oid' || '.ndjson'), '404/404',
  'D fixture: nothing at either key before the export');
select throws_like($$ select archive.to_s3('t40.evt', 'evt_10000', null, null) $$,
  'pg_partition_magician: the object key %t40.evt_10000.' || :'evt_oid' || '.ndjson is already claimed by the chunk of relation 1; refusing to write the export of %',
  'D: the export whose plain and oid-shaped keys are both another writer''s is refused');
select is((t40.req('GET', :'p' || 't40.evt_10000.ndjson')).status || '/' || (t40.req('GET', :'p' || 't40.evt_10000.' || :'evt_oid' || '.ndjson')).status,
  '404/404', 'D: and nothing was PUT at either key');
select is((select count(*)::int from archive.object_key_owner where key_base = :'p' || 't40.evt_10000'), 0,
  'D: and the refusal rolled back its base claim with it');

-- ======================= PART E: install claims the keys the ledger records =======================
-- An installation upgraded to this release has ledger rows and no whole-key claims; the seed is what an
-- install runs. Taken out for Part A's chunk key and run again, it must claim that key for t40.evt.
delete from archive.object_key_claim where object_key = :'p' || 't40.evt_0.ndjson';
select is(t40.holder(:'p' || 't40.evt_0.ndjson'), null, 'E fixture: the chunk key has no whole-key claim, as before an upgrade');
select is(archive._claim_archived_keys(), 1, 'E: the seed claimed exactly one key, the only ledger key without a claim');
select is(t40.holder(:'p' || 't40.evt_0.ndjson'), 't40.evt/chunk',
  'E: the seed claimed the chunk key pgpm.archive_ledger records, for the table that archived it');
select is(t40.holder(:'p' || 't40.ev2_0.ndjson'), 't40.log/export',
  'E: and left a claim already made as it was');

select count(t40.clear(k)) from unnest(array[
  :'p' || 't40.evt_0.ndjson', :'p' || 't40.evt_0.' || :'evt_oid' || '.ndjson',
  :'p' || 't40.ev2_0.ndjson', :'p' || 't40.ev2.' || :'ev2_oid' || '_0.ndjson',
  :'p' || 't40.gz_0.ndjson.gz', :'p' || 't40.gz_0.' || :'gz_oid' || '.ndjson.gz']) k \gset discard_
select * from finish();
