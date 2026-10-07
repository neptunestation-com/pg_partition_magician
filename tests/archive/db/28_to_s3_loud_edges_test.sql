-- Three loud edges of archive.to_s3 left after #594/#595 (issue #636), none losing rows, each now
-- refused or cleaned up where it starts:
--
--   1. archive.configure refused only p_part_bytes <= 0, so a positive size under S3's 5 MiB minimum
--      for a non-final multipart part was stored, and every export spanning more than one part then
--      uploaded all of them and failed at CompleteMultipartUpload with EntityTooSmall. configure now
--      refuses anything under 5 MiB, and the smallest size it accepts is exactly 5 MiB.
--   2. archive.configure had no bound on p_fetch_rows: 0 read no page and tripped the conservation
--      check with a message about rows, and a negative value failed on LIMIT. configure refuses a
--      p_fetch_rows under 1, and archive.to_s3 refuses a row that holds one anyway, by name.
--   3. The initiate POST (CreateMultipartUpload) sat outside #595's abort: the handlers abort the
--      upload whose id they recorded, and an export broken INSIDE the initiate, after the store had
--      created the upload but before its UploadId reached archive.to_s3, recorded none, so the upload
--      was left in flight with nothing to abort it. A cancel (A) and an ordinary transport error (B)
--      landing there now both leave no upload in flight at the key, and the sweep that finds the
--      orphan reaches no other key: an upload at a key the export's key is a PREFIX of survives.
--
-- For 3, a stand-in for the http extension's http(http_request), in the place of the module's
-- transport, archive._s3_send (the one place every request goes through, #984), forwards every request
-- to the real one against MinIO, counts initiates, part PUTs and abort DELETEs in sequences (which a rolled-back export cannot undo), and
-- breaks the export right after the initiate's real response arrived, so the store HAS the upload and
-- archive.to_s3 never saw its id. The id escapes the rolled-back export in the error message itself,
-- which is how the file can say WHICH upload must be gone, not only how many are left.
--
-- The stand-in also answers the sweep's ListMultipartUploads the way S3 does, by key PREFIX (#711).
-- MinIO lists only the exact key, so passed through, the listing never offered the sweep the bystander
-- at the longer key, and the bystander assertions held with archive._s3_abort_uploads_at's exact-key
-- filter deleted: the one line that keeps an S3 sweep off another object's upload went unwatched. The
-- answer is built from MinIO's whole-bucket listing, every upload whose key begins with the export's
-- key, and the stand-in counts what it offered beyond the exact key, which is the witness that the
-- filter had something to filter. An abort is sent to the export's own key, and MinIO, like S3, refuses
-- an UploadId that is not an upload at that key (NoSuchUpload), so the bystander would survive even a
-- sweep without the filter: what such a sweep does is SEND an abort naming the bystander's upload. The
-- stand-in therefore sorts the aborts it forwards by the UploadId they name, the bystander's or any other.
select plan(29);

create schema t28;

-- a signed request through the REAL transport (the signer, while the stand-in is switched off)
create function t28.req(p_parent regclass, p_method text, p_key text, p_query text) returns http_response
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  return archive.s3_signed_request(p_method, cfg.endpoint, cfg.bucket, cfg.region, p_key, p_query, 'text/plain', '', v_key_id, v_secret);
end $$;

-- The uploads MinIO lists as in flight under a key PREFIX, (key, UploadId), signed here and sent
-- through public.http by its qualified name, independent of the code under test (the same instrument
-- as tests/archive/db/24, which also reads the keys). MinIO answers a prefix listing with the exact key
-- only; with p_prefix null this lists the whole bucket, which MinIO does answer in full.
create function t28.list(p_parent regclass, p_prefix text) returns table(k text, id text)
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; r http_response;
  v_host text; v_uri text; v_q text; v_amz text; v_date text; v_ph text; v_scope text; v_can text; v_sts text; v_k bytea; v_sig text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_host := regexp_replace(cfg.endpoint, '^https?://([^/]+).*$', '\1');
  v_uri := '/' || cfg.bucket || '/';
  v_q := case when p_prefix is null then 'uploads=' else 'prefix=' || archive.s3_url_encode(p_prefix) || '&uploads=' end;
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
  return query select x.k, x.id from xmltable('//*[local-name()=''Upload'']' passing (r.content::xml)
                  columns k text path '*[local-name()=''Key'']', id text path '*[local-name()=''UploadId'']') x;
end $$;

-- the UploadIds in flight under a prefix, sorted
create function t28.inflight(p_parent regclass, p_prefix text) returns text[] language sql as $$
  select coalesce(array_agg(id order by id), '{}') from t28.list(p_parent, p_prefix)
$$;

-- abort whatever an earlier run left under a prefix, each at its own key, so what is listed
-- afterwards came from THIS run
create function t28.abort_all(p_parent regclass, p_prefix text) returns int
language plpgsql as $$
declare n int := 0; r record;
begin
  for r in select * from t28.list(p_parent, p_prefix) loop
    perform t28.req(p_parent, 'DELETE', r.k, 'uploadId=' || archive.s3_url_encode(r.id)); n := n + 1;
  end loop;
  return n;
end $$;

create sequence t28.initiated;
create sequence t28.parts;
create sequence t28.aborts;
create sequence t28.offered;
create sequence t28.bystander_aborts;
create function t28.n(p_seq regclass) returns bigint language plpgsql as $$
declare v bigint; c boolean;
begin
  execute format('select last_value, is_called from %s', p_seq) into v, c;
  return case when c then v else 0 end;
end $$;
create function t28.reset() returns void language sql as $$
  select setval('t28.initiated', 1, false), setval('t28.parts', 1, false), setval('t28.aborts', 1, false),
         setval('t28.offered', 1, false), setval('t28.bystander_aborts', 1, false)
$$;

-- The stand-in. t28.mode 'cancel' raises query_canceled, 'error' an ordinary error, in both cases
-- right after the initiate's real response arrived: the store has created the upload, and its
-- UploadId, which the message carries out, never reaches archive.to_s3. The message also says whether
-- the upload was listed in flight at the key at that moment.
create function t28.http(r http_request) returns http_response language plpgsql as $$
declare v_resp http_response; v_id text; v_listed boolean; v_key text := current_setting('t28.key'); v_xml xml;
begin
  -- the sweep's listing of uploads at the export's key, answered with S3's prefix semantics (see the top)
  if r.method::text = 'GET' and r.uri like '%&uploads='
     and position('prefix=' || archive.s3_url_encode(v_key) || '&' in r.uri) > 0 then
    select xmlelement(name "ListMultipartUploadsResult",
             xmlelement(name "IsTruncated", 'false'),
             xmlagg(xmlelement(name "Upload", xmlelement(name "Key", l.k), xmlelement(name "UploadId", l.id))))
      into v_xml
      from t28.list(current_setting('t28.parent')::regclass, null) l
     where starts_with(l.k, v_key);
    perform nextval('t28.offered') from xpath('//Upload/Key/text()', v_xml) k where k::text <> v_key;
    return (200, 'application/xml', '{}'::http_header[], v_xml::text)::http_response;
  end if;
  if r.method::text = 'POST' and r.uri like '%?uploads=%' then perform nextval('t28.initiated');
  elsif r.method::text = 'PUT' and r.uri like '%?partNumber=%' then perform nextval('t28.parts');
  elsif r.method::text = 'DELETE' and r.uri like '%?uploadId=%' then
    -- the abort's UploadId is the last thing in its URI; t28.other is the bystander's, once it exists
    perform nextval(case when right(r.uri, length('uploadId=' || archive.s3_url_encode(coalesce(current_setting('t28.other', true), ''))))
                              = 'uploadId=' || archive.s3_url_encode(coalesce(current_setting('t28.other', true), ''))
                         then 't28.bystander_aborts' else 't28.aborts' end);
  end if;
  v_resp := public.http(r);
  if r.method::text = 'POST' and r.uri like '%?uploads=%' then
    v_id := (xpath('//*[local-name()=''UploadId'']/text()', v_resp.content::xml))[1]::text;
    v_listed := v_id = any(t28.inflight(current_setting('t28.parent')::regclass, current_setting('t28.key')));
    if current_setting('t28.mode') = 'cancel' then
      raise exception 't28: cancel inside the initiate; upload % listed: %', v_id, case when v_listed then 'yes' else 'no' end using errcode = 'query_canceled';
    else
      raise exception 't28: transport error inside the initiate; upload % listed: %', v_id, case when v_listed then 'yes' else 'no' end;
    end if;
  end if;
  return v_resp;
end $$;

-- The stand-in takes the place of the module's transport, archive._s3_send, while t28.standin is on
-- (#984: the signers reach the http extension only through it, never through search_path).
select mk_transport_standin('t28');

create temp table outcome (label text primary key, sqlstate text, msg text);

-- one export under the stand-in, its outcome recorded. t28.standin is set inside the call (SET LOCAL
-- semantics through set_config) so the stand-in is in the way of the export and of nothing else.
create procedure t28.export(p_label text, p_parent text) language plpgsql as $$
declare v_child text;
begin
  select child_name into v_child from pgpm.part where parent_table = p_parent::regclass order by lo::numeric limit 1;
  perform set_config('t28.standin', 'on', true);
  begin
    perform archive.to_s3(p_parent::regclass, v_child, '0', '100000');
    insert into outcome values (p_label, '00000', 'returned');
  exception when query_canceled or others then
    insert into outcome values (p_label, sqlstate, sqlerrm);
  end;
  perform set_config('t28.standin', 'off', true);
end $$;

-- a statement's error message, or 'ok'
create function t28.try(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm; end $$;

-- --- fixtures ------------------------------------------------------------------------------------

call mk_archive_table('le28', 30, 100000, null, true);
call mk_archive_table('la28', 7, 100000, null, true);
call mk_archive_table('lb28', 4, 100000, null, true);
select mk_archive_config('le28'); select mk_archive_config('la28'); select mk_archive_config('lb28');
select child_name as le_child from pgpm.part where parent_table = 'public.le28'::regclass order by lo::numeric limit 1 \gset

select is((select (part_bytes, fetch_rows, prefix)::text from archive.config where parent_table = 'public.le28'::regclass),
  '(8388608,20000,le28/)',
  'LIVENESS: le28 is configured with the default part_bytes and fetch_rows and its own prefix');

-- --- 1. part_bytes under S3's 5 MiB part minimum --------------------------------------------------

select throws_like(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_part_bytes => 1) $$,
  'archive.configure: p_part_bytes must be at least 5242880 bytes (5 MiB, the smallest multipart part S3 accepts), not 1',
  'archive.configure refuses p_part_bytes => 1');
select throws_like(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_part_bytes => 5242879) $$,
  'archive.configure: p_part_bytes must be at least 5242880 bytes (5 MiB, the smallest multipart part S3 accepts), not 5242879',
  'archive.configure refuses one byte under 5 MiB');
select throws_like(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_part_bytes => 0) $$,
  'archive.configure: p_part_bytes must be a positive number of bytes, not 0',
  'archive.configure still refuses p_part_bytes => 0 by its #594 message');
