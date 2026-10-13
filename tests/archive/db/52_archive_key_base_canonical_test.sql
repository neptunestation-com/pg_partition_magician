-- One object, one claim, whatever the spelling of the prefix (issue #1260; reproduction F5-02 of review pass 12).
--
-- archive._owned_key claims a key base (archive.object_key_owner) and a whole key (archive.object_key_claim) as
-- TEXT, and used to take the prefix exactly as archive.configure stored it. MinIO, the store this harness and
-- pgpm_archive/README.md name, reads a key with a leading '/' (or several) as the same object as the key without
-- it. So a table that took a dropped table's name, configured with the same prefix spelled with a leading '/',
-- claimed the unclaimed base '/<p>t52.f', kept the PLAIN key shape, and its chunk PUT replaced the dropped table's
-- object, the only copy of the rows retire() dropped. The contract: every key is assembled, claimed and written in
-- one canonical spelling (no leading '/', no empty segment), so two spellings of one object are one claim, and a
-- key with a '.' or '..' segment, which no store can be addressed with (the HTTP client resolves it before sending,
-- and the signature then no longer matches), is refused up front, naming it.
--
--   Part A  the issue: a namesake configured '/<p>' takes the oid shape and leaves the dropped table's object as
--           it was; a third namesake configured with every '/' doubled does the same
--   Part B  an older install's state: claims and a ledger row spelled '/<p>...' (what a pre-fix module configured
--           '/<p>' recorded) are claimed again in the canonical spelling by install
--           (archive._claim_canonical_spellings), so the table's own direct call over its recorded chunk is still
--           refused (#975) and a later namesake still takes the oid shape
--   Part C  a '.' or '..' segment: archive.configure refuses it, archive._owned_key refuses one already stored,
--           and the remedy each message names, typed here, archives the chunk
--
-- Fixtures are asymmetric so a replaced object cannot pass an identity check: the first f holds 9 'old' rows in
-- [0, 10) and each namesake fewer 'new' ones; g's chunk holds ids 1, 2, 3 and 7, so a write of [0, 5) over it
-- would leave three. The prefix carries current_database() because the bucket outlives a test database, and every
-- key is cleared and witnessed absent before the work that writes it.
set client_min_messages = warning;
select plan(26);

create schema t52;

create function t52.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t52.clear(p_key text) returns int language plpgsql as $$
begin
  perform t52.req('DELETE', p_key);
  return (t52.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t52.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t52.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return coalesce((select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
                     from regexp_split_to_table(v.content, e'\n') l where l <> ''), '');
end $$;

-- The key a direct NDJSON call writes, or its error: PL/pgSQL, so an assertion compares the outcome either way.
create function t52.arch(p_parent regclass, p_lo text, p_hi text) returns text language plpgsql as $$
begin
  return (pgpm.archive_to_s3_ndjson(p_parent, 'unused', p_lo, p_hi)).s3_key;
exception when others then return 'ERROR: ' || sqlerrm;
end $$;

select current_database() || '/t52/' as p \gset

-- ======================= PART A: the namesake's prefix spelled with a leading '/' (F5-02) =======================
create table t52.f (id bigint primary key, payload text not null);
insert into t52.f select g, 'old' from generate_series(1, 25) g;
call pgpm.transmute('t52.f', 'id', 10::bigint, p_paused => true);
select archive.configure('t52.f', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't52.f'::regclass::oid as f1_oid \gset

select is(t52.clear(:'p' || 't52.f_0.ndjson'), 404, 'fixture: (A) nothing at <p>t52.f_0.ndjson before the work');
select is(t52.arch('t52.f', '0', '10'), :'p' || 't52.f_0.ndjson',
  'LIVENESS: (A) the first t52.f archives its chunk [0, 10) at the plain key <p>t52.f_0.ndjson');
select is(t52.rows(:'p' || 't52.f_0.ndjson'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old',
  'LIVENESS: (A) the object holds the first t52.f''s nine rows');

-- the documented drop: the object is now the only copy of those rows
drop table t52.f cascade;

create table t52.f (id bigint primary key, payload text not null);
insert into t52.f select g, 'new' from generate_series(1, 4) g;
insert into t52.f select g, 'new' from generate_series(11, 25) g;
call pgpm.transmute('t52.f', 'id', 10::bigint, p_paused => true);
select archive.configure('t52.f', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => '/' || :'p');
select 't52.f'::regclass::oid as f2_oid \gset
select is((t52.req('GET', '/' || :'p' || 't52.f_0.ndjson')).status, 200,
  'LIVENESS: (A) the store reads /<p>t52.f_0.ndjson, the leading-slash spelling, as the existing object');
select is(t52.clear(:'p' || 't52.f.' || :'f2_oid' || '_0.ndjson'), 404,
  'fixture: (A) nothing at the second t52.f''s oid-shaped key before the work');

select is(t52.arch('t52.f', '0', '10'), :'p' || 't52.f.' || :'f2_oid' || '_0.ndjson',
  'A: the namesake configured ''/<p>'' writes at the oid shape, <p>t52.f.<oid>_0.ndjson, spelled without the slash');
select is(t52.rows(:'p' || 't52.f_0.ndjson'), '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old',
  'A: the dropped table''s object still holds its nine rows');
select is(t52.rows(:'p' || 't52.f.' || :'f2_oid' || '_0.ndjson'), '1:new,2:new,3:new,4:new',
  'A: and the namesake''s four rows are at its own key');

-- a third t52.f, its prefix with a leading '//' and every '/' doubled
drop table t52.f cascade;
create table t52.f (id bigint primary key, payload text not null);
insert into t52.f select g, 'third' from generate_series(5, 6) g;
insert into t52.f select g, 'third' from generate_series(11, 25) g;
call pgpm.transmute('t52.f', 'id', 10::bigint, p_paused => true);
select archive.configure('t52.f', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                         p_prefix => '//' || replace(:'p', '/', '//'));
select 't52.f'::regclass::oid as f3_oid \gset
select is(t52.clear(:'p' || 't52.f.' || :'f3_oid' || '_0.ndjson'), 404,
  'fixture: (A) nothing at the third t52.f''s oid-shaped key before the work');
select is(t52.arch('t52.f', '0', '10'), :'p' || 't52.f.' || :'f3_oid' || '_0.ndjson',
  'A: a namesake whose prefix has every ''/'' doubled writes at its oid shape in the canonical spelling');
select is(t52.rows(:'p' || 't52.f_0.ndjson') || '/' || t52.rows(:'p' || 't52.f.' || :'f3_oid' || '_0.ndjson'),
  '1:old,2:old,3:old,4:old,5:old,6:old,7:old,8:old,9:old/5:third,6:third',
  'A: the first t52.f''s object is still its nine rows, and the third''s two rows are at its own key');

-- ======================= PART B: an older install's claims and ledger row, spelled '/<p>' =======================
create table t52.g (id bigint primary key, payload text not null);
insert into t52.g values (1, 'old'), (2, 'old'), (3, 'old'), (7, 'old');
call pgpm.transmute('t52.g', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t52.g values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('t52.g', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t52.g', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't52.g'::regclass::oid as g1_oid \gset

select is(t52.clear(:'p' || 't52.g_0.ndjson'), 404, 'fixture: (B) nothing at <p>t52.g_0.ndjson before the work');
call pgpm.maintain('t52.g');
select is(t52.rows(:'p' || 't52.g_0.ndjson') || '/' || coalesce((select string_agg(id::text, ',') from t52.g where id < 10000), 'none'),
  '1:old,2:old,3:old,7:old/none',
  'LIVENESS: (B) the chunk object holds rows 1, 2, 3 and 7, and retire() dropped them, so it is their only copy');

-- What a module before this fix, configured '/<p>', recorded: every claim and the ledger row in that spelling, and
-- nothing in the canonical one (the store wrote one object either way).
update pgpm.archive_ledger set s3_key = '/' || s3_key where parent_table = 't52.g'::regclass;
update archive.object_key_owner set key_base = '/' || key_base where key_base = :'p' || 't52.g';
update archive.object_key_claim set object_key = '/' || object_key where object_key = :'p' || 't52.g_0.ndjson';
select is((select string_agg(s3_key, ',') from pgpm.archive_ledger where parent_table = 't52.g'::regclass)
          || '/' || (select count(*) from archive.object_key_claim where object_key = :'p' || 't52.g_0.ndjson'),
  '/' || :'p' || 't52.g_0.ndjson/0',
  'LIVENESS: (B) the ledger records the chunk at /<p>t52.g_0.ndjson, and no claim is spelled <p>t52.g_0.ndjson');

select lives_ok($$ select archive._claim_canonical_spellings() $$, 'B: install''s canonical-spelling claim step runs');
select is((select parent_oid::text || '/' || kind || '/' || (rows_digest is not null)::text
             from archive.object_key_claim where object_key = :'p' || 't52.g_0.ndjson'),
  :'g1_oid' || '/chunk/true',
  'B: the chunk''s key is claimed in the canonical spelling, as t52.g''s chunk with the digest it recorded');

select throws_like($$ select pgpm.archive_to_s3_ndjson('t52.g', 'unused', '0', '5') $$,
  '%refuses to write [0, 5)%pgpm.archive_ledger records the chunk [0, 10000)%',
  'B: t52.g''s direct call over its recorded chunk is still refused, the ledger row spelled /<p>');
select is(t52.rows(:'p' || 't52.g_0.ndjson'), '1:old,2:old,3:old,7:old',
  'B: and the chunk object still holds rows 1, 2, 3 and 7');

drop table t52.g cascade;
create table t52.g (id bigint primary key, payload text not null);
insert into t52.g values (1, 'new'), (2, 'new');
call pgpm.transmute('t52.g', 'id', 10000::bigint, p_paused => true);
select archive.configure('t52.g', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't52.g'::regclass::oid as g2_oid \gset
select is(t52.arch('t52.g', '0', '10000'), :'p' || 't52.g.' || :'g2_oid' || '_0.ndjson',
  'B: a namesake configured <p> takes the oid shape, the base claimed under the older spelling');
select is(t52.rows(:'p' || 't52.g_0.ndjson') || '/' || t52.rows(:'p' || 't52.g.' || :'g2_oid' || '_0.ndjson'),
  '1:old,2:old,3:old,7:old/1:new,2:new',
  'B: the dropped t52.g''s object is as it was, and the namesake''s two rows are at its own key');

-- ======================= PART C: a '.' or '..' segment =======================
create table t52.h (id bigint primary key, payload text not null);
insert into t52.h values (1, 'h'), (2, 'h'), (11, 'h');
call pgpm.transmute('t52.h', 'id', 10::bigint, p_paused => true);
select throws_like(format($$ select archive.configure('t52.h', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => %L) $$, :'p' || 'x/../'),
  '%p_prefix ' || :'p' || 'x/../ has a "." or ".." segment%',
  'C: archive.configure refuses a prefix with a ".." segment, naming it');
select is((select count(*)::int from archive.config where parent_table = 't52.h'::regclass), 0,
  'C: and stores nothing');
select lives_ok(format($$ select archive.configure('t52.h', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => %L) $$, :'p' || 'x/'),
  'C: the remedy the message names, the prefix without the segment, is accepted');

-- a row an older module stored (or a hand UPDATE): archive._owned_key refuses it, naming it
update archive.config set prefix = :'p' || './' where parent_table = 't52.h'::regclass;
select is(t52.clear(:'p' || 't52.h_0.ndjson'), 404, 'fixture: (C) nothing at <p>t52.h_0.ndjson before the work');
select is(t52.arch('t52.h', '0', '10'),
  'ERROR: pg_partition_magician: the object key base ' || :'p' || './t52.h has a "." or ".." segment (archive.config.prefix is ' || :'p' || './); no store can be addressed with one, so nothing is written there. Spell the prefix without it: archive.configure(t52.h, ..., p_prefix => <the prefix without "." and ".." segments>)',
  'C: a stored prefix with a "." segment is refused at the key, naming the base and the prefix');
select archive.configure('t52.h', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select is(t52.arch('t52.h', '0', '10') || '/' || t52.rows(:'p' || 't52.h_0.ndjson'), :'p' || 't52.h_0.ndjson/1:h,2:h',
  'C: the remedy the refusal names, archive.configure with the prefix spelled without it, archives the chunk');

-- the bucket outlives this database: leave nothing behind
select t52.req('DELETE', k) from unnest(array[
  :'p' || 't52.f_0.ndjson', :'p' || 't52.f.' || :'f2_oid' || '_0.ndjson', :'p' || 't52.f.' || :'f3_oid' || '_0.ndjson',
  :'p' || 't52.g_0.ndjson', :'p' || 't52.g.' || :'g2_oid' || '_0.ndjson', :'p' || 't52.h_0.ndjson']) k;

select * from finish();
