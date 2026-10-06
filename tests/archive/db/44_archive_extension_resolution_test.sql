-- pgpm_archive resolves the objects of the two extensions it depends on, pgcrypto's hmac() and digest() and
-- the http extension's http(), http_set_curlopt(), bytea_to_text() and its types, through the extensions'
-- own schemas, never through the CALLER's search_path (issue #984).
--
-- The SigV4 signers used to call all of them unqualified, in functions that pinned no search_path, so they
-- resolved through whatever path the calling session (a maintain() tick, a pg_cron job, an operator) had:
--
--   A. A function hmac(bytea, bytea, text) in any schema ahead of pgcrypto's on that path received
--      'AWS4' || <the S3 secret key> as its key argument and ran with the caller's privileges (F11-01). The
--      shadows below are owned by a NON-superuser role, the caller is the superuser running this file, and
--      each shadow records what it was handed and who it ran as before delegating to the real function, so
--      the defect leaves a valid signature behind it and shows up only in what the shadows saw. The path
--      names pg_catalog explicitly AFTER the shadows' schema, which puts even convert_to(), the builtin the
--      secret is first handed to, behind a shadow: the signers pin their own search_path to pg_catalog, so
--      none of these can be reached from inside them.
--   B. Every S3 function named the http extension's types (http_response, http_header) in its declarations,
--      so a tick under an application search_path that does not name the extensions' schema (`set
--      search_path = app`, the per-schema caller #551 describes) failed every archive call with `type
--      "http_response" does not exist`, logged skip_archive on every tick and never archived (F5-06). Both
--      archive_fn strategies, both synchronous exports and the multipart abort sweep are driven from that
--      path here, and the objects they wrote are read back by identity under the default one.
--
-- Fixtures are asymmetric: each managed table has two partitions due for archiving and one that is not, so
-- a tick that archived everything, or only one, reads differently from one that archived exactly what was
-- due. Object keys carry a per-run prefix, so an object read back was written by this run.
set client_min_messages = warning;
select plan(15);

select extnamespace::regnamespace::text as crypto_nsp from pg_extension where extname = 'pgcrypto' \gset
select extnamespace::regnamespace::text as http_nsp from pg_extension where extname = 'http' \gset
select 't44-' || current_database() || '-' || md5(clock_timestamp()::text) as run \gset

-- --- A. shadows ahead of the extensions, owned by another role -----------------------------------

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't44_low') then create role t44_low nosuperuser; end if;
end $$;
create schema t44_shadow authorization t44_low;
create table t44_shadow.seen (n int generated always as identity, fn text, arg text, ran_as text);
alter table t44_shadow.seen owner to t44_low;
grant insert on t44_shadow.seen to public;

set role t44_low;
-- each shadow records (its name, the argument a secret would travel in, the role it runs as), then
-- delegates to the object it shadows, so the signer still produces a valid request either way
select format($f$create function t44_shadow.hmac(bytea, bytea, text) returns bytea language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('hmac', encode($2, 'hex'), current_user::text);
      return %1$I.hmac($1, $2, $3); end $b$$f$, :'crypto_nsp') \gexec
select format($f$create function t44_shadow.digest(bytea, text) returns bytea language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('digest', encode($1, 'hex'), current_user::text);
      return %1$I.digest($1, $2); end $b$$f$, :'crypto_nsp') \gexec
select format($f$create function t44_shadow.http(%1$I.http_request) returns %1$I.http_response language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('http', ($1).uri, current_user::text);
      return %1$I.http($1); end $b$$f$, :'http_nsp') \gexec
select format($f$create function t44_shadow.http_set_curlopt(varchar, varchar) returns boolean language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('http_set_curlopt', $1, current_user::text);
      return %1$I.http_set_curlopt($1, $2); end $b$$f$, :'http_nsp') \gexec
select format($f$create function t44_shadow.bytea_to_text(bytea) returns text language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('bytea_to_text', encode($1, 'hex'), current_user::text);
      return %1$I.bytea_to_text($1); end $b$$f$, :'http_nsp') \gexec
create function t44_shadow.convert_to(text, name) returns bytea language plpgsql as $b$
begin insert into t44_shadow.seen (fn, arg, ran_as) values ('convert_to', $1, current_user::text);
      return pg_catalog.convert_to($1, $2); end $b$;
reset role;

select is(
  (select array_agg(p.proname::text || ':' || pg_get_userbyid(p.proowner) order by p.proname)
     from pg_proc p where p.pronamespace = 't44_shadow'::regnamespace),
  array['bytea_to_text:t44_low', 'convert_to:t44_low', 'digest:t44_low', 'hmac:t44_low', 'http:t44_low',
        'http_set_curlopt:t44_low'],
  'LIVENESS: six shadows, every one owned by the non-superuser t44_low');

-- the victim session: the shadows' schema first, pg_catalog explicitly behind it, the extensions after
select set_config('search_path', 't44_shadow, pg_catalog, ' || :'crypto_nsp' || ', ' || :'http_nsp', false);
create temp table resolved as
  select array[to_regprocedure('hmac(bytea,bytea,text)')::oid, to_regprocedure('digest(bytea,text)')::oid,
               to_regprocedure('convert_to(text,name)')::oid, to_regprocedure('bytea_to_text(bytea)')::oid,
               to_regprocedure('http_set_curlopt(varchar,varchar)')::oid,
               to_regprocedure('http(' || :'http_nsp' || '.http_request)')::oid] as oids;
create temp table sent as
  select (archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
            :'run' || '/a.txt', '', 'text/plain', 'alpha', 'minioadmin', 'minioadmin')).status as text_status,
         (archive.s3_signed_request_bytea('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
            :'run' || '/b.bin', '', 'application/octet-stream', '\x627261766f'::bytea, 'minioadmin', 'minioadmin')).status as bytea_status;
reset search_path;

select is(
  (select array_agg(p.pronamespace::regnamespace::text order by o.i) from resolved r, unnest(r.oids) with ordinality o(oid, i)
     join pg_proc p on p.oid = o.oid),
  array_fill('t44_shadow'::text, array[6]),
  'LIVENESS: under the victim''s search_path every unqualified hmac, digest, convert_to, bytea_to_text, http_set_curlopt and http resolves to a shadow');

select is((select (text_status, bytea_status)::text from sent), '(200,200)',
  'LIVENESS: both signers, called under that search_path, signed requests MinIO accepted');

select is(
  (select array[(archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
                   :'run' || '/a.txt', '', 'text/plain', '', 'minioadmin', 'minioadmin')).content::text,
                (archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
                   :'run' || '/b.bin', '', 'text/plain', '', 'minioadmin', 'minioadmin')).content::text]),
  array['alpha', 'bravo'],
  'LIVENESS: and the objects they PUT hold exactly the payloads they were given');

select is(
  (select count(*)::int from t44_shadow.seen
    where arg in (encode(pg_catalog.convert_to('AWS4minioadmin', 'UTF8'), 'hex'), 'AWS4minioadmin')),
  0, 'neither signer handed ''AWS4'' || the S3 secret key to a function the caller''s search_path put ahead of the real one');

select is((select array_agg(distinct fn || ' as ' || ran_as) from t44_shadow.seen), null::text[],
  'and no function owned by another role ran inside either signer as the caller');

drop schema t44_shadow cascade;
drop role t44_low;

-- --- B. a tick, and the synchronous exports, under an application search_path ---------------------

create schema app;
create schema t44;

-- a statement's error message, or 'ok'
create function t44.try(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm; end $$;

-- an object's bytes, fetched under the default search_path (see tests/archive/db/13 for text_to_bytea)
create function t44.fetch(p_parent regclass, p_key text) returns bytea language plpgsql as $$
declare cfg archive.config; v_resp http_response;
begin
  if p_key is null then return null; end if;   -- no object recorded: the assertion reading it says so
  select * into cfg from archive.config where parent_table = p_parent;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '',
                                      'minioadmin', 'minioadmin');
  if v_resp.status not between 200 and 299 then raise exception 'fetch of % failed: HTTP %', p_key, v_resp.status; end if;
  return text_to_bytea(v_resp.content);
end $$;

-- an NDJSON object's ids, in order
create function t44.ids(p_parent regclass, p_key text) returns bigint[] language sql as $$
  select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
    from regexp_split_to_table(convert_from(t44.fetch(p_parent, p_key), 'UTF8'), e'\n') l where l <> ''
$$;

-- n44 archives through the NDJSON strategy, p44 through the Parquet one. 1..1200 lands in a monolith
-- [0, 2000); 2001..2005 in [2000, 3000) and 3001..3003 in [3000, 4000); the frontier 4000 with p_retain
-- 1000 puts the boundary at 3000, so the monolith and [2000, 3000) are due and [3000, 4000) is not.
call mk_archive_table('n44', 1200, 1000, 1000, p_paused => false);
call mk_archive_table('p44', 1200, 1000, 1000, p_paused => false);
insert into public.n44 (id, payload) select g, 'y' from generate_series(2001, 2005) g;
insert into public.n44 (id, payload) select g, 'z' from generate_series(3001, 3003) g;
insert into public.n44 (id, payload) values (4000, 'frontier');
insert into public.p44 (id, payload) select g, 'y' from generate_series(2001, 2005) g;
insert into public.p44 (id, payload) select g, 'z' from generate_series(3001, 3003) g;
insert into public.p44 (id, payload) values (4000, 'frontier');
select archive.configure('public.n44', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'run' || '/n44/');
select archive.configure('public.p44', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'run' || '/p44/');
update pgpm.config set retain_batch = 0, archive_batch = null
 where parent_table in ('public.n44'::regclass, 'public.p44'::regclass);
select pgpm.set_archive_fn('public.n44', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('public.p44', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select child_name as n_late from pgpm.part where parent_table = 'public.n44'::regclass and lo = '3000' \gset
select child_name as p_late from pgpm.part where parent_table = 'public.p44'::regclass and lo = '3000' \gset

-- the application's session: its own schema only
set search_path = app;
create temp table unseen as
  select pg_catalog.to_regtype('http_response') is null and pg_catalog.to_regtype('http_header') is null
     and pg_catalog.to_regprocedure('hmac(bytea,bytea,text)') is null as none_visible;
call pgpm.maintain('public.n44');
call pgpm.maintain('public.n44');
call pgpm.maintain('public.p44');
call pgpm.maintain('public.p44');
create temp table direct as
  select t44.try(pg_catalog.format('select archive.to_s3(%L, %L, %L, %L)', 'public.n44', :'n_late', '3000', '4000')) as to_s3,
         t44.try(pg_catalog.format('select archive.to_s3_parquet(%L, %L, %L, %L)', 'public.p44', :'p_late', '3000', '4000')) as to_s3_parquet,
         t44.try(pg_catalog.format('select archive._s3_abort_uploads_at(%L, %L, %L, %L, %L, %L)', 'http://minio:9000',
                                   'archive-test-bucket', 'us-east-1', :'run' || '/none.ndjson', 'minioadmin', 'minioadmin')) as abort_sweep;
reset search_path;

select ok((select none_visible from unseen),
  'LIVENESS: under search_path app neither the http extension''s types nor pgcrypto''s hmac are visible');

select is(
  (select array_agg(lo || ':' || pgpm._is_write_blocked(parent_table, child_name) order by parent_table::text, lo::numeric)
     from pgpm.part where parent_table in ('public.n44'::regclass, 'public.p44'::regclass) and lo in ('0', '2000', '3000')),
  array['0:true', '2000:true', '3000:false', '0:true', '2000:true', '3000:false'],
  'LIVENESS: the ticks under search_path app ran and write-blocked exactly the partitions due for archiving, on both tables');

select is(
  (select array_agg(parent_table::text || ' ' || lo || ' ' || rows_archived order by parent_table::text, lo::numeric)
     from pgpm.archive_ledger where parent_table in ('public.n44'::regclass, 'public.p44'::regclass)),
  array['n44 0 1200', 'n44 2000 5', 'p44 0 1200', 'p44 2000 5'],
  'the ticks under search_path app archived exactly the monolith and [2000, 3000) of each table, by both strategies');

select is(
  (select array_agg(action || ': ' || coalesce(method, '') order by at) from pgpm.log
    where parent_table in ('public.n44'::regclass, 'public.p44'::regclass) and action = 'skip_archive'),
  null::text[],
  'and logged no skip_archive: no archive call failed to resolve an extension object through the session search_path');

select is(
  array[t44.ids('public.n44', (select s3_key from pgpm.archive_ledger where parent_table = 'public.n44'::regclass and lo = '0'))::text,
        t44.ids('public.n44', (select s3_key from pgpm.archive_ledger where parent_table = 'public.n44'::regclass and lo = '2000'))::text],
  array[(select array_agg(g::bigint) from generate_series(1, 1200) g)::text, '{2001,2002,2003,2004,2005}'],
  'the NDJSON objects the tick wrote hold exactly the rows of the partitions they archived');

select is(
  (select array_agg(left(encode(t44.fetch('public.p44', s3_key), 'escape'), 4) order by lo::numeric)
     from pgpm.archive_ledger where parent_table = 'public.p44'::regclass),
  array['PAR1', 'PAR1'],
  'and both Parquet objects the tick wrote are there and are Parquet files');

select is((select (to_s3, to_s3_parquet, abort_sweep)::text from direct), '(ok,ok,ok)',
  'archive.to_s3 and archive.to_s3_parquet, called under search_path app, both export, and the multipart abort sweep they clean up with runs there too');

select is(
  t44.ids('public.n44', (select object_key from archive.object_key_claim where parent_oid = 'public.n44'::regclass::oid and kind = 'export')),
  array[3001, 3002, 3003]::bigint[],
  'the object archive.to_s3 wrote under search_path app holds exactly the rows of [3000, 4000)');

select is(
  t44.fetch('public.p44', (select object_key from archive.object_key_claim where parent_oid = 'public.p44'::regclass::oid and kind = 'export')),
  archive._pq_to_parquet(format('public.%I', :'p_late')::regclass,
                         (select compress from archive.config where parent_table = 'public.p44'::regclass)),
  'and the object archive.to_s3_parquet wrote is byte for byte the Parquet file of [3000, 4000)');

select * from finish();