select is((select (part_bytes, prefix)::text from archive.config where parent_table = 'public.le28'::regclass),
  '(8388608,le28/)',
  'the part_bytes refusals wrote nothing: the row keeps its part_bytes AND its prefix');

select lives_ok(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'le28/', p_part_bytes => 5242880) $$,
  'LIVENESS: exactly 5 MiB is accepted');
select is((select part_bytes from archive.config where parent_table = 'public.le28'::regclass), 5242880::bigint,
  'LIVENESS: and stored, so the floor is at 5 MiB and not somewhere above it');

-- --- 2. fetch_rows under 1 -----------------------------------------------------------------------

select throws_like(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_fetch_rows => 0) $$,
  'archive.configure: p_fetch_rows must be a positive number of rows, not 0',
  'archive.configure refuses p_fetch_rows => 0');
select throws_like(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_fetch_rows => -1) $$,
  'archive.configure: p_fetch_rows must be a positive number of rows, not -1',
  'archive.configure refuses a negative p_fetch_rows');
select is((select (fetch_rows, prefix)::text from archive.config where parent_table = 'public.le28'::regclass),
  '(20000,le28/)',
  'the fetch_rows refusals wrote nothing: the row keeps its fetch_rows AND its prefix');

select lives_ok(
  $$ select archive.configure('public.le28', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'le28/', p_fetch_rows => 1) $$,
  'LIVENESS: p_fetch_rows => 1 is accepted');
