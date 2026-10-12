-- archive.configure's p_endpoint is the URL of an S3-compatible store, path prefix and all, and both signers
-- (archive.s3_signed_request and archive.s3_signed_request_bytea) address an object as the endpoint, '/', the
-- bucket, '/', the key. The endpoint used to be stored and used exactly as given, so one spelled with a
-- trailing slash ('http://host:9000/', as a URL is often written) addressed '//<bucket>/<key>': MinIO answers
-- HTTP 400 to that, so every export and every tick's chunk through it failed at the PUT after the read, and
-- configure, which refuses a p_part_bytes or p_fetch_rows that cannot work (#594, #636), took it without a word
-- (issue #1269). And an endpoint with no http:// or https:// scheme, or with a query string, was taken too,
-- though the signers cannot take a host out of it.
--
-- The contract: an endpoint's trailing slashes are not part of it. archive.configure stores the endpoint
-- without them, and the signers drop them from the endpoint they are handed, so a row stored with one (by an
-- install before this, or by hand) and a direct call spelled with one address the same object as the endpoint
-- spelled without. A path prefix is kept (Supabase Storage's endpoint is https://<ref>.supabase.co/storage/v1/s3).
-- configure refuses, naming p_endpoint and before it writes anything, an endpoint that is not an http:// or
-- https:// URL with a host, or that carries a query string or a fragment. A null endpoint is AWS S3, as before.
--
-- Each export's object is stated by identity (the rows it holds, two of them, by id and payload), its key
-- cleared and witnessed absent first, because the bucket outlives the test database; the prefix carries the
-- database's name so a parallel run of this file in another database cannot meet it.
select plan(25);

create schema t53;
create table t53.evt (id bigint primary key, payload text not null);
insert into t53.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('t53.evt', 'id', 10000::bigint, p_paused => true);
select 't53-' || current_database() || '/' as p \gset
select :'p' || 't53.evt.ndjson' as k \gset

-- The store, through the endpoint spelled the way every other test spells it.
create function t53.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function t53.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('t53.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
-- the object's rows, by identity: each NDJSON line's id and payload, in id order
create function t53.held(p_key text) returns text language sql as $$
  select string_agg((l::json ->> 'id') || ':' || (l::json ->> 'payload'), ',' order by (l::json ->> 'id')::bigint)
    from (select r.content from t53.req('GET', p_key) r where r.status = 200) g,
         regexp_split_to_table(rtrim(g.content, e'\n'), e'\n') l $$;
create function t53.stored() returns text language sql as $$
  select coalesce(endpoint, '<null>') from archive.config where parent_table = 't53.evt'::regclass $$;
create function t53.cfg(p_endpoint text) returns void language sql as $$
  select archive.configure('t53.evt', 'archive-test-bucket', p_endpoint => p_endpoint,
                           p_prefix => current_setting('t53.p')) $$;
select set_config('t53.p', :'p', false) as t53_p \gset

-- ---- A. the endpoint without a slash: the store, bucket and credentials are live ----------------------------
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object key is cleared before the first export');
select t53.cfg('http://minio:9000');
select is(t53.stored(), 'http://minio:9000', 'LIVENESS: an endpoint without a trailing slash is stored as given');
select is(t53.export(), 'ok', 'LIVENESS: an export through it reaches the store');
select is(t53.held(:'k'), '1:one,2:two', 'LIVENESS: and its object holds both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared again');
select is((t53.req('GET', :'k')).status, 404, 'LIVENESS: and is gone before the slashed endpoint is tried');

-- ---- B. the endpoint with a trailing slash is stored without it, and an export through it lands at the key ---
select t53.cfg('http://minio:9000/');
select is(t53.stored(), 'http://minio:9000', 'archive.configure stores an endpoint without its trailing slash');
select is(t53.export(), 'ok', 'an export through an endpoint configured with a trailing slash reaches the store');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');
select t53.cfg('http://minio:9000///');
select is(t53.stored(), 'http://minio:9000', 'every trailing slash is dropped, not just one');

-- ---- C. a path prefix is kept, only its trailing slash dropped -------------------------------------------------
select t53.cfg('http://minio:9000/storage/v1/s3/');
select is(t53.stored(), 'http://minio:9000/storage/v1/s3',
  'an endpoint with a path prefix is taken, the prefix kept and its trailing slash dropped');
select t53.cfg(null);
select is(t53.stored(), '<null>', 'a null endpoint (AWS S3) is still taken, as null');

-- ---- D. an endpoint the signers cannot use is refused by name, and the row is left as it was --------------------
select t53.cfg('http://minio:9000/');
select throws_like($$ select t53.cfg('minio:9000') $$, '%p_endpoint%',
  'an endpoint with no scheme is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('ftp://minio:9000') $$, '%p_endpoint%',
  'an endpoint with a scheme other than http or https is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000/?x=1') $$, '%p_endpoint%',
  'an endpoint with a query string is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000#f') $$, '%p_endpoint%',
  'an endpoint with a fragment is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http:///') $$, '%p_endpoint%',
  'an endpoint with no host is refused, naming p_endpoint');
select is(t53.stored(), 'http://minio:9000', 'a refused endpoint leaves the stored row as it was');

-- ---- E. a row stored with the slash (before this, or by hand) and a direct signer call spelled with it -----------
update archive.config set endpoint = 'http://minio:9000/' where parent_table = 't53.evt'::regclass;
select is(t53.stored(), 'http://minio:9000/', 'LIVENESS: the row holds an endpoint with a trailing slash');
select is(t53.export(), 'ok', 'an export through a row stored with a trailing slash reaches the store');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((archive.s3_signed_request('GET', 'http://minio:9000/', 'archive-test-bucket', 'us-east-1', :'k', '',
             'text/plain', '', 'minioadmin', 'minioadmin')).status, 200,
  'archive.s3_signed_request addresses the key through an endpoint spelled with a trailing slash');
select is((archive.s3_signed_request_bytea('GET', 'http://minio:9000/', 'archive-test-bucket', 'us-east-1', :'k', '',
             'text/plain', ''::bytea, 'minioadmin', 'minioadmin')).status, 200,
  'archive.s3_signed_request_bytea addresses the key through an endpoint spelled with a trailing slash');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared at the end');

select * from finish();
