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
-- The same holds for what else the signers splice into that path or host (PR #1301's verification, V-01 and
-- V-02). An endpoint carrying credentials ('http://user@host:9000') had the signers sign 'user@host:9000' as the
-- Host while the client sends 'host:9000', and one whose path prefix holds an empty, '.' or '..' segment was
-- resolved away by the client or the store while the signature covered it: every request was refused 403. And
-- a bucket spelled '/my-bucket' addressed '//my-bucket/<key>', the issue's own HTTP 400 through the other
-- operand. configure refuses each by name (part F the endpoint's, part G the bucket's), without echoing a
-- password, and each refusal's remedy, typed as the message gives it, configures a table whose export lands.
--
-- And the scheme's default port (the third verification round, V-01): 'http://host:80' had the signers sign
-- 'host:80' as the Host while libcurl, which leaves a default port out, sends 'host', so the store refused every
-- request 403. The endpoint is stored, and used by both signers, without ':80' after http:// or ':443' after
-- https:// (part H). MinIO answers on 9000 here, so part H puts a stand-in in the place of the transport that
-- does what a store on port 80 would see: it sends the request to minio:9000 with the Host libcurl would send
-- for the URL the signer built (its authority, a trailing ':80' left out), and MinIO checks the signature
-- against that Host. A percent-encoded dot segment ('%2E%2E') is refused like a spelled one (part F).
--
-- And two things the fourth round found the refusals did not keep (V-01 and V-03). 'No host' was on the list of
-- what configure refuses, but an endpoint with a port and no host ('http://:9000') passed the check, was stored,
-- and every request through it died in the client ('No host part in the URL'): part I refuses it, and types the
-- remedy its message gives. And the refusals quoted the value they refused, so credentials spelled where the
-- credentials check did not look ('//user:password@host', 'http:/user:password@host') were printed whole by the
-- refusal that did fire. Part J states the rule for every refusal archive.configure can raise, ten of them, each
-- reached with a value carrying a password before an '@': the message is that refusal's own, and the password
-- is not in it. A refusal still quotes a value that holds no '@' (part J's first four lines), so the absence is
-- the rule's doing and not a message that shows nothing.
--
-- Each export's object is stated by identity (the rows it holds, two of them, by id and payload), its key
-- cleared and witnessed absent first, because the bucket outlives the test database; the prefix carries the
-- database's name so a parallel run of this file in another database cannot meet it.
select plan(89);

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
create function t53.cfgb(p_bucket text) returns void language sql as $$
  select archive.configure('t53.evt', p_bucket, p_endpoint => 'http://minio:9000',
                           p_prefix => current_setting('t53.p')) $$;
create function t53.bucket() returns text language sql as $$
  select bucket from archive.config where parent_table = 't53.evt'::regclass $$;
-- the message a statement raises, or 'no error'
create function t53.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then return sqlerrm;
end $$;
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
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');

-- ---- F. an endpoint with credentials, or a path prefix with an empty, '.' or '..' segment, is refused -------------
select t53.cfg('http://minio:9000');
select err as userinfo_err from t53.err($$ select t53.cfg('http://minioadmin:s3cr3t@minio:9000') $$) err \gset
select ok(:'userinfo_err' like '%p_endpoint must not carry credentials%',
  'an endpoint with user:password@ before the host is refused, naming p_endpoint (got: ' || :'userinfo_err' || ')');
select ok(:'userinfo_err' not like '%s3cr3t%', 'and the refusal does not echo the password');
select throws_like($$ select t53.cfg('http://minioadmin@minio:9000') $$, '%p_endpoint must not carry credentials%',
  'an endpoint with user@ before the host is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('minioadmin:s3cr3t@minio:9000') $$, '%p_endpoint must not carry credentials%',
  'an endpoint with credentials and no scheme is refused as carrying credentials, so its password is not echoed');
select throws_like($$ select t53.cfg('http://minio:9000/.') $$, '%p_endpoint''s path prefix must not hold%',
  'an endpoint whose path is a ''.'' segment is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000/storage/../s3/') $$, '%p_endpoint''s path prefix must not hold%',
  'an endpoint whose path prefix holds a ''..'' segment is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000//s3') $$, '%p_endpoint''s path prefix must not hold%',
  'an endpoint whose path prefix holds an empty segment is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000/storage/%2E%2E/s3') $$, '%p_endpoint''s path prefix must not hold%',
  'an endpoint whose path prefix holds a percent-encoded ''..'' segment is refused, naming p_endpoint');