select is((select fetch_rows from archive.config where parent_table = 'public.le28'::regclass), 1,
  'LIVENESS: and stored, so the bound is at one row and not above it');

-- a row that holds one anyway (written before the bound, or by a raw UPDATE) is refused by name
update archive.config set fetch_rows = 0 where parent_table = 'public.le28'::regclass;
select is(t28.try(format($$ select archive.to_s3('public.le28', %L, '0', '100000') $$, :'le_child')),
  'archive.to_s3: le28 has archive.config.fetch_rows 0; it must be a positive number of rows (set it with archive.configure)',
  'archive.to_s3 refuses fetch_rows = 0 in the row, by name');
update archive.config set fetch_rows = -3 where parent_table = 'public.le28'::regclass;
select is(t28.try(format($$ select archive.to_s3('public.le28', %L, '0', '100000') $$, :'le_child')),
  'archive.to_s3: le28 has archive.config.fetch_rows -3; it must be a positive number of rows (set it with archive.configure)',
  'archive.to_s3 refuses a negative fetch_rows in the row, by name');
update archive.config set fetch_rows = 7 where parent_table = 'public.le28'::regclass;
select is(t28.try(format($$ select archive.to_s3('public.le28', %L, '0', '100000') $$, :'le_child')), 'ok',
  'LIVENESS: the same export succeeds once fetch_rows is positive again');

