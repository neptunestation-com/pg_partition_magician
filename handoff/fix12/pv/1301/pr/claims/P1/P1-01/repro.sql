-- PR #1301 (issue #1269) says archive._s3_endpoint_canonical returns the endpoint without its trailing slashes,
-- that archive.configure stores the endpoint through it, and that both signers pass the endpoint they are handed
-- through it, so 'http://minio:9000/' addresses the same object as 'http://minio:9000'. In this tree the helper
-- is `select p_endpoint` (the identity): configure stores the slash, the signers address '//<bucket>/<key>',
-- MinIO answers HTTP 400 to every PUT, and the README's "A trailing slash is dropped" is not kept.
-- Present: the defect checks below fail with every LIVENESS witness held. Absent: all pass.
create extension if not exists pgtap;
select plan(14);

create schema p1e;
create table p1e.evt (id bigint primary key, payload text not null);
insert into p1e.evt values (1, 'one'), (2, 'two');   -- two rows in, asserted by identity below
call pgpm.transmute('p1e.evt', 'id', 10000::bigint, p_paused => true);
select 'p1-01-' || current_database() || '/' as p \gset
select :'p' || 'p1e.evt.ndjson' as k \gset

create function p1e.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function p1e.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('p1e.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
create function p1e.held(p_key text) returns text language sql as $$
  select string_agg((l::json ->> 'id') || ':' || (l::json ->> 'payload'), ',' order by (l::json ->> 'id')::bigint)
    from (select r.content from p1e.req('GET', p_key) r where r.status = 200) g,
         regexp_split_to_table(rtrim(g.content, e'\n'), e'\n') l $$;
create function p1e.stored() returns text language sql as $$
  select coalesce(endpoint, '<null>') from archive.config where parent_table = 'p1e.evt'::regclass $$;
create function p1e.cfg(p_endpoint text) returns text language plpgsql as $$
begin
  perform archive.configure('p1e.evt', 'archive-test-bucket', p_endpoint => p_endpoint,
                            p_prefix => current_setting('p1e.p'));
  return 'configured';
exception when others then return sqlerrm;
end $$;
select set_config('p1e.p', :'p', false) as p1e_p \gset

-- the store, bucket and credentials are live through the endpoint spelled without a slash
select ok((p1e.req('DELETE', :'k')).status in (204, 404), 'LIVENESS: the object key is cleared first');
select is(p1e.cfg('http://minio:9000'), 'configured', 'LIVENESS: the endpoint without a slash is taken');
select is(p1e.stored(), 'http://minio:9000', 'LIVENESS: and stored as given');
select is(p1e.export(), 'ok', 'LIVENESS: an export through it reaches the store');
select is(p1e.held(:'k'), '1:one,2:two', 'LIVENESS: and its object holds rows 1 and 2');
select is((p1e.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared again');
select is((p1e.req('GET', :'k')).status, 404, 'LIVENESS: and is gone before the slashed endpoint is tried');

-- the slashed endpoint: configure takes it (the fix admits it), so the stored row and the export must work
select is(p1e.cfg('http://minio:9000/'), 'configured', 'LIVENESS: configure takes the endpoint spelled with a trailing slash');
select is(archive._s3_endpoint_canonical('http://minio:9000/'), 'http://minio:9000',
  'archive._s3_endpoint_canonical drops a trailing slash');
select is(p1e.stored(), 'http://minio:9000',
  'archive.configure stores the endpoint without its trailing slash (README: "A trailing slash is dropped")');
select is(p1e.export(), 'ok', 'an export through the endpoint configured with a trailing slash reaches the store (not HTTP 400 at //bucket/key)');
select is(p1e.held(:'k'), '1:one,2:two', 'and its object lands at the key holding rows 1 and 2');

-- a direct signer call spelled with the slash addresses the same key (object put there via the unslashed endpoint)
select p1e.cfg('http://minio:9000') as fixture_cfg \gset
select p1e.export() as fixture_exp \gset
select is((archive.s3_signed_request('GET', 'http://minio:9000/', 'archive-test-bucket', 'us-east-1', :'k', '',
             'text/plain', '', 'minioadmin', 'minioadmin')).status, 200,
  'archive.s3_signed_request spelled with a trailing slash addresses the key the unslashed export wrote');
select is((archive.s3_signed_request_bytea('GET', 'http://minio:9000/', 'archive-test-bucket', 'us-east-1', :'k', '',
             'text/plain', ''::bytea, 'minioadmin', 'minioadmin')).status, 200,
  'archive.s3_signed_request_bytea spelled with a trailing slash addresses the same key');
select (p1e.req('DELETE', :'k')).status as cleared \gset

select * from finish();
