-- F12r-05: archive.to_s3 casts its paging cursor back as v_ctltype := v_ctl_typ::regtype::text, the BARE type name,
-- although it computes the column's typmod (v_ctl_mod, unused) and its own comment says the type "is spelled WITH
-- its typmod (format_type): ... for char(n) the bare `character` is char(1)". So a relation whose control-named
-- column is char(3), paged one row per page, has its cursor 'abc' cast back as 'a': every page re-admits the rows
-- it already read and the export of a quiescent relation never ends (or is refused as a write). It should export
-- each row once and complete. (scripts/check_archive_child_by_oid.py also fails on this line of the tree.)
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(5);

create schema f12r;
create table f12r.evt (id bigint primary key, payload text not null);
insert into f12r.evt values (1, 'evt');
call pgpm.transmute('f12r.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-f12r/' as p \gset
select archive.configure('f12r.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table f12r.chr (id char(3), payload text);
insert into f12r.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f12r.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f12r.clear(p_key text) returns int language sql as $$
  select (f12r.req('DELETE', p_key)).status * 0 + (f12r.req('GET', p_key)).status $$;
create function f12r.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f12r.evt', p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;
create function f12r.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := f12r.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;

select :'p' || 'f12r.chr.ndjson' as kh \gset
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f12r.chr'::regclass and attname = 'id')
          || '/' || ('abc'::character)::text,
  'character(3)/a',
  'LIVENESS: the relation''s id is character(3), and abc cast as the bare type name is cut to a');
select is((select fetch_rows from archive.config where parent_table = 'f12r.evt'::regclass), 1,
  'LIVENESS: one row per page, so the export pages through the cursor');
select is(f12r.clear(:'kh'), 404, 'LIVENESS: no object at the char(3) relation''s key before its export');
set statement_timeout = '15s';
select is(f12r.try_export('chr'), 'ok', 'archive.to_s3 of a quiescent char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(f12r.payloads(:'kh'), array['j', 'k', 'l'], 'its object holds rows j, k and l, each once');
select f12r.clear(:'kh');
select * from finish();
