-- archive.to_s3 aborts an in-flight multipart upload on the way out of a failed export, so no
-- invisible incomplete parts accrue storage. Its handler was `exception when others`, and `others`
-- does not catch query_canceled (57014), so the commonest way out of a long export, statement_timeout
-- or a cancel, skipped the abort and left the upload and its parts in the bucket (issue #595). A
-- cancel that arrives while another error is being raised is subtler: it is taken at the first
-- statement of the handler, outside any scope that catches it, so even a handler that names
-- query_canceled never gets to its DELETE. The abort now also runs from an enclosing block that
-- catches the cancel, wherever it surfaced, and the cancel still propagates.
--
-- Three exports, each through multipart (part_bytes 1, fetch_rows 1: one row per part):
--   A. a cancel raised INSIDE the transport call on part 3 (deterministic);
--   B. a real statement_timeout mid-export, the issue's own shape;
--   C. a transport error raised on part 3 while a cancel is already pending, so the cancel surfaces
--      at the handler's first statement (deterministic).
-- A stand-in for the http extension's http(http_request), ahead of public in search_path (the
-- signers call it unqualified), forwards every request to the real one against MinIO and counts
-- initiates, part PUTs and abort DELETEs in sequences, which a rolled-back export cannot undo. For A
-- and C it also lists the uploads in flight at the export's key at the moment it breaks the export,
-- so "nothing in flight afterwards" is paired with "one in flight when the export broke". Each key is
-- cleared of stale uploads and witnessed clean first, because the bucket outlives a test database.
select plan(17);

create schema t24;

-- a signed request through the REAL transport (the signer, while search_path is the default)
create function t24.req(p_parent regclass, p_method text, p_key text, p_query text) returns http_response
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  return archive.s3_signed_request(p_method, cfg.endpoint, cfg.bucket, cfg.region, p_key, p_query, 'text/plain', '', v_key_id, v_secret);
end $$;

-- the UploadIds MinIO lists as in flight under a key. ListMultipartUploads is a BUCKET-level request
-- (GET /<bucket>/?prefix=..&uploads=) that archive.s3_signed_request cannot address with an empty key,
-- so this signs it itself, the same SigV4 steps, and calls public.http by its qualified name so the
-- stand-in can call it too.
create function t24.inflight(p_parent regclass, p_key text) returns text[]
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; r http_response;
  v_host text; v_uri text; v_q text; v_amz text; v_date text; v_ph text; v_scope text; v_can text; v_sts text; v_k bytea; v_sig text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_host := regexp_replace(cfg.endpoint, '^https?://([^/]+).*$', '\1');
  v_uri := '/' || cfg.bucket || '/';
  v_q := 'prefix=' || archive.s3_url_encode(p_key) || '&uploads=';
  v_amz := to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
  v_date := substr(v_amz, 1, 8);
  v_ph := encode(digest('', 'sha256'), 'hex');
  v_scope := v_date || '/' || cfg.region || '/s3/aws4_request';
  v_can := 'GET' || e'\n' || v_uri || e'\n' || v_q || e'\n' || 'content-type:text/plain' || e'\n' || 'host:' || v_host || e'\n'
        || 'x-amz-content-sha256:' || v_ph || e'\n' || 'x-amz-date:' || v_amz || e'\n' || e'\n'
        || 'content-type;host;x-amz-content-sha256;x-amz-date' || e'\n' || v_ph;
  v_sts := 'AWS4-HMAC-SHA256' || e'\n' || v_amz || e'\n' || v_scope || e'\n' || encode(digest(v_can, 'sha256'), 'hex');
  v_k := hmac(convert_to(v_date, 'UTF8'), convert_to('AWS4' || v_secret, 'UTF8'), 'sha256');
  v_k := hmac(convert_to(cfg.region, 'UTF8'), v_k, 'sha256');
  v_k := hmac(convert_to('s3', 'UTF8'), v_k, 'sha256');
  v_k := hmac(convert_to('aws4_request', 'UTF8'), v_k, 'sha256');
  v_sig := encode(hmac(convert_to(v_sts, 'UTF8'), v_k, 'sha256'), 'hex');
  r := public.http(('GET'::http_method, cfg.endpoint || v_uri || '?' || v_q,
             array[http_header('x-amz-date', v_amz), http_header('x-amz-content-sha256', v_ph),
                   http_header('authorization', 'AWS4-HMAC-SHA256 Credential=' || v_key_id || '/' || v_scope
                     || ', SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=' || v_sig)],
             'text/plain', '')::http_request);
  if r.status not between 200 and 299 then raise exception 'list uploads: HTTP % %', r.status, left(r.content, 200); end if;
  return coalesce((select array_agg(x::text) from unnest(xpath('//*[local-name()=''UploadId'']/text()', r.content::xml)) x), '{}');
