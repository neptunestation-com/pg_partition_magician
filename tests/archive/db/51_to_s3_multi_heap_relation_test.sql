-- archive.to_s3 pages the relation it exports by a keyset cursor and, after the last page, checks that the
-- rows it paged are the rows the relation holds (#673). The synchronous export functions accept any relation in
-- the parent's schema, a partitioned table or an inheritance parent included (archive._resolve_child checks the
-- name, and archive._refuse_foreign_read admits a relation's own descendants), and such a relation reads from
-- more than one heap. The cursor used to be (control, ctid), a total order within ONE heap only: two heaps can
-- each hold a row with the same control value at the same ctid, and when a page boundary fell between those
-- twins the next page's `> cursor` skipped the second. The conservation check then refused the export as "a
-- write changed the partition during the export" with nothing writing, on every retry (issue #1168), against
-- pgpm_archive/README.md's "the only thing that trips it is a write to the partition during the export". The
-- cursor is now (control, tableoid, ctid), which is unique across the heaps a read reaches.
--
-- The contract: a to_s3 export of a relation with more than one heap, with nothing writing to it, completes and
-- its object holds every row of the relation, once. Two shapes, both with a twin pair at ctid (0,1) and a page of
-- one row, so a page boundary falls between the twins: a list-partitioned table whose two leaves hold the twins
-- (and the first leaf one more row), and an inheritance parent holding one twin itself, its child the other
-- (and one more row). The fixtures are asymmetric (two rows in one heap, one in the other) so a skipped row and a
-- doubled one cannot cancel, and each object is stated by identity: its rows' (id, payload) pairs. Each object's
-- key is cleared and witnessed absent first, because the bucket outlives the test database.
--
-- The same contract holds for a relation whose control column holds NULL (pgpm's own partitions cannot, but a
-- relation the synchronous export accepts can). The keyset predicate compared a NULL control value as NULL, so
-- such a row was never paged and the export was refused as a write (part C, V-01 of the PR's verification), and
-- a page ending on such a row set the cursor to NULL, which reads as "no cursor": the next page started over and
-- the export never ended (part D, V-02). The NULL rows are now read after every other row, in a run of their
-- own paged by (tableoid, ctid). Part C pages one row at a time over two heaps with a NULL twin pair at (0,1);
-- part D reads a whole relation in one page. Every export runs under a statement_timeout, and t51.try_export
-- reports a cancel by name, so an export that never ends fails its assertion instead of hanging the file.
--
-- And the relation's column of the control column's name need not have the parent's type. The cursor crossed
-- to the next page as text cast back to the PARENT's type: under a date parent a timestamptz cursor of noon read
-- back as midnight, so each page re-admitted the row it ended on and the export never ended (part E, V-01 of
-- the second verification round); under a timestamp parent a timestamptz cursor lost its offset, so a session
-- east of UTC re-read rows forever (part F, P1-02). The cast now takes the exported relation's own type. A
-- relation with no column of that name is refused by name before anything is read (part G).
select plan(37);

create schema t51;
create table t51.evt (id bigint primary key, payload text not null);
insert into t51.evt values (1, 'evt');
call pgpm.transmute('t51.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-t51/' as p \gset
select archive.configure('t51.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);

-- A: a list-partitioned relation in the parent's schema, two leaves, the twins at (0,1) in each
create table t51.loose (id bigint, k int, payload text) partition by list (k);
create table t51.loose_a partition of t51.loose for values in (1);
create table t51.loose_b partition of t51.loose for values in (2);
insert into t51.loose values (1, 1, 'a'), (1, 2, 'b'), (2, 1, 'c');
-- B: an inheritance parent holding one twin in its own heap, its child the other twin and one more row
create table t51.inh (id bigint, payload text);
create table t51.inh_c () inherits (t51.inh);
insert into t51.inh values (1, 'p');
insert into t51.inh_c values (1, 'q'), (4, 'r');
-- C: two heaps, a NULL-control twin pair at (0,1), leaf a also holding 1:a and 3:c
create table t51.nul (id bigint, k int, payload text) partition by list (k);
create table t51.nul_a partition of t51.nul for values in (1);
create table t51.nul_b partition of t51.nul for values in (2);
insert into t51.nul values (null, 1, 'n'), (null, 2, 'm'), (1, 1, 'a'), (3, 1, 'c');
-- D: one heap, one NULL-control row, exported under a second parent whose page holds the whole relation
create table t51.evt2 (id bigint primary key, payload text not null);
insert into t51.evt2 values (1, 'evt');
call pgpm.transmute('t51.evt2', 'id', 10000::bigint, p_paused => true);
select archive.configure('t51.evt2', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1000);
create table t51.one (id bigint, payload text);
insert into t51.one values (1, 'a'), (null, 'n'), (2, 'b');
-- E: a date parent, and a relation whose dt is timestamptz, two rows at noon and one in the evening
create table t51.evt3 (id bigint, dt date not null, payload text not null, primary key (id, dt));
insert into t51.evt3 values (1, date '2024-01-01', 'evt');
call pgpm.transmute('t51.evt3', 'dt', interval '1 day', p_paused => true);
select archive.configure('t51.evt3', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table t51.dtz (dt timestamptz, payload text);
insert into t51.dtz values ('2024-01-01 12:00+00', 'a'), ('2024-01-02 12:00+00', 'b'), ('2024-01-01 18:00+00', 'c');
-- F: a timestamp parent, and a relation whose ts is timestamptz, three rows an hour apart
create table t51.evt4 (ts timestamp primary key, payload text not null);
insert into t51.evt4 values ('2024-01-01 00:00', 'evt');
call pgpm.transmute('t51.evt4', 'ts', interval '1 day', p_paused => true);
select archive.configure('t51.evt4', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table t51.tsz (ts timestamptz, payload text);
insert into t51.tsz values ('2024-01-01 10:00+00', 'x'), ('2024-01-01 11:00+00', 'y'), ('2024-01-01 12:00+00', 'z');
-- G: a relation with no column named id, the control column of t51.evt
create table t51.nocol (x int, payload text);
insert into t51.nocol values (1, 'q');

create function t51.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- DELETE the key and report the GET status after it: 404 means the export below starts from nothing.
create function t51.clear(p_key text) returns int language sql as $$
  select (t51.req('DELETE', p_key)).status * 0 + (t51.req('GET', p_key)).status $$;
-- the id:payload pairs an NDJSON object holds, one per line, sorted; null when there is no object at the key
create function t51.rows(p_key text) returns text[] language plpgsql as $$
declare v http_response := t51.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(coalesce(l::jsonb ->> 'id', 'NULL') || ':' || (l::jsonb ->> 'payload')
                   order by (l::jsonb ->> 'id')::bigint, l::jsonb ->> 'payload')
    into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
-- runs archive.to_s3 over the relation under p_parent and reports 'ok', the error it raised, or that the
-- statement_timeout cancelled it (which `when others` does not catch)
create function t51.try_export(p_child name, p_parent regclass default 't51.evt') returns text language plpgsql as $$
begin
  perform archive.to_s3(p_parent, p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;
-- the payloads an NDJSON object holds, one per line, sorted; null when there is no object at the key
create function t51.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := t51.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
-- the id:payload pairs a relation holds, sorted the way t51.rows sorts an object's
create function t51.held(p_rel regclass) returns text[] language plpgsql as $$
declare r text[];
begin
  execute format('select array_agg(coalesce(id::text, ''NULL'') || '':'' || payload order by id, payload) from %s', p_rel)
    into r;
  return r;
end $$;
set statement_timeout = '10s';

-- 1-2. The premises both shapes share: a page is one row, and the twins share a ctid in two heaps.
select is((select fetch_rows from archive.config where parent_table = 't51.evt'::regclass), 1,
  'LIVENESS: a page is one row, so a page boundary falls between the twins');
select is((select string_agg(tableoid::regclass::text || ':' || id || ':' || ctid::text, ','
                             order by tableoid::regclass::text, payload)
             from t51.loose where id = 1) || ' ' ||
          (select string_agg(tableoid::regclass::text || ':' || id || ':' || ctid::text, ','
                             order by tableoid::regclass::text, payload)
             from t51.inh where id = 1),
  't51.loose_a:1:(0,1),t51.loose_b:1:(0,1) t51.inh:1:(0,1),t51.inh_c:1:(0,1)',
  'LIVENESS: each relation holds two rows with id 1 at the same ctid (0,1), one in each of two heaps');

-- 3-7. A: the partitioned relation.
select :'p' || 't51.loose.ndjson' as ka \gset
select is(t51.clear(:'ka'), 404, 'LIVENESS: no object at the partitioned relation''s key before its export');
select is(t51.try_export('loose'), 'ok',
  'archive.to_s3 of a partitioned relation nothing writes to completes');
select is(t51.rows(:'ka'), array['1:a', '1:b', '2:c'],
  'its object holds rows 1:a (leaf a), 1:b (leaf b) and 2:c (leaf a), each once');
select is((select array_agg(id || ':' || payload order by id, payload) from t51.loose), array['1:a', '1:b', '2:c'],
  'LIVENESS: the partitioned relation still holds exactly those rows (nothing wrote to it)');
select is(t51.clear(:'ka'), 404, 'LIVENESS: the partitioned relation''s object is cleared after the check');

-- 8-12. B: the inheritance parent.
select :'p' || 't51.inh.ndjson' as kb \gset
select is(t51.clear(:'kb'), 404, 'LIVENESS: no object at the inheritance parent''s key before its export');
select is(t51.try_export('inh'), 'ok',
  'archive.to_s3 of an inheritance parent nothing writes to completes');
select is(t51.rows(:'kb'), array['1:p', '1:q', '4:r'],
  'its object holds rows 1:p (the parent''s own heap), 1:q and 4:r (the child''s), each once');
select is((select array_agg(id || ':' || payload order by id, payload) from t51.inh), array['1:p', '1:q', '4:r'],
  'LIVENESS: the inheritance parent still holds exactly those rows (nothing wrote to it)');
select is(t51.clear(:'kb'), 404, 'LIVENESS: the inheritance parent''s object is cleared after the check');

-- 13-18. C: NULL control values across two heaps, a page of one row.
select is((select string_agg(tableoid::regclass::text || ':' || ctid::text || ':' || payload, ',' order by payload desc)
             from t51.nul where id is null),
  't51.nul_a:(0,1):n,t51.nul_b:(0,1):m',
  'LIVENESS: the relation holds two rows whose control value is NULL, at the same ctid (0,1) in two heaps');
select :'p' || 't51.nul.ndjson' as kc \gset
select is(t51.clear(:'kc'), 404, 'LIVENESS: no object at the NULL-control relation''s key before its export');
select is(t51.try_export('nul'), 'ok',
  'archive.to_s3 of a relation holding NULL control values, nothing writing to it, completes');
select is(t51.rows(:'kc'), array['1:a', '3:c', 'NULL:m', 'NULL:n'],
  'its object holds rows 1:a and 3:c and both NULL-control rows NULL:m (leaf b) and NULL:n (leaf a), each once');
select is(t51.held('t51.nul'), array['1:a', '3:c', 'NULL:m', 'NULL:n'],
  'LIVENESS: the relation still holds exactly those rows (nothing wrote to it)');
select is(t51.clear(:'kc'), 404, 'LIVENESS: the NULL-control relation''s object is cleared after the check');

-- 19-24. D: one page holds the whole relation, a NULL-control row among its rows.
select is((select fetch_rows from archive.config where parent_table = 't51.evt2'::regclass), 1000,
  'LIVENESS: under t51.evt2 a page is 1000 rows, so the first page holds every row of t51.one, the NULL one last');
select :'p' || 't51.one.ndjson' as kd \gset
select is(t51.clear(:'kd'), 404, 'LIVENESS: no object at the one-page relation''s key before its export');
select is(t51.try_export('one', 't51.evt2'), 'ok',
  'archive.to_s3 of a one-page relation ending on a NULL control value ends, and completes');
select is(t51.rows(:'kd'), array['1:a', '2:b', 'NULL:n'],
  'its object holds rows 1:a, 2:b and NULL:n, each once');
select is(t51.held('t51.one'), array['1:a', '2:b', 'NULL:n'],
  'LIVENESS: the one-page relation still holds exactly those rows (nothing wrote to it)');
select is(t51.clear(:'kd'), 404, 'LIVENESS: the one-page relation''s object is cleared after the check');

-- 25-30. E: the relation's dt is timestamptz, the parent's is date.
set timezone = 'UTC';
select is((select format_type(a.atttypid, a.atttypmod) || '/' || format_type(b.atttypid, b.atttypmod)
             from pg_attribute a, pg_attribute b
            where a.attrelid = 't51.evt3'::regclass and a.attname = 'dt'
              and b.attrelid = 't51.dtz'::regclass and b.attname = 'dt'),
  'date/timestamp with time zone',
  'LIVENESS: the parent''s dt is date and the relation''s timestamptz, so a cursor of noon read as the parent''s type is midnight');
select is((select fetch_rows from archive.config where parent_table = 't51.evt3'::regclass), 1,
  'LIVENESS: under t51.evt3 a page is one row, so the first page ends on the noon row');
select :'p' || 't51.dtz.ndjson' as ke \gset
select is(t51.clear(:'ke'), 404, 'LIVENESS: no object at the timestamptz relation''s key before its export');
select is(t51.try_export('dtz', 't51.evt3'), 'ok',
  'archive.to_s3 of a timestamptz relation under a date parent ends, and completes');
select is(t51.payloads(:'ke'), array['a', 'b', 'c'], 'its object holds rows a, b and c, each once');
select is(t51.clear(:'ke'), 404, 'LIVENESS: the timestamptz relation''s object is cleared after the check');

-- 31-35. F: the relation's ts is timestamptz, the parent's is timestamp, the session east of UTC.
set timezone = 'Asia/Tokyo';
select is((select format_type(a.atttypid, a.atttypmod) || '/' || format_type(b.atttypid, b.atttypmod)
             from pg_attribute a, pg_attribute b
            where a.attrelid = 't51.evt4'::regclass and a.attname = 'ts'
              and b.attrelid = 't51.tsz'::regclass and b.attname = 'ts'),
  'timestamp without time zone/timestamp with time zone',
  'LIVENESS: the parent''s ts is timestamp and the relation''s timestamptz, and the session is nine hours east of UTC');
select :'p' || 't51.tsz.ndjson' as kf \gset
select is(t51.clear(:'kf'), 404, 'LIVENESS: no object at the second timestamptz relation''s key before its export');
select is(t51.try_export('tsz', 't51.evt4'), 'ok',
  'archive.to_s3 of a timestamptz relation under a timestamp parent, from Asia/Tokyo, ends, and completes');
select is(t51.payloads(:'kf'), array['x', 'y', 'z'], 'its object holds rows x, y and z, each once');
select is(t51.clear(:'kf'), 404, 'LIVENESS: the second timestamptz relation''s object is cleared after the check');
reset timezone;

-- 36-37. G: a relation with no column of the control column's name is refused by name, and nothing lands.
select :'p' || 't51.nocol.ndjson' as kg \gset
select is(t51.try_export('nocol'),
  'pg_partition_magician: t51.nocol has no column id, the control column of t51.evt that archive.to_s3 pages it by; refusing to export it',
  'archive.to_s3 refuses a relation with no column of the control column''s name, naming the column');
select is((t51.req('GET', :'kg')).status, 404, 'and no object lands at its key');
reset statement_timeout;

select * from finish();
