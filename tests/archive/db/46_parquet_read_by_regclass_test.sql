-- A Parquet export reads the relation it was handed, by identity, never a namesake its old spelling reaches
-- (issue #1055, bullet 1, verified as A1055-1 before review pass 10).
--
-- archive._pq_to_parquet (and the range encoder, archive._pq_to_parquet_range) took (schema, name) from the
-- oid before its column loop, and archive._pq_snapshot read the rows by that name after it. ALTER SCHEMA ...
-- RENAME takes no lock that conflicts with the ACCESS SHARE archive._resolve_child holds on the child (#1030),
-- so a second session that swapped the child's schema with another schema holding a same-shaped table of the
-- same name, committed in between, had the export read the namesake's rows, and archive.to_s3_parquet PUT
-- them under the child's key with no error. The contract:
--
--   Part A  archive.to_s3_parquet: with a schema swap committed between the encoder's start and its read, the
--           object holds exactly the child's own rows (byte for byte the oid's own encode), none of the
--           namesake's, and the claim names the child's oid
--   Part B  the range encoder, the automatic path's (archive_to_s3_parquet strategy): the same swap, of the
--           parent's schema, still has the file hold exactly the parent's own [lo, hi) rows
--   Part C  the check that closes what rendering the regclass only narrows: archive._refuse_foreign_read
--           refuses once a read has reached a relation outside the one meant, and passes a read of the
--           relation itself, its index included
--   Part D  the window between the rendering and the INSERT's parse, entered: a swap committed there that
--           puts the rendered name on one of the parent's OWN partitions (attached under the parent's name in
--           another schema) has the range encoder refuse, not archive that one partition's rows as the
--           parent's chunk (review of #1059, V-01: it encoded 0 rows of the parent's 5, with no error)
--   Part E  the check fires from inside both readers that call it: a range read of a parent that newly
--           locks a relation carrying the parent's name (here, that same-named partition) is refused by
--           archive._pq_snapshot and by archive._encode_upload_ndjson_single, and a range of the same parent
--           that does not reach it is read as before
--
-- THE INSTRUMENT. The window is entered with no timing. archive._pq_snapshot builds its temp table with
-- CREATE TABLE AS before the INSERT that reads the rows, and an event trigger on that command's end, armed for
-- one call by the settings t46.part and t46.sql, runs t46.sql in a second session (dblink, connection `h`),
-- where it commits, and records the outcome there in t46h.seen. In the code #1055 reported, the encoder's
-- (schema, name) were taken before that point and read after it. The trigger changes nothing the export
-- reads.
--
-- Fixtures are asymmetric so a replaced file cannot pass an identity check: the relations exported hold
-- 1:orig-a, 2:orig-a (part A) and 5:orig-b, 6:orig-b, 7:orig-b (part B); the namesakes hold 9:namesake-a
-- and 8:namesake-b. Files are uncompressed, so the payload strings are visible in their bytes. The prefix
-- carries current_database() because the bucket outlives a test database.
set client_min_messages = warning;
create extension if not exists dblink;
select plan(29);

create schema t46h;   -- the helpers live apart from every schema the second session renames

create function t46h.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t46h.clear(p_key text) returns int language plpgsql as $$
begin
  perform t46h.req('DELETE', p_key);
  return (t46h.req('GET', p_key)).status;
