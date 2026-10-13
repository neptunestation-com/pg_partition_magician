-- PR #1298 says archive._owned_key canonicalises the assembled key base (archive._canonical_key: no leading '/', no
-- empty segment) BEFORE it claims anything, so a namesake configured '/P/' reaches the claim the dropped table's
-- 'P/' base holds and takes the oid shape. In this tree archive._owned_key claims v_base_q as assembled from the
-- stored prefix and never calls archive._canonical_key, so MinIO (which reads '/P/x' and 'P/x' as one object) gets
-- the namesake's chunk PUT over the dropped table's object, the only copy of the rows retire() dropped (#1260).
-- Asymmetric fixture: the old chunk holds 9 'old' rows, the namesake's range holds 4 'new' rows; objects are
-- asserted by their rows' identity.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create schema p1a;
create function p1a.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function p1a.obj_rows(p_key text) returns text language plpgsql as $$
declare v http_response := p1a.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
create function p1a.arch(p_parent regclass, p_lo text, p_hi text) returns text language plpgsql as $$
begin
  return (pgpm.archive_to_s3_ndjson(p_parent, 'unused', p_lo, p_hi)).s3_key;
exception when others then return 'ERROR: ' || sqlerrm;
end $$;

select current_database() || '-p1a-' || md5(random()::text) || '/' as p \gset
select :'p' || 'p1a.t_0.ndjson' as k \gset

create table p1a.t (id bigint primary key, payload text not null);
insert into p1a.t select g, 'old' from generate_series(1, 25) g;
call pgpm.transmute('p1a.t', 'id', 10::bigint, p_paused => true);
select archive.configure('p1a.t', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 'p1a.t'::regclass::oid as old_oid \gset
select is((p1a.req('DELETE', :'k')).status * 0 + (p1a.req('GET', :'k')).status, 404, 'fixture: no object at the chunk key before the first archive');
select is(p1a.arch('p1a.t', '0', '10'), :'k', 'LIVENESS: the first p1a.t archives its chunk [0, 10) at the plain key');
select is(p1a.obj_rows(:'k'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old', 'LIVENESS: the object holds the first table''s nine rows');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 'p1a.t'), :'old_oid'::oid,
          'LIVENESS: the first p1a.t owns the key base, so a later namesake must get the oid shape');

-- the documented drop: the object is now the only copy of those rows
drop table p1a.t cascade;

-- a namesake, configured with the same prefix spelled with a leading '/'
create table p1a.t (id bigint primary key, payload text not null);
insert into p1a.t select g, 'new' from generate_series(1, 4) g;
insert into p1a.t select g, 'new' from generate_series(11, 25) g;
call pgpm.transmute('p1a.t', 'id', 10::bigint, p_paused => true);
select archive.configure('p1a.t', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => '/' || :'p');
select 'p1a.t'::regclass::oid as new_oid \gset
select is((p1a.req('GET', '/' || :'k')).status, 200, 'LIVENESS: the store reads the leading-slash spelling of the key as the existing object');

select is(p1a.arch('p1a.t', '0', '10'), :'p' || 'p1a.t.' || :'new_oid' || '_0.ndjson',
          'the namesake configured ''/<p>'' writes at the oid shape in the canonical spelling');
select is(p1a.obj_rows(:'k'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old',
          'the dropped table''s object still holds its nine rows after the namesake archived');
select is(p1a.obj_rows(:'p' || 'p1a.t.' || :'new_oid' || '_0.ndjson'), '1:new,2:new,3:new,4:new',
          'the namesake''s four rows are at its own oid-shaped key');

select p1a.req('DELETE', k) from unnest(array[:'k', :'p' || 'p1a.t.' || :'new_oid' || '_0.ndjson']) k;
select is((p1a.req('GET', :'k')).status, 404, 'GUARD: cleaned up');
select * from finish();