select throws_like($$ select t53.cfg('http://minio:9000/%2e/') $$, '%p_endpoint''s path prefix must not hold%',
  'an endpoint whose path prefix is a percent-encoded ''.'' segment is refused, naming p_endpoint');
select is(t53.stored(), 'http://minio:9000', 'the refused endpoints leave the stored row as it was');
-- the remedy, as the message gives it: the URL without the credentials (the key stays in the Vault secrets named
-- by p_vault_key_id and p_vault_secret, the defaults the fixture fills)
select t53.cfg('http://minio:9000');
select is(t53.export(), 'ok', 'the userinfo refusal''s remedy (the URL without the credentials) exports');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');

-- ---- G. a bucket that is not a bare bucket name is refused by name -----------------------------------------------
select throws_like($$ select t53.cfgb('/archive-test-bucket') $$, '%p_bucket must be a bare bucket name%',
  'a bucket with a leading slash is refused, naming p_bucket');
select throws_like($$ select t53.cfgb('archive-test-bucket/') $$, '%p_bucket must be a bare bucket name%',
  'a bucket with a trailing slash is refused, naming p_bucket');
select throws_like($$ select t53.cfgb('archive-test-bucket/sub') $$, '%p_bucket must be a bare bucket name%',
  'a bucket with a path in it is refused, naming p_bucket');
select throws_like($$ select t53.cfgb('') $$, '%p_bucket must be a bare bucket name%',
  'an empty bucket is refused, naming p_bucket');
select throws_like($$ select t53.cfgb('..') $$, '%p_bucket must be a bare bucket name%',
  'a ''..'' bucket is refused, naming p_bucket');
select is(t53.bucket(), 'archive-test-bucket', 'the refused buckets leave the stored row as it was');
select t53.cfgb('my.bucket-1');
select is(t53.bucket(), 'my.bucket-1', 'a bucket name with dots and dashes is taken as given');
-- the remedy, as the message gives it: the bare bucket name
select t53.cfgb('archive-test-bucket');
select is(t53.export(), 'ok', 'the bucket refusal''s remedy (the bare name) exports');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');

-- ---- H. the scheme's default port is not part of the endpoint ---------------------------------------------------
select t53.cfg('http://minio:80/');
select is(t53.stored(), 'http://minio', 'an http:// endpoint is stored without its default port :80');
select archive.configure('t53.evt', 'archive-test-bucket', p_endpoint => 'https://ref.supabase.co:443/storage/v1/s3/',
                         p_prefix => current_setting('t53.p'));
select is(t53.stored(), 'https://ref.supabase.co/storage/v1/s3',
  'an https:// endpoint is stored without its default port :443, its path prefix kept');
select t53.cfg('http://minio:8080');
select is(t53.stored(), 'http://minio:8080', 'any other port is kept');
select t53.cfg('https://minio:80');
select is(t53.stored(), 'https://minio:80', 'and :80 after https://, not its default, is kept too');

-- the stand-in: a store on port 80, as MinIO sees it (see the header)
select mk_transport_standin('t53');
create function t53.http(r http_request) returns http_response language sql as $$
  select public.http((r.method, regexp_replace(r.uri, '^http://[^/]*', 'http://minio:9000'),
                      r.headers || public.http_header('host', regexp_replace(substring(r.uri from '^http://([^/]*)'), ':80$', '')),
                      r.content_type, r.content)::http_request) $$;
create function t53.export_port80() returns text language plpgsql as $$
begin
  perform set_config('t53.standin', 'on', true);
  perform archive.to_s3('t53.evt', 'evt', null, null);
  perform set_config('t53.standin', 'off', true);
  return 'ok';
