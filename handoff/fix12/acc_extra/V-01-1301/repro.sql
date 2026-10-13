-- archive.configure's new endpoint refusal (#1269, PR #1301) admits an endpoint with userinfo
-- ('http://user@host:port'): its regex reads 'user@host:port' as the host, the signers sign Host: user@host:port,
-- the client sends Host: host:port, and the store answers 403 SignatureDoesNotMatch to every PUT, after the read.
-- The PR body says configure refuses an endpoint the signers cannot use. Passes on a refusal naming p_endpoint
-- or a working export.
create extension if not exists pgtap;
select plan(6);

create schema v1e;
create table v1e.evt (id bigint primary key, payload text not null);
insert into v1e.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('v1e.evt', 'id', 10000::bigint, p_paused => true);
select 'v1e-' || current_database() || '/' as p \gset
select :'p' || 'v1e.evt.ndjson' as k \gset

create function v1e.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function v1e.try(p_bucket text, p_endpoint text) returns text language plpgsql as $$
begin
  perform archive.configure('v1e.evt', p_bucket, p_endpoint => p_endpoint, p_prefix => current_setting('v1e.p'));
  return 'configured';
exception when others then return sqlerrm;
end $$;
create function v1e.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('v1e.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
select set_config('v1e.p', :'p', false) as setp \gset
select (v1e.req('DELETE', :'k')).status as cleared \gset

-- the bucket and endpoint spelled the way every test spells them: store, bucket and credentials are live
select is(v1e.try('archive-test-bucket', 'http://minio:9000'), 'configured', 'LIVENESS: the plain bucket and endpoint are accepted');
select is(v1e.export(), 'ok', 'LIVENESS: an export through them reaches the store');
select is((v1e.req('GET', :'k')).status, 200, 'LIVENESS: and its object landed at the key');
select (v1e.req('DELETE', :'k')).status as cleared \gset

-- an endpoint carrying userinfo: refused naming p_endpoint, or an export through it reaches the key
select v1e.try('archive-test-bucket', 'http://minioadmin@minio:9000') as cfg \gset
select v1e.export() as exp \gset
select (v1e.req('GET', :'k')).status as got \gset
select ok(:'cfg' = 'configured' or :'cfg' ilike '%p_endpoint%',
  'GUARD: configure either takes the value or refuses it naming p_endpoint (got: ' || :'cfg' || ')');
select ok(:'cfg' <> 'configured' or :'exp' = 'ok',
  'archive.to_s3 through a userinfo endpoint configure accepted does not fail at the store (got: ' || left(:'exp', 160) || ')');
select ok(:'cfg' <> 'configured' or :'got'::int = 200,
  'its object lands at the key, as it does through the plain spelling');
select (v1e.req('DELETE', :'k')).status as cleared \gset

select * from finish();
