-- A synchronous export reads the relation it resolved and claimed, and nothing else (issue #1030, bullet 1,
-- verified as A1030-1 before review pass 10).
--
-- archive.to_s3 resolved the child (archive._resolve_child) and claimed the object key for that oid
-- (archive._owned_key), then read the child LATER by `%I.%I`, its schema and name, holding no lock on it. A
-- second session that dropped the child and created another relation by its name in that window had the
-- export read the NEW relation's rows and PUT them under the OLD relation's claim, over its export: after the
-- documented export-then-drop workflow, the only copy of those rows, gone with exit 0. The contract:
--
--   Part A  the issue's sequence: a concurrent DROP of the child waits for the export (here it gives up at
--           its lock_timeout), the export writes the rows of the relation it claimed, and the same DROP
--           succeeds once the export has committed
--   Part B  the read follows the relation, not its spelling: a second session that renames the child's
--           schema away and creates a namesake in a new schema of the old name (a rename the child's own
--           lock does not stop) still has the export write the claimed relation's rows
--   Part C  the hold itself: archive._resolve_child, which archive.to_s3 and archive.to_s3_parquet both call
--           before anything else, leaves the child locked to the end of the caller's transaction
--
-- THE INSTRUMENT. The window is entered deterministically, with no timing: a BEFORE INSERT trigger on
-- archive.object_key_claim, armed for one call by the settings t45.part and t45.sql, runs t45.sql in a second
-- session (dblink, connection `h`) from inside the export, after the export resolved its child and while it
-- claims the key, and records what happened there in t45.seen from that second session, so the record
-- survives an export that fails. The second session sets lock_timeout, because the export waits on it
-- through dblink, a wait the deadlock detector cannot see. The trigger changes nothing the export reads.
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the claimed relations hold
-- 1:first, 2:first, 3:first (part A) and 5:first, 6:first (part B), the namesakes 10:second, 11:second and
-- 20:third. The prefix carries current_database() because the bucket outlives a test database, and every key
-- is cleared and witnessed absent before the work that writes it.
set client_min_messages = warning;
create extension if not exists dblink;
select plan(21);

create schema t45;

