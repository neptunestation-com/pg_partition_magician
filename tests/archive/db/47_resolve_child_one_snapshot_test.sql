-- A synchronous export resolves the relation named p_child in p_parent's schema under ONE catalog snapshot
-- (issue #1062, bullet 2, verified as A1062-2 before review pass 10).
--
-- archive._resolve_child read the parent's schema NAME in one statement and looked `<that name>.p_child` up
-- by name in the next. A second session that swapped two schemas' names between the two (the parent's schema
-- renamed away, another schema given its name) had it resolve, hold and return the NAMESAKE in the schema that
-- took the name. For a recorded child the pgpm.part anchor refused the namesake; for a relation pgpm.part has
-- no row for, which the synchronous functions accept ("any relation in the parent's schema, tracked or not"),
-- it returned the namesake's oid, and archive.to_s3 exported the namesake's rows under the named relation's
-- key with no error. The contract:
--
--   Part A  an untracked relation under a schema swap inside the export: the object holds the named
--           relation's rows, named, its claim names that relation, and the namesake's rows are nowhere
--   Part B  a recorded child under the same swap: exported, its own rows, never refused for the namesake
--   Part C  the control: a recorded child whose name a namesake took in the parent's own schema is still
--           refused by the pgpm.part anchor, and nothing is written
--   Part D  archive._resolve_child itself under the swap: it returns the named relation and holds THAT
--           relation (ACCESS SHARE, to the end of the caller's transaction), whichever one its LOCK met
--
-- THE INSTRUMENT. The window is entered deterministically, with no timing. Inside _resolve_child the only
-- calls between reading anything and locking the child are format() calls that splice the child's name, and
-- the function pins no search_path, so a format(text, name, name) in a schema the caller puts ahead of
-- pg_catalog runs in their place. That shim, armed for one call by the settings t47.part, t47.child and t47.sql
-- and fired by the first such call whose last argument is the armed child's name, runs t47.sql in a second
-- session (dblink, connection `h`) and records what happened there in t47.seen from that session, so the
-- record survives an export that fails; then it returns exactly what pg_catalog.format returns. It also takes
-- a lock on a relation this transaction has not locked yet (t47.kick), which makes this backend read the
-- second session's committed catalog changes at once, as any lock acquisition does; without it the swap
-- would land only at this backend's next new lock, and the window would be entered later than claimed.
--
-- Against the defect the shim fires between the schema-name read and the by-name lookup, the window the issue
-- names. Against the fix there is no such window (one statement reads both), so it fires between that
-- statement and the LOCK, the only gap left, which the fix covers by checking, under the lock and by identity,
-- that the relation it holds is the one it resolved. If _resolve_child ever stops calling format() there, the
-- shim never fires and every LIVENESS line below fails: loudly, never a silent pass.
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the named relations hold
-- 1:mine, 2:mine (A) and 5:first, 6:first (B), the namesakes 10:namesake (A) and 20:namesake (B). The prefix
-- carries current_database() because the bucket outlives a test database, and every key is cleared and
-- witnessed absent before the work that writes it.
set client_min_messages = warning;
create extension if not exists dblink;
select plan(24);

create schema t47;
create schema t47hook;

create function t47.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t47.clear(p_key text) returns int language plpgsql as $$
begin
  perform t47.req('DELETE', p_key);
  return (t47.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t47.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t47.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- The instrument (see the header). The outcome is 'done', 'lock_not_available' (the statement gave up waiting
-- for a lock, SQLSTATE 55P03), or any other error's SQLSTATE and message.
create table t47.seen (part text primary key, outcome text not null);
create table t47.kick ();
create function t47.attempt(p_part text, p_sql text) returns text language plpgsql set search_path = public, pg_catalog as $$
declare v_out text;
begin
  begin
    perform dblink_exec('h', 'set lock_timeout = ''1s''; ' || p_sql);
    v_out := 'done';
  exception
    when lock_not_available then v_out := 'lock_not_available';
    when others then v_out := sqlstate || ': ' || sqlerrm;
  end;
  perform dblink_exec('h', pg_catalog.format('insert into t47.seen (part, outcome) values (%L, %L)', p_part, v_out));
  return v_out;
end $$;
create function t47hook.format(p_fmt text, p_a name, p_b name) returns text language plpgsql
  set search_path = public, pg_catalog as $$
declare v_part text := current_setting('t47.part', true);
begin
  if coalesce(v_part, '') <> '' and p_b = current_setting('t47.child', true) then
    perform set_config('t47.part', '', false);
    perform t47.attempt(v_part, current_setting('t47.sql'));
    lock table t47.kick in access share mode;
  end if;
  return pg_catalog.format(p_fmt, p_a, p_b);
end $$;
-- arm <part> <child> <sql>: the next format(text, name, name) whose last argument is <child> runs <sql>
create function t47.arm(p_part text, p_child name, p_sql text) returns void language sql as $$
  select set_config('t47.sql', p_sql, false), set_config('t47.child', p_child, false), set_config('t47.part', p_part, false);
$$;
select dblink_connect('h', 'dbname=' || current_database()) as connected \gset discard_

select current_database() || '/t47/' as p \gset

-- ======================= PART A: an untracked relation under a schema swap =======================
create schema t47a;
create schema t47a_o;
create table t47a.evt (id bigint primary key, payload text not null);
insert into t47a.evt values (1, 'evt');
call pgpm.transmute('t47a.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t47a.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t47a.loose (id bigint, payload text);
insert into t47a.loose values (1, 'mine'), (2, 'mine');
create table t47a_o.loose (id bigint, payload text);
insert into t47a_o.loose values (10, 'namesake');
select 't47a.evt'::regclass::oid as a_parent, 't47a.loose'::regclass::oid as a_loose,
       't47a_o.loose'::regclass::oid as a_namesake \gset
-- after the swap the parent's schema is named t47a_o, so that is where its export of `loose` is keyed
select :'p' || 't47a_o.loose.ndjson' as a_key, :'p' || 't47a.loose.ndjson' as a_old_key \gset

select ok(t47.clear(:'a_key') = 404 and t47.clear(:'a_old_key') = 404,
  'fixture: (A) nothing at either schema''s key for loose before the work');
select is((select count(*)::int from pgpm.part where parent_table = :'a_parent'::oid::regclass and child_name = 'loose'), 0,
  'fixture: (A) pgpm.part has no row for loose, so no anchor stands behind its resolution');

-- the statement is spelled before the shim is on the search_path, so only the export's own calls can fire it
select format('select archive.to_s3(%s::oid::regclass, %L, null, null)', :'a_parent', 'loose') as a_sql \gset
select t47.arm('A', 'loose',
  'alter schema t47a rename to t47a_swap; alter schema t47a_o rename to t47a; alter schema t47a_swap rename to t47a_o')
  as armed \gset discard_
set search_path = t47hook, pg_catalog, public;
select lives_ok(:'a_sql',
  'A: archive.to_s3 of the untracked relation loose completed, a second session''s schema swap committed inside it');
reset search_path;
-- disarmed here too: a failed export rolls the shim's own disarm back
select set_config('t47.part', '', false) as disarmed \gset discard_
select is((select outcome from t47.seen where part = 'A'), 'done',
  'LIVENESS: (A) the second session swapped the two schemas'' names inside the export');
select ok(to_regclass('t47a_o.loose')::oid = :'a_loose'::oid and to_regclass('t47a.loose')::oid = :'a_namesake'::oid,
  'LIVENESS: (A) the parent''s schema now has the other name, and the name it had leads to the namesake');
select is(t47.rows(:'a_key'), '1:mine,2:mine',
  'A: the object holds exactly the named relation''s rows 1 and 2, not the namesake''s row 10');
select is((select relation_oid from archive.object_key_claim where object_key = :'a_key'), :'a_loose'::oid,
  'A: the claim names the relation the caller named');
select is((t47.req('GET', :'a_old_key')).status, 404,
  'A: nothing was written under the schema name the parent had before the swap');

-- ======================= PART B: a recorded child under the same swap =======================
create schema t47b;
create schema t47b_o;
create table t47b.evt (id bigint primary key, payload text not null);
insert into t47b.evt values (5, 'first'), (6, 'first');
call pgpm.transmute('t47b.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t47b.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as b_child, child_oid as b_oid from pgpm.part
 where parent_table = 't47b.evt'::regclass and lo = '0' \gset
select format('create table t47b_o.%I (id bigint, payload text); insert into t47b_o.%I values (20, %L)',
              :'b_child', :'b_child', 'namesake') as b_namesake_sql \gset
select lives_ok(:'b_namesake_sql', 'fixture: (B) a namesake of the recorded child, row 20, in the other schema');
select 't47b.evt'::regclass::oid as b_parent \gset
select :'p' || 't47b_o.' || :'b_child' || '.ndjson' as b_key \gset
select is(t47.clear(:'b_key'), 404, 'fixture: (B) nothing at the export''s key before the work');

select format('select archive.to_s3(%s::oid::regclass, %L, null, null)', :'b_parent', :'b_child') as b_sql \gset
select t47.arm('B', :'b_child',
  'alter schema t47b rename to t47b_swap; alter schema t47b_o rename to t47b; alter schema t47b_swap rename to t47b_o')
  as armed \gset discard_
set search_path = t47hook, pg_catalog, public;
select lives_ok(:'b_sql',
  'B: archive.to_s3 of the recorded child completed, a second session''s schema swap committed inside it');
reset search_path;
select set_config('t47.part', '', false) as disarmed \gset discard_
select is((select outcome from t47.seen where part = 'B'), 'done',
  'LIVENESS: (B) the second session swapped the two schemas'' names inside the export');
select ok(to_regclass(format('t47b_o.%I', :'b_child'))::oid = :'b_oid'::oid
          and to_regclass(format('t47b.%I', :'b_child'))::oid is distinct from :'b_oid'::oid,
  'LIVENESS: (B) the recorded child moved with its schema, and its old spelling leads to the namesake');
select is(t47.rows(:'b_key'), '5:first,6:first',
  'B: the object holds exactly the recorded child''s rows 5 and 6, not the namesake''s row 20');
select is((select relation_oid from archive.object_key_claim where object_key = :'b_key'), :'b_oid'::oid,
  'B: the claim names the recorded child');

-- ======================= PART C: the control, the anchor still refuses =======================
-- A namesake that really is p_child in the parent's schema, the recorded child renamed out of its way: no
-- swap, so the name and the identity agree, and only the pgpm.part anchor stands between it and the export.
create schema t47c;
create table t47c.evt (id bigint primary key, payload text not null);
insert into t47c.evt values (7, 'first');
call pgpm.transmute('t47c.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t47c.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as c_child, child_oid as c_oid from pgpm.part
 where parent_table = 't47c.evt'::regclass and lo = '0' \gset
select :'p' || 't47c.' || :'c_child' || '.ndjson' as c_key \gset
select format('alter table t47c.%I rename to %I; create table t47c.%I (id bigint, payload text); insert into t47c.%I values (30, %L)',
              :'c_child', :'c_child' || '_was', :'c_child', :'c_child', 'namesake') as c_sql \gset
select lives_ok(:'c_sql', 'fixture: (C) the recorded child renamed away and a namesake, row 30, created by its name');
select ok(to_regclass(format('t47c.%I', :'c_child'))::oid is distinct from :'c_oid'::oid,
  'LIVENESS: (C) the recorded child''s name now leads to another relation');
select is(t47.clear(:'c_key'), 404, 'fixture: (C) nothing at the export''s key before the work');
select throws_like(format('select archive.to_s3(%L, %L, null, null)', 't47c.evt', :'c_child'),
  format('%%t47c.%s is oid %% now, not the oid %s recorded for this partition; refusing to archive it%%', :'c_child', :'c_oid'),
  'C: the namesake standing at the recorded child''s name is refused by the pgpm.part anchor');
select is((t47.req('GET', :'c_key')).status, 404, 'C: and nothing was written at its key');

-- ======================= PART D: the resolution and the hold, directly =======================
-- The schemas of part A are swapped back inside the call: the parent's schema is t47a_o going in and t47a
-- coming out, and the namesake stands at t47a_o.loose by then.
select t47.arm('D', 'loose',
  'alter schema t47a rename to t47a_swap; alter schema t47a_o rename to t47a; alter schema t47a_swap rename to t47a_o')
  as armed \gset discard_
begin;
set local search_path = t47hook, pg_catalog, public;
select archive._resolve_child(:'a_parent'::oid::regclass, 'loose', 'tests/archive/db/47')::oid as d_got \gset
reset search_path;
select is((select outcome from t47.seen where part = 'D'), 'done',
  'LIVENESS: (D) the second session swapped the schemas'' names back inside archive._resolve_child');
select ok(exists (select 1 from pg_locks l
                   where l.locktype = 'relation' and l.relation = :'a_namesake'::oid and l.pid = pg_backend_pid() and l.granted),
  'LIVENESS: (D) a LOCK inside the call met the namesake, so the swap landed inside the window the hold must close');
select is(:'d_got'::oid, :'a_loose'::oid,
  'D: archive._resolve_child returned the relation the caller named, not the namesake now at its old spelling');
select ok(exists (select 1 from pg_locks l
                   where l.locktype = 'relation' and l.relation = :'a_loose'::oid and l.pid = pg_backend_pid()
                     and l.mode = 'AccessShareLock' and l.granted),
  'D: and this transaction holds that relation, the hold an export reads under');
commit;
select set_config('t47.part', '', false) as disarmed \gset discard_

select dblink_disconnect('h') as disconnected \gset discard_
select count(t47.clear(k)) from unnest(array[:'a_key', :'a_old_key', :'b_key', :'c_key']) k \gset discard_
select * from finish();
