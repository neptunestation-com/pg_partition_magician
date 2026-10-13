-- archive.to_s3 pages a relation whose control-named column is char(3), one row per page. The README and
-- docs/reference.md list char(n) and bit(n) among the types it pages, and the code's comment promises the
-- cursor's cast carries the typmod; it casts by v_ctl_typ::regtype::text, which for bpchar is `character`,
-- i.e. char(1). A cursor of 'abc' is read back as 'a', every page re-reads the same row, and the export
-- never ends (cancelled by statement_timeout). Fixture is asymmetric (three distinct ids), asserted by identity.
create extension if not exists pgtap;
\set ON_ERROR_STOP 1
select plan(6);
create schema f5a;
create table f5a.evt (id bigint primary key, payload text not null);
insert into f5a.evt values (1, 'evt');
call pgpm.transmute('f5a.evt', 'id', 10000::bigint, p_paused => true);
select current_database() || '-f5a-' || md5(random()::text) || '/' as p \gset
select archive.configure('f5a.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table f5a.chr (id char(3), payload text);
insert into f5a.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f5a.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f5a.clear(p_key text) returns int language sql as $$
  select (f5a.req('DELETE', p_key)).status * 0 + (f5a.req('GET', p_key)).status $$;
create function f5a.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := f5a.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
create function f5a.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f5a.evt', p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;

select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f5a.chr'::regclass and attname = 'id'),
  'character(3)', 'LIVENESS: the exported relation''s id column is character(3), a type the documentation says to_s3 pages');
select is((select count(*)::int from f5a.chr), 3, 'LIVENESS: three rows, so with fetch_rows 1 the export needs more than one page');
select :'p' || 'f5a.chr.ndjson' as kh \gset
select is(f5a.clear(:'kh'), 404, 'LIVENESS: no object at the char(3) relation''s key before its export');
set statement_timeout = '10s';
select is(f5a.try_export('chr'), 'ok', 'archive.to_s3 of a char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(f5a.payloads(:'kh'), array['j', 'k', 'l'], 'its object holds rows j, k and l, each once');
select is(f5a.clear(:'kh'), 404, 'GUARD: the object is cleared after the check');
select * from finish();