create function t45.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t45.clear(p_key text) returns int language plpgsql as $$
begin
  perform t45.req('DELETE', p_key);
  return (t45.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t45.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t45.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- The instrument (see the header). The outcome is 'done', 'lock_not_available' (the statement gave up waiting
-- for a lock, SQLSTATE 55P03), or any other error's SQLSTATE and message.
create table t45.seen (part text primary key, outcome text not null);
-- Runs p_sql in the second session and records the outcome there under p_part.
create function t45.attempt(p_part text, p_sql text) returns text language plpgsql set search_path = public, pg_catalog as $$
declare v_out text;
begin
  begin
    perform dblink_exec('h', 'set lock_timeout = ''1s''; ' || p_sql);
    v_out := 'done';
  exception
    when lock_not_available then v_out := 'lock_not_available';
    when others then v_out := sqlstate || ': ' || sqlerrm;
  end;
  perform dblink_exec('h', format('insert into t45.seen (part, outcome) values (%L, %L)', p_part, v_out));
  return v_out;
end $$;
create function t45.window() returns trigger language plpgsql as $$
declare v_part text := current_setting('t45.part', true);
begin
  if coalesce(v_part, '') = '' then return new; end if;
  perform set_config('t45.part', '', false);
  perform t45.attempt(v_part, current_setting('t45.sql'));
  return new;
end $$;
create trigger t45_window before insert on archive.object_key_claim
  for each row execute function t45.window();
select dblink_connect('h', 'dbname=' || current_database()) as connected \gset discard_

select current_database() || '/t45/' as p \gset

-- ======================= PART A: a concurrent DROP and namesake =======================
create table t45.evt (id bigint primary key, payload text not null);
insert into t45.evt values (1, 'first'), (2, 'first'), (3, 'first');
call pgpm.transmute('t45.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t45.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as a_child, child_oid as a_oid from pgpm.part
 where parent_table = 't45.evt'::regclass and lo = '0' \gset
select :'p' || 't45.' || :'a_child' || '.ndjson' as a_key \gset

select is(t45.clear(:'a_key'), 404, 'fixture: (A) nothing at the export''s key before the work');
select lives_ok(format('select archive.to_s3(%L, %L, null, null)', 't45.evt', :'a_child'),
  'LIVENESS: (A) the first archive.to_s3 of the [0, 10000) child completed');
select is(t45.rows(:'a_key'), '1:first,2:first,3:first',
  'LIVENESS: (A) its object holds rows 1, 2 and 3, now the export the next run must not replace');

-- the re-run, with a second session dropping the child and creating another relation by its name inside it
select set_config('t45.sql', format(
  'drop table t45.%1$I; create table t45.%1$I partition of t45.evt for values from (0) to (10000); '
  'insert into t45.%1$I values (10, %2$L), (11, %2$L)', :'a_child', 'second'), false) as armed \gset discard_
select set_config('t45.part', 'A', false) as armed \gset discard_
select lives_ok(format('select archive.to_s3(%L, %L, null, null)', 't45.evt', :'a_child'),
  'A: the re-run export completed, a second session''s DROP of its child attempted inside it');
-- disarmed here too: a failed export rolls the trigger's own disarm back
select set_config('t45.part', '', false) as disarmed \gset discard_
select is((select count(*)::int from t45.seen where part = 'A'), 1,
  'LIVENESS: (A) the second session made its attempt inside the re-run, after the export resolved its child');
select is((select outcome from t45.seen where part = 'A'), 'lock_not_available',
  'A: the DROP waited for the export, which holds the child it resolved, and gave up at its lock_timeout');
select is(to_regclass(format('t45.%I', :'a_child'))::oid, :'a_oid'::oid,
  'A: the child is still the relation the export resolved and claimed');
select is(t45.rows(:'a_key'), '1:first,2:first,3:first',
  'A: the object holds exactly the claimed relation''s rows 1, 2 and 3, not a namesake''s');
select is((select relation_oid from archive.object_key_claim where object_key = :'a_key'), :'a_oid'::oid,
  'A: the claim names the relation the object holds');
-- the hold lasts as long as the export's transaction, and no longer
select lives_ok(format('select dblink_exec(%L, %L)', 'h', current_setting('t45.sql')),
  'LIVENESS: (A) the same DROP and namesake succeed once the export has committed');
select isnt(to_regclass(format('t45.%I', :'a_child'))::oid, :'a_oid'::oid,
  'LIVENESS: (A) and the name is now another relation''s');

-- ======================= PART B: the child's schema renamed away =======================
create schema t45b;
create table t45b.evt (id bigint primary key, payload text not null);
insert into t45b.evt values (5, 'first'), (6, 'first');
call pgpm.transmute('t45b.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t45b.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as b_child, child_oid as b_oid from pgpm.part
 where parent_table = 't45b.evt'::regclass and lo = '0' \gset
select :'p' || 't45b.' || :'b_child' || '.ndjson' as b_key \gset

select is(t45.clear(:'b_key'), 404, 'fixture: (B) nothing at the export''s key before the work');
select lives_ok(format('select archive.to_s3(%L, %L, null, null)', 't45b.evt', :'b_child'),
  'LIVENESS: (B) the first archive.to_s3 of the [0, 10000) child of t45b.evt completed');
select is(t45.rows(:'b_key'), '5:first,6:first', 'LIVENESS: (B) its object holds rows 5 and 6');

select set_config('t45.sql', format(
  'alter schema t45b rename to t45b_old; create schema t45b; '
  'create table t45b.%1$I (id bigint primary key, payload text not null); insert into t45b.%1$I values (20, %2$L)',
  :'b_child', 'third'), false) as armed \gset discard_
select set_config('t45.part', 'B', false) as armed \gset discard_
select lives_ok(format('select archive.to_s3(%L, %L, null, null)', 't45b.evt', :'b_child'),
  'B: the re-run export completed, a second session''s schema rename attempted inside it');
-- disarmed here too: a failed export rolls the trigger's own disarm back
select set_config('t45.part', '', false) as disarmed \gset discard_
select is((select outcome from t45.seen where part = 'B'), 'done',
  'LIVENESS: (B) the second session renamed t45b away and created a namesake inside the re-run');
select ok(to_regclass(format('t45b.%I', :'b_child'))::oid is distinct from :'b_oid'::oid
          and to_regclass(format('t45b_old.%I', :'b_child'))::oid = :'b_oid'::oid,
  'LIVENESS: (B) the old spelling of the child now names another relation, and the claimed one moved with its schema');
select is(t45.rows(:'b_key'), '5:first,6:first',
  'B: the object holds exactly the claimed relation''s rows 5 and 6, not the namesake''s row 20');

-- ======================= PART C: the hold itself =======================
-- archive.to_s3_parquet resolves its child, encodes it, and only then claims its key, so the window between
-- its resolve and its encode's read holds no statement an instrument can enter. What closes that window is
-- the hold archive._resolve_child takes, which both synchronous exports call before anything else; this part
-- asserts the hold directly, in a transaction of this session.
create schema t45c;
create table t45c.evt (id bigint primary key, payload text not null);
insert into t45c.evt values (7, 'pq'), (8, 'pq');
call pgpm.transmute('t45c.evt', 'id', 10000::bigint, p_paused => true);
select child_name as c_child, child_oid as c_oid from pgpm.part
 where parent_table = 't45c.evt'::regclass and lo = '0' \gset

begin;
select is(archive._resolve_child('t45c.evt', :'c_child', 'tests/archive/db/45')::oid, :'c_oid'::oid,
  'LIVENESS: (C) archive._resolve_child resolved the child to the relation pgpm.part records');
select is(t45.attempt('C', format('drop table t45c.%I', :'c_child')), 'lock_not_available',
  'C: a second session''s DROP of the child waits for the transaction that resolved it, and gave up at its lock_timeout');
commit;
-- the attempt in a statement of its own: one statement would look the child up in the catalog it began with
select t45.attempt('C after', format('drop table if exists t45c.%I', :'c_child')) as c_after \gset
select ok(:'c_after' = 'done' and to_regclass(format('t45c.%I', :'c_child')) is null,
  'LIVENESS: (C) the same DROP succeeds once that transaction has ended, and the child is gone');

select dblink_disconnect('h') as disconnected \gset discard_
select count(t45.clear(k)) from unnest(array[:'a_key', :'b_key']) k \gset discard_
select * from finish();
