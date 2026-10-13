-- archive.to_s3 of a relation whose control-named column is char(3) must end and export every row once.
-- The cursor's control value is cast back as `$1::<type>`; the type must carry its typmod (format_type), since
-- the bare `character` is char(1): a cursor of 'abc' cast back as 'a' re-admits every row from the top on
-- every page, so the export never ends. One row per page (p_fetch_rows => 1) so a page boundary falls on 'abc'.
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create extension if not exists http;
create extension if not exists pgcrypto;
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (name text primary key, decrypted_secret text not null);
insert into vault.decrypted_secrets values ('s3_archive_access_key_id', 'minioadmin'),
  ('s3_archive_secret_access_key', 'minioadmin') on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
select plan(5);

create schema f8c;
create table f8c.evt (id bigint primary key, payload text not null);
insert into f8c.evt values (1, 'evt');
call pgpm.transmute('f8c.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-f8c/' as p \gset
select archive.configure('f8c.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table f8c.chr (id char(3), payload text);
insert into f8c.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f8c.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f8c.clear(p_key text) returns int language sql as $$
  select (f8c.req('DELETE', p_key)).status * 0 + (f8c.req('GET', p_key)).status $$;
create function f8c.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f8c.evt', p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;
create function f8c.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := f8c.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;

select :'p' || 'f8c.chr.ndjson' as kh \gset
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f8c.chr'::regclass and attname = 'id'),
  'character(3)', 'LIVENESS: the exported relation''s control-named column is character(3)');
select is(('abc'::character)::text, 'a', 'LIVENESS: the bare type name `character` cuts a cursor of abc to a');
select is(f8c.clear(:'kh'), 404, 'LIVENESS: no object at the char(3) relation''s key before the export');
set statement_timeout = '20s';
select is(f8c.try_export('chr'), 'ok', 'archive.to_s3 of a char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(f8c.payloads(:'kh'), array['j', 'k', 'l'], 'its object holds rows j, k and l, each once');
select f8c.clear(:'kh');
select * from finish();
