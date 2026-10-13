-- A key is never reused by a different relation (README, docs/reference.md): a table that takes the name of a
-- dropped one gets its oid in the key, so it cannot write over the dropped table's objects, the only copy of the
-- rows retire() dropped. The claims (archive.object_key_owner / object_key_claim) compare keys as TEXT, and
-- archive.configure stores the prefix as typed. MinIO (the store this harness and the README name) reads a key
-- with a leading '/' as the same object as the key without it. So the new namesake, configured with the same
-- prefix spelled '/P/' instead of 'P/', claims the unclaimed base '/P/public.f5t', keeps the PLAIN key shape, and
-- its chunk PUT replaces the dropped table's object. Fixture asymmetric: the old chunk holds 9 'old' rows, the
-- new range 4 'new' rows; the object is asserted by its rows' identity.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create function req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function obj_rows(p_key text) returns text language plpgsql as $$
declare v http_response := req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;

select current_database() || '-f5k-' || md5(random()::text) as p \gset
select :'p' || '/public.f5t_0.ndjson' as k \gset

-- the first table: archives its chunk [0, 10) under prefix P/
create table public.f5t (id bigint primary key, payload text not null);
insert into public.f5t select g, 'old' from generate_series(1, 25) g;
call pgpm.transmute('public.f5t', 'id', 10::bigint, p_paused => true);
select archive.configure('public.f5t', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p' || '/');
select 'public.f5t'::regclass::oid as old_oid \gset
select is((req('DELETE', :'k')).status * 0 + (req('GET', :'k')).status, 404, 'LIVENESS: no object at the chunk key before the first archive');
select is((pgpm.archive_to_s3_ndjson('public.f5t', 'unused', '0', '10')).s3_key, :'k', 'LIVENESS: the first table''s chunk [0, 10) is archived at the plain key');
select is(obj_rows(:'k'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old', 'LIVENESS: the object holds the first table''s nine rows');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || '/public.f5t'), :'old_oid'::oid,
          'LIVENESS: the first table owns the key base, so a later namesake must get the oid shape');

-- the documented drop: the object is now the only copy of those rows
drop table public.f5t cascade;

-- a new table takes the name, configured with the same prefix spelled with a leading slash
create table public.f5t (id bigint primary key, payload text not null);
insert into public.f5t select g, 'new' from generate_series(1, 4) g;
insert into public.f5t select g, 'new' from generate_series(11, 25) g;
call pgpm.transmute('public.f5t', 'id', 10::bigint, p_paused => true);
select archive.configure('public.f5t', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => '/' || :'p' || '/');
select isnt('public.f5t'::regclass::oid, :'old_oid'::oid, 'LIVENESS: the namesake is another relation');
select is((req('GET', '/' || :'k')).status, 200, 'LIVENESS: the store reads the leading-slash spelling of the key as the existing object');

create function try_arch() returns text language plpgsql as $$
begin
  return (pgpm.archive_to_s3_ndjson('public.f5t', 'unused', '0', '10')).s3_key;
exception when others then return sqlerrm;
end $$;
select ok(try_arch() is not null, 'LIVENESS: the namesake''s archive call ran');
select is(obj_rows(:'k'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old',
          'the dropped table''s object still holds its nine rows after the namesake archived');
select is((req('DELETE', :'k')).status * 0 + (req('GET', :'k')).status, 404, 'GUARD: cleaned up');
select (req('DELETE', :'p' || '/public.f5t.' || 'public.f5t'::regclass::oid || '_0.ndjson')).status as cleanup_oid_shape \gset
select * from finish();