-- --- 3. an export broken inside the initiate POST -------------------------------------------------

-- one row per page and per part, so each export initiates a multipart upload after its first page
update archive.config set part_bytes = 1, fetch_rows = 1, prefix = current_database() || '/' || (parent_table::text) || '/'
 where parent_table in ('public.la28'::regclass, 'public.lb28'::regclass);
select current_database() || '/la28/public.' || (select child_name from pgpm.part where parent_table = 'public.la28'::regclass order by lo::numeric limit 1) || '.ndjson' as ka,
       current_database() || '/lb28/public.' || (select child_name from pgpm.part where parent_table = 'public.lb28'::regclass order by lo::numeric limit 1) || '.ndjson' as kb
\gset

select ok(t28.abort_all('public.la28', :'ka') >= 0 and t28.inflight('public.la28', :'ka') = '{}'
      and t28.abort_all('public.la28', :'ka' || '.other') >= 0 and t28.inflight('public.la28', :'ka' || '.other') = '{}'
      and t28.abort_all('public.lb28', :'kb') >= 0 and t28.inflight('public.lb28', :'kb') = '{}',
  'LIVENESS: no multipart upload is in flight at either key, or at the bystander''s, before the exports');

-- A bystander at a key la28's key is a prefix of. S3 lists uploads by key PREFIX, so a sweep that
-- matched the prefix alone would abort it. MinIO lists only the exact key (measured: a prefix listing
-- of la28's key does not show it), which is why the stand-in answers the sweep's listing itself, with
-- the bystander in it; the exact-key filter in archive._s3_abort_uploads_at is then all that keeps the
-- sweep off it, here as against S3.
select (xpath('//*[local-name()=''UploadId'']/text()',
        (t28.req('public.la28', 'POST', :'ka' || '.other', 'uploads=')).content::xml))[1]::text as other_id \gset
select is(t28.inflight('public.la28', :'ka' || '.other'), array[:'other_id'],
  'LIVENESS: the bystander upload is in flight at la28''s key || ''.other''');
select set_config('t28.other', :'other_id', false);

-- A: a cancel inside the initiate

select t28.reset();
select set_config('t28.mode', 'cancel', false), set_config('t28.parent', 'public.la28', false), set_config('t28.key', :'ka', false);
call t28.export('A', 'public.la28');
select substring(msg from 'upload (\S+) listed') as a_id from outcome where label = 'A' \gset

select is((select sqlstate from outcome where label = 'A'), '57014',
  'A: the cancel propagates out of archive.to_s3 as itself');
select alike((select msg from outcome where label = 'A'), 't28: cancel inside the initiate; upload % listed: yes',
  'A LIVENESS: the store had created the upload and listed it in flight when the cancel landed');
select is(array[t28.n('t28.initiated'), t28.n('t28.parts')], array[1, 0]::bigint[],
  'A LIVENESS: one initiate and no part: the cancel landed before archive.to_s3 knew the upload''s id');
select ok(not (:'a_id' = any(t28.inflight('public.la28', :'ka'))),
  'A: the upload the cancelled initiate created is no longer in flight');
-- the bystander's half pairs the negative with its witness: the listing the sweep read OFFERED it the
-- bystander (as S3's would), and no abort named it
select is(format('%s | %s | offered %s, named %s', t28.inflight('public.la28', :'ka'), t28.inflight('public.la28', :'ka' || '.other'),
                 t28.n('t28.offered'), t28.n('t28.bystander_aborts')),
  '{} | {' || :'other_id' || '} | offered 1, named 0',
  'A: nothing is left in flight at the key, and the bystander at the longer key is untouched: the sweep''s listing offered it, and no abort named it');
select is(t28.n('t28.aborts'), 1::bigint,
  'A: archive.to_s3 sent exactly one abort naming an upload other than the bystander''s: the orphan at its key');

-- B: an ordinary transport error inside the initiate (the `when others` path)

select t28.reset();
select set_config('t28.mode', 'error', false), set_config('t28.parent', 'public.lb28', false), set_config('t28.key', :'kb', false);
call t28.export('B', 'public.lb28');
select substring(msg from 'upload (\S+) listed') as b_id from outcome where label = 'B' \gset

select is((select sqlstate from outcome where label = 'B'), 'P0001',
  'B: the transport error propagates out of archive.to_s3 as itself');
select alike((select msg from outcome where label = 'B'), 't28: transport error inside the initiate; upload % listed: yes',
  'B LIVENESS: the store had created the upload and listed it in flight when the error was raised');
select is(array[t28.n('t28.initiated'), t28.n('t28.parts')], array[1, 0]::bigint[],
  'B LIVENESS: one initiate and no part');
select ok(:'b_id' <> :'a_id', 'B LIVENESS: a different upload from A''s');
select is(t28.inflight('public.lb28', :'kb'), '{}'::text[],
  'B: no multipart upload is left in flight at the key after the failed export');

-- the bystander was only ever a witness: abort it, and say the bucket is clean
select is(t28.abort_all('public.la28', :'ka') + t28.abort_all('public.la28', :'ka' || '.other') + t28.abort_all('public.lb28', :'kb'), 1,
  'the only upload left behind by this file was the bystander, now aborted');

select * from finish();
