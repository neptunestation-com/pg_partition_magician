-- A synchronous export keys and claims the relation archive._resolve_child resolved, BY OID, never by its
-- name looked up again (issue #1064, Tier 1, verified as V-01 of #1063's verification).
--
-- archive._resolve_child resolves the export's child in one snapshot, holds it under ACCESS SHARE and returns
-- its regclass. archive.to_s3 and archive.to_s3_parquet then handed the NAME back to archive._child_object_key,
-- and archive._owned_key looked the relation up again by (the parent's CURRENT schema, the name): once to build
-- the key base <prefix><schema>.<child> and once to find the relation its claim records. The hold is on the
-- child only, so ALTER TABLE <parent> SET SCHEMA between the two lookups was not blocked: the object holding the
-- resolved relation's rows was keyed and claimed as the destination schema's namesake, and the namesake's own
-- later export passed that claim and PUT over the only copy (after the documented export-then-drop workflow).
-- The contract:
--
--   Part A  archive.to_s3 with the parent moved to a schema holding a namesake inside the export: the object
--           is keyed by the resolved relation's own schema and name, holds its rows, and its claim names it;
--           nothing is written or claimed at the namesake's key, and the namesake's later export through the
--           same parent leaves the first object as it was
--   Part B  the same for archive.to_s3_parquet
--   Part C  the boundary the hold does not cover: ALTER SCHEMA ... RENAME takes no lock that conflicts with it,
--           so the schema NAME can change between the hold and the key. The key then spells the name the
--           relation's schema has when the key is rendered, the claim still names the held relation, and an
--           object another relation's claim holds at that spelling is not written over: here another parent's
--           export already stands at <prefix><new name>.loose.ndjson, so this one takes the oid shape beside it
--
-- THE INSTRUMENT (the one tests/archive/db/47's sibling reproduction uses). pgpm._refuse_filtered_reads calls
-- row_security_active unqualified, both exports call it on the resolved child right after
-- archive._resolve_child returns, and neither pins a search_path, so a row_security_active(regclass) in a
-- schema the caller puts ahead of pg_catalog runs in its place. Armed for one call by t49.armed (the oid it
-- fires on), t49.part and t49.sql, it runs t49.sql in a second session (dblink, connection `h`) and records what
-- happened there in t49.seen from that session, so the record survives an export that fails; then it takes a
-- lock on a relation this transaction has not locked yet (t49.kick), which makes this backend read the second
-- session's committed catalog changes at once, and returns what pg_catalog.row_security_active returns. If
-- either export stops calling it there, the shim never fires and the LIVENESS lines below fail: loudly, never
-- a silent pass.
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the exported relations hold
-- 1:mine, 2:mine (A), 3:mine_b, 4:mine_b (B) and 5:mine, 6:mine (C), the namesakes 10:namesake (A),
-- 20:namesake_b (B) and 30:other (C). The prefix carries current_database() because the bucket outlives a test database, and
-- every key is cleared and witnessed absent before the work that writes it.
set client_min_messages = warning;
create extension if not exists dblink;
select plan(28);

create schema t49;
create schema t49hook;

create function t49.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t49.clear(p_key text) returns int language plpgsql as $$
begin
  perform t49.req('DELETE', p_key);
  return (t49.req('GET', p_key)).status;
end $$;
-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t49.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t49.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;
-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/39 and 46, so a Parquet object compares byte for byte.
create function t49.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t49.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;
-- Whether a file carries a payload string (uncompressed, so a value's bytes appear as they are).
create function t49.has(p_file bytea, p_payload text) returns boolean language sql as $$
  select position(convert_to(p_payload, 'UTF8') in p_file) > 0 $$;

-- The instrument (see the header). The outcome is 'done' or any error's SQLSTATE and message.
create table t49.seen (part text primary key, outcome text not null);
create table t49.kick ();
create table t49.got (part text primary key, file bytea);   -- an object's bytes, kept to compare with later
create function t49hook.row_security_active(p regclass) returns boolean language plpgsql volatile
  set search_path = public, pg_catalog as $$
declare v_out text; v_part text := current_setting('t49.part', true);
begin
  if coalesce(v_part, '') <> '' and current_setting('t49.armed', true) = p::oid::text then
    perform set_config('t49.part', '', false);
    begin
      perform dblink_exec('h', 'set lock_timeout = ''2s''; ' || current_setting('t49.sql'));
      v_out := 'done';
    exception when others then v_out := sqlstate || ': ' || sqlerrm;
    end;
    perform dblink_exec('h', pg_catalog.format('insert into t49.seen (part, outcome) values (%L, %L)', v_part, v_out));
    lock table t49.kick in access share mode;
  end if;
  return pg_catalog.row_security_active(p::oid);
end $$;
-- arm <part> <relation oid> <sql>: the next row_security_active(<relation>) runs <sql> in the second session
create function t49.arm(p_part text, p_rel oid, p_sql text) returns void language sql as $$
  select set_config('t49.sql', p_sql, false), set_config('t49.armed', p_rel::text, false),
         set_config('t49.part', p_part, false);
$$;
select dblink_connect('h', 'dbname=' || current_database()) as connected \gset discard_

select current_database() || '/t49/' as p \gset

-- ======================= PART A: archive.to_s3, the parent moved inside the export =======================
create schema t49as;
create schema t49ad;
create table t49as.evt (id bigint primary key, payload text not null);
insert into t49as.evt values (1, 'evt');
call pgpm.transmute('t49as.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t49as.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t49as.loose (id bigint, payload text);
insert into t49as.loose values (1, 'mine'), (2, 'mine');
create table t49ad.loose (id bigint, payload text);
insert into t49ad.loose values (10, 'namesake');
select 't49as.evt'::regclass::oid as a_par, 't49as.loose'::regclass::oid as a_mine,
       't49ad.loose'::regclass::oid as a_other \gset
select :'p' || 't49as.loose.ndjson' as a_key, :'p' || 't49ad.loose.ndjson' as a_other_key \gset
select ok(t49.clear(:'a_key') = 404 and t49.clear(:'a_other_key') = 404,
  'A fixture: nothing at either schema''s key for loose before the work');

-- the statement is spelled before the shim is on the search_path, so only the export's own calls can fire it
select format('select archive.to_s3(%s::oid::regclass, %L, null, null)', :'a_par', 'loose') as a_sql \gset
select t49.arm('A', :'a_mine', 'alter table t49as.evt set schema t49ad') as armed \gset discard_
set search_path = t49hook, pg_catalog, public;
select lives_ok(:'a_sql', 'A: archive.to_s3(evt, loose) completed, the parent moved to t49ad inside it');
reset search_path;
-- disarmed here too: a failed export rolls the shim's own disarm back
select set_config('t49.part', '', false) as disarmed \gset discard_
select is((select outcome from t49.seen where part = 'A'), 'done',
  'A LIVENESS: a second session moved the parent to t49ad inside the export, after archive._resolve_child returned');
select is((select relnamespace::regnamespace::text from pg_class where oid = :'a_par'), 't49ad',
  'A LIVENESS: the parent now lives in t49ad, where a namesake loose already stood');
select is(t49.rows(:'a_key'), '1:mine,2:mine',
  'A: the object keyed by the resolved relation''s own schema and name holds exactly its rows 1 and 2');
select is((select relation_oid from archive.object_key_claim where object_key = :'a_key'), :'a_mine'::oid,
  'A: and its claim names that relation');
select is((t49.req('GET', :'a_other_key')).status, 404,
  'A: nothing was written at the namesake''s key t49ad.loose');
select is((select array_agg(object_key order by object_key) from archive.object_key_claim
            where parent_oid = :'a_par' and kind = 'export' and relation_oid = :'a_other'::oid),
          null::text[],
  'A: no export claim of this parent names the namesake, whose rows it never read');

-- the consequence the issue names: the namesake, now loose in the parent's schema, exported through it
select lives_ok(format('select archive.to_s3(%s::oid::regclass, %L, null, null)', :'a_par', 'loose'),
  'A fixture: archive.to_s3(evt, loose) of the namesake now standing in the parent''s schema');
select is(t49.rows(:'a_other_key'), '10:namesake',
  'A: the namesake''s export holds its own row 10, at its own key');
select is(t49.rows(:'a_key'), '1:mine,2:mine',
  'A: and the first object still holds the resolved relation''s rows 1 and 2');

-- ======================= PART B: archive.to_s3_parquet, the same move =======================
create schema t49bs;
create schema t49bd;
create table t49bs.evt (id bigint primary key, payload text not null);
insert into t49bs.evt values (1, 'evt');
call pgpm.transmute('t49bs.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t49bs.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t49bs.loose (id bigint, payload text);
insert into t49bs.loose values (3, 'mine_b'), (4, 'mine_b');
create table t49bd.loose (id bigint, payload text);
insert into t49bd.loose values (20, 'namesake_b');
select 't49bs.evt'::regclass::oid as b_par, 't49bs.loose'::regclass::oid as b_mine,
       't49bd.loose'::regclass::oid as b_other \gset
select :'p' || 't49bs.loose.parquet' as b_key, :'p' || 't49bd.loose.parquet' as b_other_key \gset
select ok(t49.clear(:'b_key') = 404 and t49.clear(:'b_other_key') = 404,
  'B fixture: nothing at either schema''s key for loose before the work');

select format('select archive.to_s3_parquet(%s::oid::regclass, %L, null, null)', :'b_par', 'loose') as b_sql \gset
select t49.arm('B', :'b_mine', 'alter table t49bs.evt set schema t49bd') as armed \gset discard_
set search_path = t49hook, pg_catalog, public;
select lives_ok(:'b_sql', 'B: archive.to_s3_parquet(evt, loose) completed, the parent moved to t49bd inside it');
reset search_path;
select set_config('t49.part', '', false) as disarmed \gset discard_
select is((select outcome from t49.seen where part = 'B'), 'done',
  'B LIVENESS: a second session moved the parent to t49bd inside the export, after archive._resolve_child returned');
select is((select relnamespace::regnamespace::text from pg_class where oid = :'b_par'), 't49bd',
  'B LIVENESS: the parent now lives in t49bd, where a namesake loose already stood');
insert into t49.got values ('B', t49.bytes(:'b_key'));
select ok((select t49.has(file, 'mine_b') and not t49.has(file, 'namesake_b') from t49.got where part = 'B'),
  'B: the object keyed by the resolved relation''s own schema and name holds its rows, not the namesake''s');
select is((select relation_oid from archive.object_key_claim where object_key = :'b_key'), :'b_mine'::oid,
  'B: and its claim names that relation');
select is((t49.req('GET', :'b_other_key')).status, 404,
  'B: nothing was written at the namesake''s key t49bd.loose');
select lives_ok(format('select archive.to_s3_parquet(%s::oid::regclass, %L, null, null)', :'b_par', 'loose'),
  'B fixture: archive.to_s3_parquet(evt, loose) of the namesake now standing in the parent''s schema');
select ok(t49.has(t49.bytes(:'b_other_key'), 'namesake_b'),
  'B: the namesake''s export holds its own row, at its own key');
-- ok over `=`, not is(): two missing objects are both null, and is() would call them the same file
select ok(coalesce(t49.bytes(:'b_key') = (select file from t49.got where part = 'B'), false),
  'B: and the first object is byte for byte the one the first export wrote');

-- ======================= PART C: the schema renamed inside the export =======================
-- Another parent, in t49cn, has already exported its own loose (row 30) under the same prefix, so it owns the
-- base <prefix>t49cn.loose and its claim holds <prefix>t49cn.loose.ndjson. Inside this parent's export the
-- second session renames t49cn away and gives its name to this parent's (and the child's) schema.
create schema t49cs;
create schema t49cn;
create table t49cn.evt (id bigint primary key, payload text not null);
insert into t49cn.evt values (1, 'evt');
call pgpm.transmute('t49cn.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t49cn.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t49cn.loose (id bigint, payload text);
insert into t49cn.loose values (30, 'other');
create table t49cs.evt (id bigint primary key, payload text not null);
insert into t49cs.evt values (1, 'evt');
call pgpm.transmute('t49cs.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t49cs.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t49cs.loose (id bigint, payload text);
insert into t49cs.loose values (5, 'mine'), (6, 'mine');
select 't49cs.evt'::regclass::oid as c_par, 't49cs.loose'::regclass::oid as c_mine,
       't49cn.loose'::regclass::oid as c_other \gset
select :'p' || 't49cn.loose.ndjson' as c_other_key, :'p' || 't49cs.loose.ndjson' as c_old_key,
       :'p' || 't49cn.loose.' || :'c_par' || '.ndjson' as c_key \gset
select ok(t49.clear(:'c_other_key') = 404 and t49.clear(:'c_old_key') = 404 and t49.clear(:'c_key') = 404,
  'C fixture: nothing at any of the three keys before the work');
select lives_ok($$select archive.to_s3('t49cn.evt', 'loose', null, null)$$,
  'C fixture: the other parent exported its loose, row 30, to <prefix>t49cn.loose.ndjson');

select format('select archive.to_s3(%s::oid::regclass, %L, null, null)', :'c_par', 'loose') as c_sql \gset
select t49.arm('C', :'c_mine', 'alter schema t49cn rename to t49cn_was; alter schema t49cs rename to t49cn')
  as armed \gset discard_
set search_path = t49hook, pg_catalog, public;
select lives_ok(:'c_sql', 'C: archive.to_s3(evt, loose) completed, its schema renamed into the other''s name inside it');
reset search_path;
select set_config('t49.part', '', false) as disarmed \gset discard_
select is((select outcome from t49.seen where part = 'C'), 'done',
  'C LIVENESS: a second session gave this parent''s schema the other schema''s name inside the export');
select is(t49.rows(:'c_other_key'), '30:other',
  'C: the other relation''s object at <prefix>t49cn.loose.ndjson still holds exactly its row 30');
select is((select relation_oid from archive.object_key_claim where object_key = :'c_key'), :'c_mine'::oid,
  'C: this export took the oid shape beside it, and its claim names the held relation');
select is(t49.rows(:'c_key'), '5:mine,6:mine',
  'C: and the object there holds exactly the held relation''s rows 5 and 6');

select dblink_disconnect('h') as disconnected \gset discard_
select count(t49.clear(k)) from unnest(array[:'a_key', :'a_other_key', :'b_key', :'b_other_key',
                                             :'c_other_key', :'c_old_key', :'c_key']) k \gset discard_
select * from finish();