exception when others then
  perform set_config('t53.standin', 'off', true);
  return sqlerrm;
end $$;
select t53.cfg('http://minio');
select is(t53.export_port80(), 'ok', 'LIVENESS: through the stand-in, an export through the endpoint spelled without a port reaches the store');
select is(t53.held(:'k'), '1:one,2:two', 'LIVENESS: and its object holds both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');
select t53.cfg('http://minio:80');
select is(t53.export_port80(), 'ok', 'an export through an endpoint configured with its default port is not refused by the store');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');
update archive.config set endpoint = 'http://minio:80' where parent_table = 't53.evt'::regclass;
select is(t53.export_port80(), 'ok', 'an export through a row stored by hand with the default port is not refused by the store');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared after the default-port exports');

-- ---- I. an endpoint with a port and no host is refused, and the remedy its message gives exports ------------------
select t53.cfg('http://minio:9000');
select err as nohost_err from t53.err($$ select t53.cfg('http://:9000') $$) err \gset
select ok(:'nohost_err' like '%p_endpoint has no host before its port%',
  'an endpoint with a port and no host is refused, naming p_endpoint (got: ' || :'nohost_err' || ')');
select throws_like($$ select t53.cfg('http://:9000/storage/v1/s3/') $$, '%p_endpoint has no host before its port%',
  'and so is one with a path prefix after the port');
select throws_like($$ select t53.cfg('https://:8443') $$, '%p_endpoint has no host before its port%',
  'and an https:// one');
select throws_like($$ select t53.cfg('http://:80') $$, '%p_endpoint must be null (AWS S3) or%',
  'the default port and no host is nothing after the scheme, refused as that, naming p_endpoint');
