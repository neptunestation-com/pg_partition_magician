-- The text SigV4 signer in a database whose server encoding is not UTF8 (issue #728).
--
-- archive.s3_signed_request hashed convert_to(p_payload, 'UTF8') into x-amz-content-sha256 and then put
-- p_payload itself on the wire, which is text in the SERVER encoding. In a UTF8 database those are the
-- same bytes. In a LATIN1 one, 'café' hashes as 63 61 66 c3 a9 and goes out as 63 61 66 e9, so the store
-- refused every body holding a non-ASCII character (400 XAmzContentSHA256Mismatch). The uncompressed
-- NDJSON strategy sends its chunk through this signer, so such a table logged skip_archive on every tick
-- and was never covered or retired, while archive.to_s3 and the Parquet strategy, both on the bytea
-- signer, archived the same partition. The signer now sends the bytes it hashed.
--
-- The archive track gives every file a UTF8 database, where the defect cannot show, so this file builds a
-- LATIN1 sibling through dblink, installs the module into it from the files under test, and drives the
-- strategy there, reading results back over the connection. pgpm_test.archive_install, when set on this
-- database, names the archive install to load instead of the tree's own: bench/archive_signer_non_utf8.sh
-- points it at a mutant.
--
-- Fixture: one chunk holding two rows with non-ASCII text and one without, so a strategy that dropped or
-- mangled only the non-ASCII rows cannot match the identity check on all three.
select plan(16);

create extension if not exists dblink;
create schema t29;

select current_database() || '_l1' as l1 \gset

select lives_ok(format($$ select dblink_exec('dbname=postgres', 'drop database if exists %I') $$, :'l1'),
  'LIVENESS: no LATIN1 sibling is left over from an earlier run');
select lives_ok(format($$ select dblink_exec('dbname=postgres',
  'create database %I encoding ''LATIN1'' lc_collate ''C'' lc_ctype ''C'' template template0') $$, :'l1'),
  'LIVENESS: a LATIN1 sibling database is created');
select dblink_connect('l1', 'dbname=' || :'l1');

-- what one statement in the sibling returns, as text
create function t29.one(p_sql text) returns text language sql as $$
  select x from dblink('l1', p_sql) as t(x text)
$$;

select is(t29.one('show server_encoding'), 'LATIN1', 'LIVENESS: the sibling''s server encoding is LATIN1');

select lives_ok($$ select dblink_exec('l1', 'create extension if not exists http; create extension if not exists pgcrypto') $$,
  'LIVENESS: pgsql-http and pgcrypto are installed in the sibling');
select lives_ok($$ select dblink_exec('l1', pg_read_file('/repo/tests/archive/fixtures.sql')) $$,
  'LIVENESS: the archive fixtures are installed in the sibling');
select lives_ok($$ select dblink_exec('l1', pg_read_file('/repo/pgpm_core/install.sql')) $$,
  'LIVENESS: pgpm_core is installed in the sibling');
select lives_ok($$ select dblink_exec('l1', pg_read_file(coalesce(nullif(current_setting('pgpm_test.archive_install', true), ''),
                                                                  '/repo/pgpm_archive/install.sql'))) $$,
  'LIVENESS: the archive module under test is installed in the sibling');

-- S3 from THIS (UTF8) database, where the text signer was always right: the instrument, not the subject
create function t29.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin')
$$;
-- an NDJSON object's rows as sorted id:payload text, or null when there is no object
create function t29.rows(p_key text) returns text language plpgsql as $$
declare r http_response := t29.req('GET', p_key);
begin
  if r.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::int)
            from regexp_split_to_table(r.content, e'\n') l where l <> '');
end $$;

-- [0, 10000) holds ids 1, 2 (non-ASCII) and 3 (ASCII); 45000 moves the frontier so [0, 10000) is aged
select dblink_exec('l1', $$
  create table public.lt (id bigint primary key, payload text);
  insert into public.lt values (1, 'caf' || chr(233)), (2, 'na' || chr(239) || 've'), (3, 'plain') $$);
select dblink_exec('l1', $$ call pgpm.transmute('public.lt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false) $$);
select dblink_exec('l1', format($$
  insert into public.lt values (45000, 'frontier');
  do $d$ begin
    perform archive.configure('public.lt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => %L);
    perform pgpm.set_archive_fn('public.lt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
  end $d$ $$, :'l1' || '/'));

select is(t29.one($$ select octet_length(payload) || '/' || octet_length(convert_to(payload, 'UTF8')) from public.lt where id = 1 $$), '4/5',
  'LIVENESS: row 1 is 4 bytes in the sibling''s encoding and 5 in UTF-8, so the two encodings differ on it');
select is(t29.one($$ select (archive_fn::regproc)::text || ' ' || (select compress::text from archive.config where parent_table = 'public.lt'::regclass)
                      from pgpm.config where parent_table = 'public.lt'::regclass $$),
  'pgpm.archive_to_s3_ndjson false',
  'LIVENESS: the table archives through the NDJSON strategy, uncompressed: the path that signs with the text signer');

-- the bucket outlives this database: clear both keys this file writes, and witness them absent
select is((select array_agg((t29.req('DELETE', k)).status * 0 + (t29.req('GET', k)).status order by k)
             from unnest(array[:'l1' || '/direct.txt', :'l1' || '/public.lt_0.ndjson']) k),
  array[404, 404], 'LIVENESS: no object at either key this file writes, before it writes them');

-- two ticks, the way pg_cron runs them
select t29.one('call pgpm.maintain(''public.lt'')');
select t29.one('call pgpm.maintain(''public.lt'')');

select is(t29.one($$ select (exists (select 1 from pgpm.archive_ledger where parent_table = 'public.lt'::regclass and lo = '0')
                          or exists (select 1 from pgpm.log where parent_table = 'public.lt'::regclass and action = 'skip_archive'))::text $$),
  'true', 'LIVENESS: the archive step ran the strategy on [0, 10000)');
select is(t29.one($$ select string_agg(distinct left(method, 160), ' | ') from pgpm.log
                      where parent_table = 'public.lt'::regclass and action = 'skip_archive' $$),
  null, 'no tick deferred the chunk');
select is(t29.one($$ select rows_archived || ' ' || s3_key from pgpm.archive_ledger where parent_table = 'public.lt'::regclass and lo = '0' $$),
  '3 ' || :'l1' || '/public.lt_0.ndjson',
  'the NDJSON strategy archived [0, 10000)''s three rows at its key');

-- the object, read back from THIS (UTF8) database: the store holds the rows' UTF-8 text, all three
select is(t29.rows(:'l1' || '/public.lt_0.ndjson'),
  '1:caf' || chr(233) || ',2:na' || chr(239) || 've,3:plain',
  'the object holds exactly rows 1, 2 and 3, their text intact');

-- the signer itself, which every caller shares, not only the strategy: a direct PUT from the sibling, read
-- back here
select is(t29.one(format($$ select (archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', %L, '',
                                    'text/plain', 'd' || chr(233) || 'j' || chr(224), 'minioadmin', 'minioadmin')).status::text $$,
                          :'l1' || '/direct.txt')),
  '200', 'archive.s3_signed_request from the sibling PUTs a non-ASCII body');
select is((t29.req('GET', :'l1' || '/direct.txt')).content::text, 'd' || chr(233) || 'j' || chr(224),
  'and the store holds that body as its UTF-8 bytes');

select dblink_disconnect('l1');
select dblink_exec('dbname=postgres', format('drop database if exists %I with (force)', :'l1'));
select * from finish();
