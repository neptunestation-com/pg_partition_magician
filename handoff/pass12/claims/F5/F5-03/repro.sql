-- pgpm accepts a `date` control column, pgpm.set_archive_fn accepts pgpm.archive_to_s3_parquet for such a table
-- with no preflight, and archive._pq_to_parquet_range_counted's column-type switch has no `date` branch: every
-- chunk the strategy is handed raises "unsupported column type date", so on the automatic path every tick logs
-- skip_archive for the same chunk and nothing of the table is ever archived or retired. Driven here by the
-- strategy call pgpm._archive_step makes, over a chunk of the table's own partition. A twin table differing only
-- in being archived by the NDJSON strategy archives the same range (witness that the range and config are sound).
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(6);
create schema f5h;
select current_database() || '-f5h-' || md5(random()::text) || '/' as p \gset

create table f5h.dp (id bigint, dt date not null, payload text not null, primary key (id, dt));
create table f5h.dn (id bigint, dt date not null, payload text not null, primary key (id, dt));
insert into f5h.dp select g, date '2024-01-01' + (g % 10), 'p' || g from generate_series(1, 40) g;
insert into f5h.dn select g, date '2024-01-01' + (g % 10), 'n' || g from generate_series(1, 40) g;
call pgpm.transmute('f5h.dp', 'dt', interval '1 day', p_paused => true);
call pgpm.transmute('f5h.dn', 'dt', interval '1 day', p_paused => true);
select archive.configure('f5h.dp', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('f5h.dn', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

select lives_ok($$select pgpm.set_archive_fn('f5h.dp', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure)$$,
  'LIVENESS: set_archive_fn accepts the Parquet strategy for the date-controlled table');
select pgpm.set_archive_fn('f5h.dn', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f5h.dp'::regclass and attname = 'dt'),
  'date', 'LIVENESS: the control column is date, a control type pgpm.transmute accepted');

create function f5h.try(p_fmt text, p_parent text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  execute format('select * from pgpm.archive_to_s3_%s(%L, %L, %L, %L)', p_fmt, p_parent, 'unused',
                 '2024-01-01 00:00:00+00', '2024-01-06 00:00:00+00') into r;
  return 'rows=' || r.rows_archived;
exception when others then return sqlerrm;
end $$;
select is(f5h.try('ndjson', 'f5h.dn'), 'rows=20', 'LIVENESS: the NDJSON strategy archives the twin''s chunk [2024-01-01, 2024-01-06), 20 rows');
select is((select count(*)::int from f5h.dp where dt >= '2024-01-01' and dt < '2024-01-06'), 20,
  'LIVENESS: the Parquet table''s chunk holds 20 rows to archive');
select is(f5h.try('parquet', 'f5h.dp'), 'rows=20',
  'the Parquet strategy set_archive_fn accepted archives the date-controlled table''s chunk');

create function f5h.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
select is((f5h.req('DELETE', :'p' || 'f5h.dn_2024010100000000.ndjson')).status * 0
          + (f5h.req('DELETE', :'p' || 'f5h.dp_2024010100000000.parquet')).status * 0, 0, 'GUARD: objects deleted');
select * from finish();
