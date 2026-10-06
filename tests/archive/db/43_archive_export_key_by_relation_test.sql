-- An export's key is claimed by the relation it exports, not only by its parent (issue #976, reproduction
-- F5-05 of review pass 9).
--
-- archive.object_key_claim (#890) claimed a whole key by its parent and its kind, so the same parent's
-- export of ANOTHER relation at that key read as a re-run export. archive._resolve_child accepts any
-- relation in the parent's schema, so after archive.to_s3(parent, 'x'), DROP TABLE x (the documented
-- export-then-drop workflow, after which the object is the only copy of x's rows) and a new relation named
-- x, the same parent's archive.to_s3 of the new x PUT over the first export. The contract: the claim
-- records the exported relation's oid, a re-run by that relation finds the key its own, and another
-- relation spelling the key is refused, at the plain shape and at the oid shape alike, with the first
-- export left exactly as it was.
--
--   Part A  the issue's sequence at the plain key: export, re-run by the same relation (which rewrites
--           the object), drop, a namesake's export refused, the object unchanged
--   Part B  the same at the oid shape, which an export takes when its plain key is another writer's
--   Part C  the upgrade: install records a chunk claim's relation (the parent itself), and leaves an export
--           claim made before the column existed unrecorded, which no export may write over
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the first relation holds
-- 1:first, 2:first and 3:first (then 4:first, from the re-run), the namesake 10:second and 11:second. The
-- prefix carries current_database() because the bucket outlives a test database, and every key is cleared
-- and witnessed absent before the work that writes it.
set client_min_messages = warning;
select plan(24);

create schema t43;