end $$;
-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/39, so a Parquet object compares byte for byte.
create function t46h.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t46h.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;
-- Whether a file carries a payload string (uncompressed, so a value's bytes appear as they are).
create function t46h.has(p_file bytea, p_payload text) returns boolean language sql as $$
  select position(convert_to(p_payload, 'UTF8') in p_file) > 0 $$;

-- The instrument (see the header). The outcome is 'done' or any error's SQLSTATE and message.
create table t46h.seen (part text primary key, outcome text not null);
create function t46h.attempt(p_part text, p_sql text) returns text language plpgsql set search_path = public, pg_catalog as $$
declare v_out text;
begin
  begin
    perform dblink_exec('h', 'set lock_timeout = ''1s''; ' || p_sql);
    v_out := 'done';
  exception when others then v_out := sqlstate || ': ' || sqlerrm;
  end;
  perform dblink_exec('h', format('insert into t46h.seen (part, outcome) values (%L, %L)', p_part, v_out));
  return v_out;
end $$;
create function t46h.window() returns event_trigger language plpgsql as $$
declare v_part text := current_setting('t46.part', true);
begin
  if coalesce(v_part, '') = '' then return; end if;
  perform set_config('t46.part', '', false);
  perform t46h.attempt(v_part, current_setting('t46.sql'));
end $$;
create event trigger t46_window on ddl_command_end when tag in ('CREATE TABLE AS') execute function t46h.window();
select dblink_connect('h', 'dbname=' || current_database()) as connected \gset discard_

select current_database() || '/t46/' as p \gset
-- the second session's swap of two schemas' names, in one committed transaction
create function t46h.swap_sql(p_a name, p_b name) returns text language sql as $$
  select format('alter schema %1$I rename to %3$I; alter schema %2$I rename to %1$I; alter schema %3$I rename to %2$I',
                p_a, p_b, p_a || '_swap') $$;

-- ======================= PART A: archive.to_s3_parquet =======================
create schema t46a;
create table t46a.evt (id bigint primary key, payload text not null);
insert into t46a.evt values (1, 'orig-a'), (2, 'orig-a');
call pgpm.transmute('t46a.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t46a.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as a_child, child_oid as a_oid from pgpm.part
 where parent_table = 't46a.evt'::regclass and lo = '0' \gset
-- the namesake: a schema holding a same-shaped table under the child's name, ready to take t46a's name
create schema t46a_x;
select format('create table t46a_x.%I (id bigint primary key, payload text not null); insert into t46a_x.%I values (9, %L)',
              :'a_child', :'a_child', 'namesake-a') as mk \gset
:mk;
-- the parent's schema is named t46a_x once the swap has run, and the export's key names it as it is then
select is(t46h.clear(:'p' || 't46a_x.' || :'a_child' || '.parquet'), 404,
  'A fixture: nothing at the key the export writes before the work');

select set_config('t46.sql', t46h.swap_sql('t46a', 't46a_x'), false) as armed \gset discard_
select set_config('t46.part', 'A', false) as armed \gset discard_
select lives_ok(format('select archive.to_s3_parquet(%L, %L, null, null)', 't46a.evt', :'a_child'),
  'A: archive.to_s3_parquet completed, a second session''s schema swap committed inside it');
-- disarmed here too: a failed export rolls the trigger's own disarm back
select set_config('t46.part', '', false) as disarmed \gset discard_
select is((select outcome from t46h.seen where part = 'A'), 'done',
  'A LIVENESS: the second session swapped t46a and t46a_x inside the export, after the encoder began');
select ok(to_regclass(format('t46a.%I', :'a_child'))::oid is distinct from :'a_oid'::oid
          and to_regclass(format('t46a_x.%I', :'a_child'))::oid = :'a_oid'::oid,
  'A LIVENESS: the child''s old spelling now names the namesake, and the child moved with its schema');
-- coalesced, so a run whose export failed still reaches every assertion below rather than stopping here
select coalesce((select object_key from archive.object_key_claim
                  where relation_oid = :'a_oid'::oid and object_key like '%.parquet'), '(no claim)') as a_key \gset
select ok(length(t46h.bytes(:'a_key')) > 0,
  'A: the claim for the child''s oid names an object, and the object is there');
select is(t46h.bytes(:'a_key'), archive._pq_to_parquet(:'a_oid'::oid::regclass, false),
  'A: the object is byte for byte the encode of the child''s own oid, rows 1 and 2');
select ok(t46h.has(t46h.bytes(:'a_key'), 'orig-a'), 'A: it carries the child''s payload');
select ok(not t46h.has(t46h.bytes(:'a_key'), 'namesake-a'),
  'A: and holds none of the namesake''s row 9');
select is(t46h.clear(:'a_key'), 404, 'A: the object is cleared');

-- ======================= PART B: the range encoder =======================
create schema t46b;
create table t46b.evt (id bigint primary key, payload text not null);
insert into t46b.evt values (5, 'orig-b'), (6, 'orig-b'), (7, 'orig-b');
call pgpm.transmute('t46b.evt', 'id', 10000::bigint, p_paused => true);
select 't46b.evt'::regclass::oid as b_oid \gset
create schema t46b_x;
create table t46b_x.evt (id bigint primary key, payload text not null);
insert into t46b_x.evt values (8, 'namesake-b');
create table t46h.got (part text primary key, file bytea);

select set_config('t46.sql', t46h.swap_sql('t46b', 't46b_x'), false) as armed \gset discard_
select set_config('t46.part', 'B', false) as armed \gset discard_
select lives_ok(format('insert into t46h.got select %L, archive._pq_to_parquet_range(%s::oid::regclass, %L, %L, %L, false)',
                       'B', :'b_oid', 'id', '0', '10000'),
  'B: the range encoder completed, a second session''s swap of the parent''s schema committed inside it');
select set_config('t46.part', '', false) as disarmed \gset discard_
select is((select outcome from t46h.seen where part = 'B'), 'done',
  'B LIVENESS: the second session swapped t46b and t46b_x inside the encode');
select ok(to_regclass('t46b.evt')::oid is distinct from :'b_oid'::oid and to_regclass('t46b_x.evt')::oid = :'b_oid'::oid,
  'B LIVENESS: the parent''s old spelling now names the namesake, and the parent moved with its schema');
select ok(length((select file from t46h.got where part = 'B')) > 0,
  'B: the encoder returned a file');
select is((select file from t46h.got where part = 'B'),
          archive._pq_to_parquet_range(:'b_oid'::oid::regclass, 'id', '0', '10000', false),
  'B: the file is byte for byte the encode of the parent''s own oid over [0, 10000), rows 5, 6 and 7');
select ok(t46h.has((select file from t46h.got where part = 'B'), 'orig-b'), 'B: it carries the parent''s payload');
select ok(not t46h.has((select file from t46h.got where part = 'B'), 'namesake-b'),
  'B: and holds none of the namesake''s row 8');

-- ======================= PART C: what a read reached =======================
create schema t46c;
create table t46c.mine (id bigint primary key, payload text);
insert into t46c.mine values (1, 'mine'), (2, 'mine');
create table t46c.other (id bigint primary key);
insert into t46c.other values (3);
-- whether this transaction holds a lock on the relation
create function t46h.held(p_rel oid) returns boolean language sql as $$
  select exists (select 1 from pg_locks l where l.locktype = 'relation' and l.pid = pg_backend_pid() and l.relation = p_rel) $$;

begin;
-- pgTAP's own tables are locked by its first assertion in this transaction, before the sample below
select pass('C: a transaction of its own, pgTAP''s own tables taken before the sample');
select archive._held_relations() as c_before \gset
select string_agg(payload, ',' order by id) as c_read from t46c.mine \gset
select ok(t46h.held('t46c.mine'::regclass) and t46h.held('t46c.mine_pkey'::regclass)
          and not ('t46c.mine_pkey'::regclass::oid = any (:'c_before'::oid[])),
  'C LIVENESS: the read of t46c.mine newly holds it and its index, which the planner opened');
select lives_ok(format('select archive._refuse_foreign_read(%L, %L, %L::oid[])', 't46', 't46c.mine', :'c_before'),
  'C: a read of the relation itself, its index included, is not refused');
select count(*) as c_other from t46c.other \gset
select ok(t46h.held('t46c.other'::regclass) and not ('t46c.other'::regclass::oid = any (:'c_before'::oid[])),
  'C LIVENESS: then another relation was read, so this transaction newly holds a lock on it');
select throws_like(format('select archive._refuse_foreign_read(%L, %L, %L::oid[])', 't46', 't46c.mine', :'c_before'),
  '%t46 reached t46c.other%while reading t46c.mine%',
  'C: once a read has reached another relation, it is refused, naming the relation reached');
commit;

-- ======================= PART D: the swap lands on a partition named like the parent =======================
-- The instrument is the verifier's (V-01): a BEFORE TRUNCATE trigger on the reused snapshot table, whose
-- TRUNCATE runs between the rendering and the INSERT, commits the swap from the second session and then takes
-- a new lock on a system catalog, so this backend reads the catalog change as the INSERT's parse would. Its
-- state lives in transaction-local settings, not a table: a table it locked inside the encode would be a
-- relation the check rightly refuses, and would mask what this part probes.
create schema t46d; create schema t46d_x;
create table t46d.evt (id bigint not null, payload text) partition by range (id);
create table t46d.evt_p0 partition of t46d.evt for values from (0) to (100);
create table t46d_x.evt partition of t46d.evt for values from (1000) to (2000);   -- the parent's own name
insert into t46d.evt select g, 'parent-d' from generate_series(1, 5) g;
insert into t46d.evt values (1500, 'partition-d');
select 't46d.evt'::regclass::oid as d_oid \gset
create function t46h.swap_on_truncate() returns trigger language plpgsql as $$
begin
  if current_setting('t46.d_armed', true) = 'yes' then
    perform set_config('t46.d_armed', '', true);
    perform dblink_exec('h', t46h.swap_sql('t46d', 't46d_x'));
    lock table pg_catalog.pg_description in access share mode;   -- a new lock: the catalog change is read
  end if;
  return null;
end $$;

begin;
-- the snapshot table is ON COMMIT DROP, so the encodes and the trigger on it share this one transaction
select is((select c.p_num_rows from archive._pq_to_parquet_range_counted(:'d_oid'::oid::regclass, 'id', '0', '100', false) c),
          5::bigint, 'D LIVENESS: before the swap the range encoder reads the parent''s 5 rows of [0, 100)');
create trigger t46_d_swap before truncate on pg_temp.archive_pq_snapshot
  for each statement execute function t46h.swap_on_truncate();
select set_config('t46.d_armed', 'yes', true) as armed \gset discard_
select throws_like(format('select archive._pq_to_parquet_range_counted(%s::oid::regclass, %L, %L, %L, false)',
                          :'d_oid', 'id', '0', '100'),
  '%archive._pq_snapshot reached t46d.evt%while reading t46d_x.evt%',
  'D: the range encoder refuses once its rendered name reached the partition named like the parent');
select ok(to_regclass('t46d_x.evt')::oid = :'d_oid'::oid
          and exists (select 1 from pg_inherits where inhrelid = to_regclass('t46d.evt') and inhparent = :'d_oid'::oid),
  'D LIVENESS: the swap committed inside the encode, and the parent''s old spelling names one of its own partitions');
commit;

-- ======================= PART E: the check fires inside both readers =======================
create schema t46e; create schema t46e_x;
create table t46e.evt (id bigint primary key, payload text not null);
insert into t46e.evt values (1, 'parent-e'), (2, 'parent-e');
call pgpm.transmute('t46e.evt', 'id', 10000::bigint, p_paused => true);
select archive.configure('t46e.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
create table t46e_x.evt partition of t46e.evt for values from (900000000) to (900010000);   -- the parent's own name
insert into t46e.evt values (900000001, 'partition-e');
select ok(exists (select 1 from pg_inherits where inhrelid = 't46e_x.evt'::regclass and inhparent = 't46e.evt'::regclass)
          and (select count(*) from t46e_x.evt) = 1,
  'E LIVENESS: t46e_x.evt is a partition of t46e.evt, carries its name, and holds row 900000001');
select lives_ok($$ select archive._pq_to_parquet_range('t46e.evt', 'id', '0', '10000', false) $$,
  'E LIVENESS: the range encoder reads [0, 10000), which does not reach that partition');
select throws_like($$ select archive._pq_to_parquet_range('t46e.evt', 'id', '900000000', '900010000', false) $$,
  '%archive._pq_snapshot reached t46e_x.evt%while reading t46e.evt%',
  'E: the range encoder refuses a read that newly locked a relation carrying the parent''s name');
select lives_ok($$ select * from archive._encode_upload_ndjson_single('t46e.evt', '0', '10000', false) $$,
  'E LIVENESS: the NDJSON strategy''s read of [0, 10000) completes');
select throws_like($$ select * from archive._encode_upload_ndjson_single('t46e.evt', '900000000', '900010000', false) $$,
  '%archive._encode_upload_ndjson_single reached t46e_x.evt%while reading t46e.evt%',
  'E: the NDJSON strategy refuses the same read, from inside its own call of the check');

select dblink_disconnect('h') as disconnected \gset discard_
drop event trigger t46_window;
select * from finish();
