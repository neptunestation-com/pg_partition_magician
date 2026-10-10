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
select plan(12);

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
  select array_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload')
                   order by (l::jsonb ->> 'id')::bigint, l::jsonb ->> 'payload')
    into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
-- runs archive.to_s3 over the relation and reports 'ok' or the error it raised
create function t51.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('t51.evt', p_child, null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;

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

select * from finish();
