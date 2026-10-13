-- archive.configure accepts an S3-compatible endpoint ending in '/', and the two signers then build the
-- path '//<bucket>/<key>' (the endpoint's trailing slash plus their own '/'), which the store refuses
-- (MinIO: HTTP 400 "An unsupported API call for method: PUT at '//bucket/key'"); every export and every
-- tick's chunk fails at the PUT.
-- (verifier's rebuild: a fix that refuses the slashed endpoint in configure also passes; the original
-- asserted configure accepts it as LIVENESS, so a refusing fix could never close it.)
-- configure refuses p_part_bytes and p_fetch_rows that cannot work where the value is chosen (#594, #636); an endpoint that cannot work should be refused or normalised there too.
create extension if not exists pgtap;
select plan(6);

create schema f19e;
create table f19e.evt (id bigint primary key, payload text not null);
insert into f19e.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('f19e.evt', 'id', 10000::bigint, p_paused => true);
select 'f19-02-' || current_database() || '/' as p \gset

create function f19e.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function f19e.try(p_endpoint text) returns text language plpgsql as $$
begin
  perform archive.configure('f19e.evt', 'archive-test-bucket', p_endpoint => p_endpoint, p_prefix => current_setting('f19e.p'));
  return 'configured';
exception when others then return sqlerrm;
end $$;
create function f19e.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('f19e.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
select set_config('f19e.p', :'p', false);

-- the same call with the endpoint spelled without the slash works end to end: the store, bucket and credentials are live
select is(f19e.try('http://minio:9000'), 'configured', 'LIVENESS: the endpoint without a trailing slash is accepted');
select is(f19e.export(), 'ok', 'LIVENESS: the export reaches the store through that endpoint');
select is((f19e.req('GET', :'p' || 'f19e.evt.ndjson')).status, 200, 'LIVENESS: and its object landed');
select (f19e.req('DELETE', :'p' || 'f19e.evt.ndjson')).status as cleared \gset

-- the endpoint with a trailing slash: either configure refuses it where it is chosen (naming p_endpoint),
-- or it takes it and an export through it reaches the key. Taking it and then failing every PUT is the defect.
select f19e.try('http://minio:9000/') as slash_cfg \gset
select f19e.export() as slash_exp \gset
select (f19e.req('GET', :'p' || 'f19e.evt.ndjson')).status as slash_get \gset
select ok(:'slash_cfg' = 'configured' or :'slash_cfg' ilike '%endpoint%',
  'GUARD: configure either takes the slashed endpoint or refuses it naming the endpoint (got: ' || :'slash_cfg' || ')');
select ok(:'slash_cfg' <> 'configured' or :'slash_exp' not like '%HTTP 400%',
  'archive.to_s3 through an endpoint configured with a trailing slash does not fail at the store with HTTP 400 (a //bucket/key path)');
select ok(:'slash_cfg' <> 'configured' or :'slash_get'::int = 200,
  'its object lands at the key, as it does through the endpoint spelled without the slash');
select (f19e.req('DELETE', :'p' || 'f19e.evt.ndjson')).status as cleared \gset

select * from finish();
