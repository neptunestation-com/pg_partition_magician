-- archive.to_s3 casts its keyset cursor back as the exported relation's control column's BARE type name
-- (v_ctltype := v_ctl_typ::regtype::text), not format_type with the typmod the comment above it promises:
-- for char(3) that is `character`, which is char(1), so a cursor of 'abc' reads back as 'a', every later
-- page re-admits every row above 'a', and the export never ends (bit(3) the same way: `bit` is bit(1)).
create extension if not exists pgtap;
select plan(8);

create schema f19c;
create table f19c.evt (id bigint primary key, payload text not null);
insert into f19c.evt values (1, 'evt');
call pgpm.transmute('f19c.evt', 'id', 10000::bigint, p_paused => true);
select 'f19-01-' || current_database() || '/' as p \gset
select archive.configure('f19c.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
create table f19c.chr (id char(3), payload text);
insert into f19c.chr values ('abd', 'k'), ('abc', 'j'), ('abe', 'l');

create function f19c.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f19c.clear(p_key text) returns int language sql as $$
  select (f19c.req('DELETE', p_key)).status * 0 + (f19c.req('GET', p_key)).status $$;
create function f19c.payloads(p_key text) returns text[] language plpgsql as $$
declare v http_response := f19c.req('GET', p_key); r text[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg(l::jsonb ->> 'payload' order by l::jsonb ->> 'payload') into r
    from regexp_split_to_table(v.content, e'\n') as s(l) where l <> '';
  return r;
end $$;
create function f19c.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('f19c.evt', p_child, null, null);
  return 'ok';
exception
  when query_canceled then return 'cancelled by statement_timeout: the export did not end';
  when others then return sqlerrm;
end $$;

select :'p' || 'f19c.chr.ndjson' as k \gset

select is((select fetch_rows from archive.config where parent_table = 'f19c.evt'::regclass), 1,
  'LIVENESS: a page is one row, so the cursor crosses a page boundary twice');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'f19c.chr'::regclass and attname = 'id'),
  'character(3)', 'LIVENESS: the exported relation''s id is character(3)');
select is(('abc'::character)::text, 'a',
  'LIVENESS: a cursor of abc cast as the bare type name character is cut to a');
select is((select array_agg(payload order by payload) from f19c.chr), array['j', 'k', 'l'],
  'LIVENESS: the relation holds rows j, k and l');
select is(f19c.clear(:'k'), 404, 'LIVENESS: no object at the relation''s key before the export');

set statement_timeout = '15s';
select is(f19c.try_export('chr'), 'ok',
  'archive.to_s3 of a char(3) relation, one row per page, ends and completes');
reset statement_timeout;
select is(f19c.payloads(:'k'), array['j', 'k', 'l'],
  'its object holds rows j, k and l, each once');
select is(f19c.clear(:'k'), 404, 'fixture: the object is cleared after the check');

select * from finish();