create function t43.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t43.clear(p_key text) returns int language plpgsql as $$
begin
  perform t43.req('DELETE', p_key);
  return (t43.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t43.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t43.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- Which relation's export a whole key is claimed for, as its oid (null when unrecorded or unclaimed).
-- PL/pgSQL, so the file loads, and fails by assertion, against a module whose claims carry no relation.
create function t43.claimed_relation(p_key text) returns oid language plpgsql as $$
declare v oid;
begin
  execute 'select relation_oid from archive.object_key_claim where object_key = $1' into v using p_key;
  return v;
exception when undefined_column then return null;
end $$;

select current_database() || '/t43/' as p \gset

create table t43.evt (id bigint primary key, payload text not null);
insert into t43.evt values (45000, 'frontier');
call pgpm.transmute('t43.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t43.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't43.evt'::regclass::oid as evt_oid \gset

-- ======================= PART A: the plain key =======================
-- an untracked relation in the parent's schema, exported through the parent
create table t43.xtr (id bigint primary key, payload text not null);
insert into t43.xtr values (1, 'first'), (2, 'first'), (3, 'first');
select 't43.xtr'::regclass::oid as first_oid \gset

select is(t43.clear(:'p' || 't43.xtr.ndjson') || '/' || t43.clear(:'p' || 't43.xtr.' || :'evt_oid' || '.ndjson'), '404/404',
  'A fixture: nothing at the export''s key nor at its oid shape before the work');
select lives_ok($$ select archive.to_s3('t43.evt', 'xtr', null, null) $$,
  'A LIVENESS: archive.to_s3 of t43.xtr completed');
select is(t43.rows(:'p' || 't43.xtr.ndjson'), '1:first,2:first,3:first',
  'A LIVENESS: the export landed at <p>t43.xtr.ndjson holding rows 1, 2 and 3');
select is(t43.claimed_relation(:'p' || 't43.xtr.ndjson'), :'first_oid'::oid,
  'A: the claim on <p>t43.xtr.ndjson records the relation it exported, by oid');

-- a re-run by the same relation is the one writer that finds the key its own; row 4 shows it really wrote
insert into t43.xtr values (4, 'first');
select lives_ok($$ select archive.to_s3('t43.evt', 'xtr', null, null) $$,
  'A: a re-run export of the same relation completes');
select is(t43.rows(:'p' || 't43.xtr.ndjson'), '1:first,2:first,3:first,4:first',
  'A: and rewrote its own object, which now holds row 4 as well');

-- the documented export-then-drop: the object is now the only copy of rows 1 to 4
drop table t43.xtr;
create table t43.xtr (id bigint primary key, payload text not null);
insert into t43.xtr values (10, 'second'), (11, 'second');
select 't43.xtr'::regclass::oid as second_oid \gset
select isnt(:'second_oid'::oid, :'first_oid'::oid,
  'A LIVENESS: the new t43.xtr is another relation, with an oid of its own');

select throws_like($$ select archive.to_s3('t43.evt', 'xtr', null, null) $$,
  'pg_partition_magician: the object key %t43.xtr.ndjson is already claimed by the export of relation '
    || :'first_oid' || ' through t43.evt; refusing to write the export of t43.xtr (relation ' || :'second_oid' || ') over it%',
  'A: the same parent''s export of the namesake is refused, naming both relations');
select is(t43.rows(:'p' || 't43.xtr.ndjson'), '1:first,2:first,3:first,4:first',
  'A: the dropped relation''s export, the only copy of rows 1 to 4, is exactly as it was');
select is((t43.req('GET', :'p' || 't43.xtr.' || :'evt_oid' || '.ndjson')).status, 404,
  'A: and the refused export was not diverted to the oid shape either');
select is(t43.claimed_relation(:'p' || 't43.xtr.ndjson'), :'first_oid'::oid,
  'A: the claim still names the dropped relation');

-- ======================= PART B: the oid shape =======================
-- The plain key of t43.ext2 is claimed for another writer (oid 1, a chunk), so the export takes the oid
-- shape <p>t43.ext2.<evt oid>.ndjson; a namesake of the same parent spells that key too.
create table t43.ext2 (id bigint primary key, payload text not null);
insert into t43.ext2 values (5, 'first'), (6, 'first');
select 't43.ext2'::regclass::oid as b_first_oid \gset
insert into archive.object_key_claim (object_key, parent_oid, kind, relation_oid) values
  (:'p' || 't43.ext2.ndjson', 1, 'chunk', 1);
select is(t43.clear(:'p' || 't43.ext2.ndjson') || '/' || t43.clear(:'p' || 't43.ext2.' || :'evt_oid' || '.ndjson'), '404/404',
  'B fixture: nothing at the plain key nor at the oid shape before the work');
select lives_ok($$ select archive.to_s3('t43.evt', 'ext2', null, null) $$,
  'B LIVENESS: archive.to_s3 of t43.ext2 completed');
select is(t43.rows(:'p' || 't43.ext2.' || :'evt_oid' || '.ndjson') || '/' || (t43.req('GET', :'p' || 't43.ext2.ndjson')).status,
  '5:first,6:first/404',
  'B LIVENESS: the export took the oid shape <p>t43.ext2.<oid>.ndjson, the plain key being another writer''s');
select is(t43.claimed_relation(:'p' || 't43.ext2.' || :'evt_oid' || '.ndjson'), :'b_first_oid'::oid,
  'B: the claim on the oid shape records the relation it exported');

drop table t43.ext2;
create table t43.ext2 (id bigint primary key, payload text not null);
insert into t43.ext2 values (20, 'second');
select 't43.ext2'::regclass::oid as b_second_oid \gset
select throws_like($$ select archive.to_s3('t43.evt', 'ext2', null, null) $$,
  'pg_partition_magician: the object key %t43.ext2.' || :'evt_oid' || '.ndjson is already claimed by the export of relation '
    || :'b_first_oid' || ' through t43.evt; refusing to write the export of t43.ext2 (relation ' || :'b_second_oid' || ') over it%',
  'B: the namesake''s export at the oid shape is refused too');
select is(t43.rows(:'p' || 't43.ext2.' || :'evt_oid' || '.ndjson') || '/' || (t43.req('GET', :'p' || 't43.ext2.ndjson')).status,
  '5:first,6:first/404',
  'B: the first export at the oid shape is exactly as it was, and nothing was written at the plain key');

-- ======================= PART C: claims made before the column =======================
-- An installation upgraded from a main that claimed whole keys without their relation has rows whose
-- relation_oid is null. A chunk's relation is its parent, so install records it; an export's is not known,
-- so its claim stays unrecorded, and an export spelling its key is refused rather than adopted.
insert into archive.object_key_claim (object_key, parent_oid, kind) values
  (:'p' || 't43.evt_90000.ndjson', :'evt_oid'::oid, 'chunk'),
  (:'p' || 't43.ext3.ndjson', :'evt_oid'::oid, 'export');
select ok((select count(*) from archive.object_key_claim
             where object_key in (:'p' || 't43.evt_90000.ndjson', :'p' || 't43.ext3.ndjson')) = 2
          and t43.claimed_relation(:'p' || 't43.evt_90000.ndjson') is null
          and t43.claimed_relation(:'p' || 't43.ext3.ndjson') is null,
  'C fixture: a chunk claim and an export claim with no relation recorded, as before an upgrade');
select is(archive._record_claim_relations(), 1, 'C: install recorded the relation of exactly one claim');
select is(t43.claimed_relation(:'p' || 't43.evt_90000.ndjson'), :'evt_oid'::oid,
  'C: the chunk claim''s relation is its parent');
select is(t43.claimed_relation(:'p' || 't43.ext3.ndjson'), null,
  'C: and the export claim''s relation is left unrecorded, not guessed');

create table t43.ext3 (id bigint primary key, payload text not null);
insert into t43.ext3 values (30, 'third');
select is(t43.clear(:'p' || 't43.ext3.ndjson'), 404, 'C fixture: nothing at <p>t43.ext3.ndjson before the export');
select throws_like($$ select archive.to_s3('t43.evt', 'ext3', null, null) $$,
  'pg_partition_magician: the object key %t43.ext3.ndjson is already claimed by the export of relation (unrecorded) through t43.evt; refusing to write the export of t43.ext3 (relation '
    || ('t43.ext3'::regclass::oid)::text || ') over it%',
  'C: an export over an export claim whose relation is unrecorded is refused');
select is((t43.req('GET', :'p' || 't43.ext3.ndjson')).status, 404, 'C: and nothing was PUT');

select count(t43.clear(k)) from unnest(array[
  :'p' || 't43.xtr.ndjson', :'p' || 't43.xtr.' || :'evt_oid' || '.ndjson',
  :'p' || 't43.ext2.ndjson', :'p' || 't43.ext2.' || :'evt_oid' || '.ndjson', :'p' || 't43.ext3.ndjson']) k \gset discard_
select * from finish();
