-- PR #1301 (round 2) says archive._s3_endpoint_canonical returns the endpoint without its trailing slashes, that
-- archive.configure stores the endpoint through it and that both signers pass the endpoint they are handed
-- through it, so 'http://minio:9000/' addresses the same object as 'http://minio:9000' (CHANGELOG, README,
-- the PR body, the helper's own comment). In this tree the helper's body is `select p_endpoint;`: the slash
-- is stored as given, both signers address '//<bucket>/<key>', MinIO answers HTTP 400 to every PUT, and the
-- issue's defect (#1269, F19-02) is exactly as it was. Fails here; passes on a tree whose helper drops the slashes.
create extension if not exists pgtap;
select plan(11);

create schema p101;
create table p101.evt (id bigint primary key, payload text not null);
insert into p101.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('p101.evt', 'id', 10000::bigint, p_paused => true);
select 'p101-' || current_database() || '/' as p \gset
select :'p' || 'p101.evt.ndjson' as k \gset
select set_config('p101.p', :'p', false) as p101_p \gset

create function p101.req(p_method text, p_endpoint text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, p_endpoint, 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function p101.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('p101.evt', 'evt', null, null);
  return 'ok';
exception when others then return left(sqlerrm, 160);
end $$;
-- the object's rows by identity (id:payload in id order), or null when there is no object
create function p101.held(p_key text) returns text language sql as $$
  select string_agg((l::json ->> 'id') || ':' || (l::json ->> 'payload'), ',' order by (l::json ->> 'id')::bigint)
    from (select r.content from p101.req('GET', 'http://minio:9000', p_key) r where r.status = 200) g,
         regexp_split_to_table(rtrim(g.content, e'\n'), e'\n') l $$;
create function p101.cfg(p_endpoint text) returns void language sql as $$
  select archive.configure('p101.evt', 'archive-test-bucket', p_endpoint => p_endpoint,
                           p_prefix => current_setting('p101.p')) $$;
create function p101.stored() returns text language sql as $$
  select coalesce(endpoint, '<null>') from archive.config where parent_table = 'p101.evt'::regclass $$;

-- the store, bucket and credentials are live through the endpoint spelled without a slash
select p101.req('DELETE', 'http://minio:9000', :'k') as cleared \gset
select is((p101.req('GET', 'http://minio:9000', :'k')).status, 404, 'LIVENESS: the key is absent before the first export');
select p101.cfg('http://minio:9000');
select is(p101.export(), 'ok', 'LIVENESS: an export through http://minio:9000 reaches the store');
select is(p101.held(:'k'), '1:one,2:two', 'LIVENESS: and its object holds rows 1 and 2');
select p101.req('DELETE', 'http://minio:9000', :'k') as cleared \gset
select is((p101.req('GET', 'http://minio:9000', :'k')).status, 404, 'LIVENESS: the key is absent again before the slashed endpoint is tried');

-- the endpoint spelled with a trailing slash: configure takes it (the fix normalises rather than refuses) ...
select p101.cfg('http://minio:9000/');
select is((select count(*) from archive.config where parent_table = 'p101.evt'::regclass)::int, 1,
  'LIVENESS: archive.configure took the endpoint spelled http://minio:9000/');
-- ... and the fix's contract: stored without the slash, and the export through it lands at the key
select is(p101.stored(), 'http://minio:9000', 'archive.configure stores http://minio:9000/ without its trailing slash');
select is(p101.export(), 'ok', 'an export through the endpoint configured as http://minio:9000/ reaches the store (not HTTP 400 at //bucket/key)');
select is(p101.held(:'k'), '1:one,2:two', 'and its object at the key holds rows 1 and 2');

-- a row stored with the slash (an install before the fix, or by hand) and a direct signer call spelled with it
update archive.config set endpoint = 'http://minio:9000/' where parent_table = 'p101.evt'::regclass;
select is(p101.stored(), 'http://minio:9000/', 'LIVENESS: the row now holds the endpoint with a trailing slash');
select is((p101.req('GET', 'http://minio:9000/', :'k')).status, 200,
  'archive.s3_signed_request spelled with a trailing slash addresses the key (the signer drops the slash)');
select is((archive.s3_signed_request_bytea('GET', 'http://minio:9000/', 'archive-test-bucket', 'us-east-1', :'k', '',
             'text/plain', ''::bytea, 'minioadmin', 'minioadmin')).status, 200,
  'archive.s3_signed_request_bytea spelled with a trailing slash addresses the key');
select p101.req('DELETE', 'http://minio:9000', :'k') as cleared \gset

select * from finish();