end $$;

-- abort whatever an earlier run left at a key, so what is listed afterwards came from THIS run
create function t24.abort_all(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare u text; n int := 0;
begin
  foreach u in array t24.inflight(p_parent, p_key) loop
    perform t24.req(p_parent, 'DELETE', p_key, 'uploadId=' || archive.s3_url_encode(u)); n := n + 1;
  end loop;
  return n;
end $$;

-- Counters that survive the export's rollback. `seen` is the in-flight count sampled when the stand-in
-- broke the export; -1 means it never sampled.
create sequence t24.initiated;
create sequence t24.parts;
create sequence t24.aborts;
create sequence t24.seen minvalue -1;
create function t24.n(p_seq regclass) returns bigint language plpgsql as $$
declare v bigint; c boolean;
begin
  execute format('select last_value, is_called from %s', p_seq) into v, c;
  return case when c then v else 0 end;
end $$;
create function t24.reset() returns void language sql as $$
  select setval('t24.initiated', 1, false), setval('t24.parts', 1, false), setval('t24.aborts', 1, false),
         setval('t24.seen', -1, true)
$$;

-- The stand-in. t24.mode: 'count' forwards everything; 'cancel' raises query_canceled from inside the
-- transport after part t24.at_part is stored; 'pending' queues a cancel against this backend and raises
-- an ordinary transport error in the same statement, so the cancel is still pending when the error
-- reaches archive.to_s3's handler. Both sample the uploads in flight at t24.key first.
create function t24.http(r http_request) returns http_response language plpgsql as $$
declare v_resp http_response; v_n bigint; v_mode text := current_setting('t24.mode');
begin
  if r.method::text = 'POST' and r.uri like '%?uploads=%' then perform nextval('t24.initiated');
  elsif r.method::text = 'DELETE' and r.uri like '%?uploadId=%' then perform nextval('t24.aborts');
  end if;
  v_resp := public.http(r);
  if r.method::text = 'PUT' and r.uri like '%?partNumber=%' then
    v_n := nextval('t24.parts');
    if v_mode <> 'count' and v_n = current_setting('t24.at_part')::bigint then
      perform setval('t24.seen', cardinality(t24.inflight(current_setting('t24.parent')::regclass, current_setting('t24.key'))), true);
      if v_mode = 'cancel' then
        raise exception 't24: cancel inside the transport' using errcode = 'query_canceled';
      else
        raise exception 't24: transport aborted by callback (cancel queued: %)', pg_cancel_backend(pg_backend_pid());
      end if;
    end if;
  end if;
  return v_resp;
end $$;

create temp table outcome (label text primary key, sqlstate text, msg text);

-- one export under the stand-in, its outcome recorded. search_path is set inside the call (SET LOCAL
-- semantics through set_config) so the stand-in is in the way of the export and of nothing else.
create procedure t24.export(p_label text, p_parent text) language plpgsql as $$
declare v_child text;
begin
  select child_name into v_child from pgpm.part where parent_table = p_parent::regclass order by lo::numeric limit 1;
  perform set_config('search_path', 't24, public', true);
  begin
    perform archive.to_s3(p_parent::regclass, v_child, '0', '100000');
    insert into outcome values (p_label, '00000', 'returned');
  exception when query_canceled or others then
    insert into outcome values (p_label, sqlstate, sqlerrm);
  end;
  perform set_config('search_path', 'public', true);
end $$;

-- --- fixtures: three tables, one multipart export each -------------------------------------------

call mk_archive_table('ca24', 40, 100000, null, true);
call mk_archive_table('cb24', 20000, 100000, null, true);
call mk_archive_table('cc24', 60, 100000, null, true);
select mk_archive_config('ca24'); select mk_archive_config('cb24'); select mk_archive_config('cc24');
update archive.config set part_bytes = 1, fetch_rows = 1, prefix = current_database() || '/' || (parent_table::text) || '/'
 where parent_table in ('public.ca24'::regclass, 'public.cb24'::regclass, 'public.cc24'::regclass);
select current_database() || '/ca24/public.' || (select child_name from pgpm.part where parent_table = 'public.ca24'::regclass order by lo::numeric limit 1) || '.ndjson' as ka,
       current_database() || '/cb24/public.' || (select child_name from pgpm.part where parent_table = 'public.cb24'::regclass order by lo::numeric limit 1) || '.ndjson' as kb,
       current_database() || '/cc24/public.' || (select child_name from pgpm.part where parent_table = 'public.cc24'::regclass order by lo::numeric limit 1) || '.ndjson' as kc
\gset

select ok(t24.abort_all('public.ca24', :'ka') >= 0 and t24.inflight('public.ca24', :'ka') = '{}'
      and t24.abort_all('public.cb24', :'kb') >= 0 and t24.inflight('public.cb24', :'kb') = '{}'
      and t24.abort_all('public.cc24', :'kc') >= 0 and t24.inflight('public.cc24', :'kc') = '{}',
  'LIVENESS: no multipart upload is in flight at any of the three keys before the exports');

-- the lister can see an in-flight upload: initiate one at a probe key, list it, abort it
select (xpath('//*[local-name()=''UploadId'']/text()',
        (t24.req('public.ca24', 'POST', :'ka' || '.probe', 'uploads=')).content::xml))[1]::text as probe_id \gset
select is(t24.inflight('public.ca24', :'ka' || '.probe'), array[:'probe_id'],
  'LIVENESS: the lister sees an upload initiated at a probe key, by its UploadId');
select is(t24.abort_all('public.ca24', :'ka' || '.probe'), 1, 'LIVENESS: and the probe upload is aborted');

-- --- A: a cancel raised inside the transport call ------------------------------------------------

select t24.reset();
select set_config('t24.mode', 'cancel', false), set_config('t24.at_part', '3', false),
       set_config('t24.parent', 'public.ca24', false), set_config('t24.key', :'ka', false);
call t24.export('A', 'public.ca24');

select is((select (sqlstate, msg)::text from outcome where label = 'A'), '(57014,"t24: cancel inside the transport")',
  'A: the stand-in''s cancel propagates out of archive.to_s3 as itself, not swallowed by the cleanup');
select is(array[t24.n('t24.initiated'), t24.n('t24.parts')], array[1, 3]::bigint[],
  'A LIVENESS: the export initiated one upload and stored three parts before the cancel');
select is(t24.n('t24.seen'), 1::bigint,
  'A LIVENESS: one upload was in flight at the key when the cancel landed');
select is(t24.n('t24.aborts'), 1::bigint, 'A: archive.to_s3 sent the abort for it');
select is(t24.inflight('public.ca24', :'ka'), '{}'::text[],
  'A: no multipart upload is left in flight at the key after the cancelled export');

-- --- B: a real statement_timeout mid-export (the issue's shape) ----------------------------------

select t24.reset();
select set_config('t24.mode', 'count', false);
set statement_timeout = '3s';
call t24.export('B', 'public.cb24');
reset statement_timeout;

select is((select sqlstate from outcome where label = 'B'), '57014',
  'B LIVENESS: the export was ended by statement_timeout');
select ok(t24.n('t24.initiated') = 1 and t24.n('t24.parts') >= 1,
  'B LIVENESS: it had initiated its upload and stored parts before the timeout: ' || t24.n('t24.parts') || ' part(s)');
select cmp_ok(t24.n('t24.aborts'), '>=', 1::bigint, 'B: archive.to_s3 sent the abort');
select is(t24.inflight('public.cb24', :'kb'), '{}'::text[],
  'B: no multipart upload is left in flight at the key after the timed-out export');

-- --- C: a transport error while a cancel is pending ----------------------------------------------

select t24.reset();
select set_config('t24.mode', 'pending', false), set_config('t24.at_part', '3', false),
       set_config('t24.parent', 'public.cc24', false), set_config('t24.key', :'kc', false);
call t24.export('C', 'public.cc24');

select is((select (sqlstate, msg)::text from outcome where label = 'C'), '(57014,"canceling statement due to user request")',
  'C LIVENESS: the pending cancel surfaced as query_canceled after the transport error');
select is(array[t24.n('t24.initiated'), t24.n('t24.parts')], array[1, 3]::bigint[],
  'C LIVENESS: the export initiated one upload and stored three parts before the transport error');
select is(t24.n('t24.seen'), 1::bigint,
  'C LIVENESS: one upload was in flight at the key when the transport failed');
select is(t24.n('t24.aborts'), 1::bigint, 'C: archive.to_s3 sent the abort even though the cancel cut its first handler short');
select is(t24.inflight('public.cc24', :'kc'), '{}'::text[],
  'C: no multipart upload is left in flight at the key');

select t24.abort_all('public.ca24', :'ka') + t24.abort_all('public.cb24', :'kb') + t24.abort_all('public.cc24', :'kc') as leftover \gset
select * from finish();
