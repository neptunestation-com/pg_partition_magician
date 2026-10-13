-- archive.configure stores p_bucket verbatim and both signers build endpoint || '/' || bucket || '/' || key, so a
-- bucket spelled with a leading slash ('/my-bucket') addresses '//<bucket>/<key>', the #1269 consequence through
-- the other operand: MinIO answers HTTP 400 to every PUT, after the read. configure refuses nothing about the
-- bucket. Passes on a refusal naming p_bucket or a working export.
create extension if not exists pgtap;
select plan(6);

create schema v2b;
create table v2b.evt (id bigint primary key, payload text not null);
insert into v2b.evt values (1, 'one'), (2, 'two');
call pgpm.transmute('v2b.evt', 'id', 10000::bigint, p_paused => true);
select 'v2b-' || current_database() || '/' as p \gset
select :'p' || 'v2b.evt.ndjson' as k \gset

create function v2b.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function v2b.try(p_bucket text, p_endpoint text) returns text language plpgsql as $$
begin
  perform archive.configure('v2b.evt', p_bucket, p_endpoint => p_endpoint, p_prefix => current_setting('v2b.p'));
  return 'configured';
exception when others then return sqlerrm;
end $$;
create function v2b.export() returns text language plpgsql as $$
begin
  perform archive.to_s3('v2b.evt', 'evt', null, null);
  return 'ok';
exception when others then return sqlerrm;
end $$;
select set_config('v2b.p', :'p', false) as setp \gset
select (v2b.req('DELETE', :'k')).status as cleared \gset

-- the bucket and endpoint spelled the way every test spells them: store, bucket and credentials are live
select is(v2b.try('archive-test-bucket', 'http://minio:9000'), 'configured', 'LIVENESS: the plain bucket and endpoint are accepted');
select is(v2b.export(), 'ok', 'LIVENESS: an export through them reaches the store');
select is((v2b.req('GET', :'k')).status, 200, 'LIVENESS: and its object landed at the key');
select (v2b.req('DELETE', :'k')).status as cleared \gset

-- a bucket spelled with a leading slash: refused naming p_bucket, or an export through it reaches the key
select v2b.try('/archive-test-bucket', 'http://minio:9000') as cfg \gset
select v2b.export() as exp \gset
select (v2b.req('GET', :'k')).status as got \gset
select ok(:'cfg' = 'configured' or :'cfg' ilike '%p_bucket%',
  'GUARD: configure either takes the value or refuses it naming p_bucket (got: ' || :'cfg' || ')');
select ok(:'cfg' <> 'configured' or :'exp' = 'ok',
  'archive.to_s3 through a leading-slash bucket configure accepted does not fail at the store (got: ' || left(:'exp', 160) || ')');
select ok(:'cfg' <> 'configured' or :'got'::int = 200,
  'its object lands at the key, as it does through the plain spelling');
select (v2b.req('DELETE', :'k')).status as cleared \gset

select * from finish();
