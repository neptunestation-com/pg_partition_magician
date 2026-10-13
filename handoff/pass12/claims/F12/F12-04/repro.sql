-- archive.to_s3 casts the paging cursor back as the exported relation's column type WITHOUT its typmod
-- (pgpm_archive/install.sql: v_ctltype := v_ctl_typ::regtype::text, v_ctl_mod read and never used). For a
-- char(3) column the bare type is `character`, i.e. char(1): a cursor of 'abc' comes back as 'a', every later
-- page re-reads the same row, and an export of a relation the docs list as pageable (char(n)) never ends.
-- docs/reference.md: "with nothing writing to the relation it reads every row once ... char(n), bit(n)".
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(5);

create schema f1204;
create table f1204.evt (id bigint primary key, payload text not null);
insert into f1204.evt values (1, 'evt');
call pgpm.transmute('f1204.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-f1204/' as p \gset
select archive.configure('f1204.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table f1204.chr (id char(3), payload text);
insert into f1204.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f1204.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f1204.clear(p_key text) returns int language sql as $$
  select (f1204.req('DELETE', p_key)).status * 0 + (f1204.req('GET', p_key)).status $$;
create function f1204.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := f1204.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
create function f1204.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f1204.evt'::regclass, p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;

select is((select fetch_rows from archive.config where parent_table = 'f1204.evt'::regclass), 1,
  'LIVENESS: a page is one row, so the cursor crosses a page boundary between every row');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f1204.chr'::regclass and attname = 'id'),
  'character(3)', 'LIVENESS: the exported relation''s id column is character(3)');
select :'p' || 'f1204.chr.ndjson' as kh \gset
select is(f1204.clear(:'kh'), 404, 'LIVENESS: no object at the relation''s key before its export');

set statement_timeout = '15s';
select is(f1204.try_export('chr'), 'ok', 'archive.to_s3 of a char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(f1204.payloads(:'kh'), array['j', 'k', 'l'], 'its object holds rows j, k and l, each once');
select f1204.clear(:'kh');
select * from finish();