select is(t53.stored(), 'http://minio:9000', 'the host-less endpoints leave the stored row as it was');
-- what the refusal reads is an empty host, not a colon: an IPv6 literal's authority starts with '[' and holds several
select t53.cfg('http://[::1]:9000');
select is(t53.stored(), 'http://[::1]:9000', 'LIVENESS: an endpoint whose host is an IPv6 literal is not read as host-less');
-- the remedy, as the message gives it: the store's host name between the scheme and the port
select t53.cfg('http://minio:9000');
select is(t53.export(), 'ok', 'the no-host refusal''s remedy (the host name before the port) exports');
select is(t53.held(:'k'), '1:one,2:two', 'and its object lands at the key holding both rows');
select is((t53.req('DELETE', :'k')).status, 204, 'LIVENESS: the object is cleared');

-- ---- J. no refusal of archive.configure prints a value that holds an '@' ------------------------------------------
-- A refusal's answer to one call, judged: which refusal it is (the witness that the value reached the branch named),
-- and whether the password typed before the '@' is in it.
create function t53.judge(p_sql text, p_refusal text) returns text language sql as $$
  select case when m not like p_refusal then 'another answer: ' || replace(m, 's3cr3t', '<the password>')
              when m like '%s3cr3t%' then 'that refusal, printing the password'
              else 'that refusal, without the password' end
    from t53.err(p_sql) m $$;
-- the refusals that quote a value do quote one that holds no '@'
select ok(t53.err($$ select t53.cfg('minio:9000') $$) like '%not ''minio:9000''',
  'the format refusal quotes the value it refuses when that holds no ''@''');
select ok(t53.err($$ select t53.cfg('http://:9000') $$) like '%not ''http://:9000''',
  'and so does the no-host refusal');
select ok(t53.err($$ select t53.cfg('http://minio:9000/./s3') $$) like '%not ''http://minio:9000/./s3''',
  'and the path-segment refusal');
select ok(t53.err($$ select t53.cfgb('/archive-test-bucket') $$) like '%not ''/archive-test-bucket''',
  'and the bucket refusal');
-- the credentials refusal, which the three spellings below it used to miss
select is(t53.judge($$ select t53.cfg('http://user:s3cr3t@minio:9000') $$, '%p_endpoint must not carry credentials%'),
  'that refusal, without the password', 'the credentials refusal does not print the password');
-- the format refusal: credentials where the credentials check does not look for them
select is(t53.judge($$ select t53.cfg('//user:s3cr3t@minio:9000') $$, '%p_endpoint must be null (AWS S3) or%'),
  'that refusal, without the password', 'the format refusal of //user:password@host does not print the password');
select is(t53.judge($$ select t53.cfg('http:/user:s3cr3t@minio:9000') $$, '%p_endpoint must be null (AWS S3) or%'),
  'that refusal, without the password', 'nor that of http:/user:password@host');
select is(t53.judge($$ select t53.cfg('http:///user:s3cr3t@minio:9000') $$, '%p_endpoint must be null (AWS S3) or%'),
  'that refusal, without the password', 'nor that of http:///user:password@host');
select is(t53.judge($$ select t53.cfg('http://user:pa/s3cr3t@minio:9000?x=1') $$, '%p_endpoint must be null (AWS S3) or%'),
  'that refusal, without the password', 'nor that of a password holding a ''/'', before a query string');
select is(t53.judge($$ select t53.cfg('http:/user:p@s3cr3t') $$, '%p_endpoint must be null (AWS S3) or%'),
  'that refusal, without the password', 'nor that of a password holding an ''@'' itself, which no host follows');
-- the no-host and path-segment refusals, reached with an '@' in the path
select is(t53.judge($$ select t53.cfg('http://:9000/user:s3cr3t@minio') $$, '%p_endpoint has no host before its port%'),
  'that refusal, without the password', 'the no-host refusal does not print what precedes an ''@''');
select is(t53.judge($$ select t53.cfg('http://minio:9000/./user:s3cr3t@minio') $$, '%p_endpoint''s path prefix must not hold%'),
  'that refusal, without the password', 'the path-segment refusal does not print what precedes an ''@''');
-- the bucket refusal, reached with the store's whole URL, credentials and all, typed as the bucket
select is(t53.judge($$ select t53.cfgb('http://user:s3cr3t@minio:9000/archive-test-bucket') $$, '%p_bucket must be a bare bucket name%'),
  'that refusal, without the password', 'the bucket refusal does not print what precedes an ''@''');
-- and the five refusals that quote no text value, each raised before the endpoint is read
create function t53.cfgx(p_parent regclass, p_bucket text, p_part_bytes bigint, p_fetch_rows int) returns void language sql as $$
  select archive.configure(p_parent, p_bucket, p_endpoint => 'http://user:s3cr3t@minio:9000',
                           p_prefix => current_setting('t53.p'), p_part_bytes => p_part_bytes, p_fetch_rows => p_fetch_rows) $$;
create table t53.unmanaged (id bigint primary key);
select is(t53.judge($$ select t53.cfgx('t53.evt', null, 8388608, 20000) $$, '%archive.configure does not accept null for p_bucket%'),
  'that refusal, without the password', 'the null-argument refusal does not print the endpoint''s password');
select is(t53.judge($$ select t53.cfgx('t53.unmanaged', 'archive-test-bucket', 8388608, 20000) $$, '%t53.unmanaged is not managed by pgpm%'),
  'that refusal, without the password', 'nor the unmanaged-table refusal');
select is(t53.judge($$ select t53.cfgx('t53.evt', 'archive-test-bucket', 0, 20000) $$, '%p_part_bytes must be a positive number of bytes%'),
  'that refusal, without the password', 'nor the part-size refusal');
select is(t53.judge($$ select t53.cfgx('t53.evt', 'archive-test-bucket', 1, 20000) $$, '%p_part_bytes must be at least 5242880 bytes%'),
  'that refusal, without the password', 'nor the smallest-part refusal');
select is(t53.judge($$ select t53.cfgx('t53.evt', 'archive-test-bucket', 8388608, 0) $$, '%p_fetch_rows must be a positive number of rows%'),
  'that refusal, without the password', 'nor the page-size refusal');
select is(t53.stored() || ' ' || t53.bucket(), 'http://minio:9000 archive-test-bucket',
  'and every one of them leaves the stored row as it was');

select * from finish();
