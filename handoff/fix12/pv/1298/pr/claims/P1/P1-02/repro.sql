-- PR #1298 changed archive._refuse_recorded_chunk_overwrite to match a chunk's pgpm.archive_ledger row by
-- archive._canonical_key(a.s3_key) = p_key, on the premise that p_key is canonical because archive._owned_key
-- canonicalises it. In this tree archive._owned_key does not, so for a table configured with a prefix spelled with
-- a leading '/' the key it assembles AND the ledger row the tick recorded are both '/P/...', the canonical form
-- 'P/...' matches neither, and the #975/#1069 refusal that the base's `a.s3_key = p_key` gave is lost: a direct
-- call over the recorded chunk after retire() reads no row and PUTs an empty object over the only copy.
-- Asymmetric fixture: the chunk holds ids 1, 2, 3 and 7; the direct call's [0, 5) would leave three if it wrote
-- live rows and zero after retire(); the object is asserted by its rows' identity.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(8);

create schema p1b;
create function p1b.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function p1b.obj_rows(p_key text) returns text language plpgsql as $$
declare v http_response := p1b.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;
create function p1b.arch(p_parent regclass, p_lo text, p_hi text) returns text language plpgsql as $$
begin
  return (pgpm.archive_to_s3_ndjson(p_parent, 'unused', p_lo, p_hi)).s3_key;
exception when others then return 'ERROR: ' || sqlerrm;
end $$;

-- the prefix as an operator may type it: with a leading '/'
select '/' || current_database() || '-p1b-' || md5(random()::text) || '/' as p \gset
select :'p' || 'p1b.g_0.ndjson' as k \gset

create table p1b.g (id bigint primary key, payload text not null);
insert into p1b.g values (1, 'old'), (2, 'old'), (3, 'old'), (7, 'old');
call pgpm.transmute('p1b.g', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into p1b.g values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('p1b.g', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('p1b.g', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

select is((p1b.req('DELETE', :'k')).status * 0 + (p1b.req('GET', :'k')).status, 404, 'fixture: nothing at the chunk key before the work');
call pgpm.maintain('p1b.g');
select is((select string_agg(s3_key, ',') from pgpm.archive_ledger where parent_table = 'p1b.g'::regclass), :'k',
  'LIVENESS: the tick recorded the chunk [0, 10000) at the key as this module spelled it, with the leading slash');
select is(p1b.obj_rows(:'k') || '/' || coalesce((select string_agg(id::text, ',') from p1b.g where id < 10000), 'none'),
  '1:old,2:old,3:old,7:old/none',
  'LIVENESS: the chunk object holds rows 1, 2, 3 and 7, and retire() dropped them, so it is their only copy');
select is((select rows_digest is not null from archive.object_key_claim where object_key = :'k'), true,
  'LIVENESS: the chunk''s whole-key claim records the digest of its rows, so a re-run can be judged');

-- a direct call over the recorded chunk with a shorter range: #975 says this is refused
select p1b.arch('p1b.g', '0', '5') as outcome \gset
select alike(:'outcome'::text, '%refuses to write [0, 5)%pgpm.archive_ledger records the chunk [0, 10000)%',
  'the direct call over the recorded chunk is refused, naming the chunk');
select is(p1b.obj_rows(:'k'), '1:old,2:old,3:old,7:old', 'the chunk object still holds rows 1, 2, 3 and 7');

-- the same call with the chunk's own range after retire(): reads no row, must be refused too
select p1b.arch('p1b.g', '0', '10000') as outcome2 \gset
select alike(:'outcome2'::text, '%refuses to write [0, 10000)%', 'the re-run after retire() is refused (it reads no row)');
select is(p1b.obj_rows(:'k'), '1:old,2:old,3:old,7:old', 'and the chunk object is still the only copy of its four rows');

select p1b.req('DELETE', :'k');
select * from finish();
