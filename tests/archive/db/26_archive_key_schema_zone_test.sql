-- The archive_fn transports named an uploaded object <prefix><p_parent::text>_<stem>.<ext> (issue #551),
-- and two parts of that name were rendered by the CALLING SESSION rather than by identity:
--
--   * p_parent::text is regclass output, which leaves the schema out whenever the session's search_path
--     reaches the parent. Two parents named `evt` in schemas t26a and t26b, sharing a prefix (the default
--     one, `events/`, is shared by every table archive.configure sets up), each ticked from a session
--     whose search_path shows its own schema, both wrote <prefix>evt_0.ndjson: the second PUT overwrote
--     the first, both ledger rows recorded the key as archived, and retire() dropped t26a's partition
--     with its rows gone from the store.
--   * a time kind's stem was the digits of the native lo text as the session rendered it, zone offset
--     included and its SIGN dropped. 2024-01-01 00:00Z rendered in Asia/Karachi (05:00:00+05) and
--     2024-01-01 10:00Z rendered in America/Bogota (05:00:00-05) are two different chunks with one stem,
--     2024010105000005, so the second overwrote the first while each call reported its chunk covered.
--
-- Now the key names the parent as quote_ident(schema) || '.' || quote_ident(table), whatever the path, and
-- a time stem is the digits of the lo rendered in UTC, whatever the zone. Both are asserted as EXACT keys
-- (identity, not merely "the two differ"), from sessions chosen so that the old rendering would differ.
--
-- Fixtures are asymmetric so that a clobbered object cannot pass an identity check: 20 rows against 3 in
-- the two `evt` tables and in the two `pq` tables, 3 rows against 1 in the two time chunks. Every
-- candidate key (the shared legacy one and each new one) is cleared and witnessed absent first, because
-- the bucket outlives a test database; the prefix carries current_database() so a concurrent run of this
-- file elsewhere cannot share a key with this one.
select plan(36);

create schema t26;

create function t26.status(p_parent regclass, p_method text, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  return (archive.s3_signed_request(p_method, cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '',
                                    v_key_id, v_secret)).status;
end;
$$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t26.clear(p_parent regclass, p_key text) returns int
language plpgsql as $$
begin
  perform t26.status(p_parent, 'DELETE', p_key);
  return t26.status(p_parent, 'GET', p_key);
end;
$$;

-- The ids an NDJSON object holds, in order (null when there is no object): identity, not a count.
create function t26.ids(p_parent regclass, p_key text) returns bigint[]
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then return null; end if;
  return (select array_agg((l::jsonb ->> 'id')::bigint order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v_resp.content, e'\n') l where l <> '');
end;
$$;

-- An object's byte length (null when there is none); text_to_bytea undoes the extension's reinterpretation
-- of the body, as in tests/archive/db/16, so a Parquet object's length is its real one.
create function t26.bytes(p_parent regclass, p_key text) returns int
language plpgsql as $$
declare cfg archive.config; v_key_id text; v_secret text; v_resp http_response;
begin
  select * into cfg from archive.config where parent_table = p_parent;
  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = cfg.vault_key_id;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = cfg.vault_secret;
  v_resp := archive.s3_signed_request('GET', cfg.endpoint, cfg.bucket, cfg.region, p_key, '', 'text/plain', '', v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then return null; end if;
  return octet_length(text_to_bytea(v_resp.content));
end;
$$;

select current_database() || '/t26/' as p \gset

-- ======================= PART A: same-named parents in two schemas, NDJSON =======================

create schema t26a;
create schema t26b;
create table t26a.evt (id bigint primary key, payload text);
create table t26b.evt (id bigint primary key, payload text);
insert into t26a.evt select g, 'a' from generate_series(1, 20) g;
insert into t26b.evt select g, 'b' from generate_series(1, 3) g;
call pgpm.transmute('t26a.evt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
call pgpm.transmute('t26b.evt', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t26a.evt values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged in both
insert into t26b.evt values (45000, 'frontier');
select archive.configure('t26a.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('t26b.evt', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t26a.evt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('t26b.evt', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);

select is((select array_agg(id order by id) from t26a.evt where id < 10000),
          (select array_agg(g::bigint) from generate_series(1, 20) g),
  'LIVENESS: t26a.evt holds exactly ids 1..20 in [0, 10000)');
select is((select array_agg(id order by id) from t26b.evt where id < 10000), array[1, 2, 3]::bigint[],
  'LIVENESS: t26b.evt holds exactly ids 1..3 in [0, 10000)');
select is(t26.clear('t26a.evt', :'p' || 'evt_0.ndjson'), 404, 'LIVENESS: no object at the shared legacy key <prefix>evt_0.ndjson');
select is(t26.clear('t26a.evt', :'p' || 't26a.evt_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t26a.evt_0.ndjson');
select is(t26.clear('t26b.evt', :'p' || 't26b.evt_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t26b.evt_0.ndjson');

-- each tenant's tick runs under its own search_path, where regclass::text renders the parent as bare `evt`
set search_path = t26a, public;
select is('t26a.evt'::regclass::text, 'evt', 'LIVENESS: under t26a''s search_path the parent renders unqualified');
call pgpm.maintain('t26a.evt');
set search_path = t26b, public;
select is('t26b.evt'::regclass::text, 'evt', 'LIVENESS: under t26b''s search_path the parent renders unqualified');
call pgpm.maintain('t26b.evt');
reset search_path;

select is((select rows_archived from pgpm.archive_ledger where parent_table = 't26a.evt'::regclass and lo = '0'), 20::bigint,
  'LIVENESS: t26a''s tick archived its 20 rows in [0, 10000)');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 't26b.evt'::regclass and lo = '0'), 3::bigint,
  'LIVENESS: t26b''s tick archived its 3 rows in [0, 10000)');
select is((select array_agg(id order by id) from t26a.evt where id < 10000), null::bigint[],
  'LIVENESS: retire() dropped t26a''s [0, 10000), so the object is the only copy of ids 1..20');

select is((select s3_key from pgpm.archive_ledger where parent_table = 't26a.evt'::regclass and lo = '0'),
          :'p' || 't26a.evt_0.ndjson',
  'the ndjson key names t26a.evt schema-qualified although the ticking session''s search_path reached it');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't26b.evt'::regclass and lo = '0'),
          :'p' || 't26b.evt_0.ndjson',
  'the ndjson key names t26b.evt schema-qualified although the ticking session''s search_path reached it');
select is(t26.ids('t26a.evt', (select s3_key from pgpm.archive_ledger where parent_table = 't26a.evt'::regclass and lo = '0')),
          (select array_agg(g::bigint) from generate_series(1, 20) g),
  'the object t26a''s ledger row names holds exactly t26a''s ids 1..20');
select is(t26.ids('t26b.evt', (select s3_key from pgpm.archive_ledger where parent_table = 't26b.evt'::regclass and lo = '0')),
          array[1, 2, 3]::bigint[],
  'the object t26b''s ledger row names holds exactly t26b''s ids 1..3');
select is(t26.status('t26a.evt', 'GET', :'p' || 'evt_0.ndjson'), 404,
  'nothing was written at the shared, search_path-relative key <prefix>evt_0.ndjson');

-- ======================= PART B: same-named parents in two schemas, Parquet =======================

create table t26a.pq (id bigint primary key, payload text);
create table t26b.pq (id bigint primary key, payload text);
insert into t26a.pq select g, repeat('a', 40) from generate_series(1, 20) g;
insert into t26b.pq select g, repeat('b', 40) from generate_series(1, 3) g;
call pgpm.transmute('t26a.pq', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
call pgpm.transmute('t26b.pq', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t26a.pq values (45000, 'frontier');
insert into t26b.pq values (45000, 'frontier');
select archive.configure('t26a.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select archive.configure('t26b.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t26a.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select pgpm.set_archive_fn('t26b.pq', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);

select is(t26.clear('t26a.pq', :'p' || 'pq_0.parquet'), 404, 'LIVENESS: no object at the shared legacy key <prefix>pq_0.parquet');
select is(t26.clear('t26a.pq', :'p' || 't26a.pq_0.parquet'), 404, 'LIVENESS: no object at <prefix>t26a.pq_0.parquet');
select is(t26.clear('t26b.pq', :'p' || 't26b.pq_0.parquet'), 404, 'LIVENESS: no object at <prefix>t26b.pq_0.parquet');

set search_path = t26a, public;
call pgpm.maintain('t26a.pq');
set search_path = t26b, public;
call pgpm.maintain('t26b.pq');
reset search_path;

select is((select array_agg(parent_table::text || ':' || rows_archived order by parent_table::text) from pgpm.archive_ledger
            where lo = '0' and parent_table in ('t26a.pq'::regclass, 't26b.pq'::regclass)),
          array['t26a.pq:20', 't26b.pq:3'],
  'LIVENESS: each Parquet tick recorded its own [0, 10000) with its own row count');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't26a.pq'::regclass and lo = '0'),
          :'p' || 't26a.pq_0.parquet',
  'the parquet key names t26a.pq schema-qualified');
select is((select s3_key from pgpm.archive_ledger where parent_table = 't26b.pq'::regclass and lo = '0'),
          :'p' || 't26b.pq_0.parquet',
  'the parquet key names t26b.pq schema-qualified');
select ok(t26.bytes('t26a.pq', :'p' || 't26a.pq_0.parquet') > t26.bytes('t26b.pq', :'p' || 't26b.pq_0.parquet'),
  'the t26a object is the larger, 20-row file, not the 3-row file that used to share its key');
select is(t26.status('t26a.pq', 'GET', :'p' || 'pq_0.parquet'), 404,
  'nothing was written at the shared, search_path-relative key <prefix>pq_0.parquet');

-- ======================= PART C: a time kind's stem does not depend on the session's zone ==================

set timezone = 'UTC';
create table public.t26tz (ts timestamptz not null, id int not null, payload text, primary key (ts, id));
insert into public.t26tz values
  ('2024-01-01 00:10:00+00', 1, 'a'), ('2024-01-01 00:20:00+00', 2, 'a'), ('2024-01-01 00:30:00+00', 3, 'a'),
  ('2024-01-01 10:30:00+00', 4, 'b');
call pgpm.transmute('public.t26tz', 'ts', interval '1 hour');
select archive.configure('public.t26tz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select child_name as child from pgpm.part where parent_table = 'public.t26tz'::regclass order by lo::timestamptz limit 1 \gset

-- chunk A [00:00Z, 01:00Z) as a session in Asia/Karachi renders it, chunk B [10:00Z, 11:00Z) as one in
-- America/Bogota does: the two lo texts whose digits used to coincide
set timezone = 'Asia/Karachi';
select pgpm._ts_text('2024-01-01 00:00:00+00') as a_lo, pgpm._ts_text('2024-01-01 01:00:00+00') as a_hi \gset
set timezone = 'America/Bogota';
select pgpm._ts_text('2024-01-01 10:00:00+00') as b_lo, pgpm._ts_text('2024-01-01 11:00:00+00') as b_hi \gset
set timezone = 'UTC';

select is(regexp_replace(:'a_lo', '[^0-9]', '', 'g'), regexp_replace(:'b_lo', '[^0-9]', '', 'g'),
  'LIVENESS: the two chunks'' lo texts, ' || :'a_lo' || ' and ' || :'b_lo' || ', have the same digits');
select is((select array_agg(id order by id) from public.t26tz where ts >= :'a_lo' and ts < :'a_hi'), array[1, 2, 3],
  'LIVENESS: chunk A holds ids 1, 2, 3');
select is((select array_agg(id order by id) from public.t26tz where ts >= :'b_lo' and ts < :'b_hi'), array[4],
  'LIVENESS: chunk B holds id 4');
select is(t26.clear('public.t26tz', :'p' || 'public.t26tz_2024010100000000.ndjson'), 404,
  'LIVENESS: no object at chunk A''s UTC key');
select is(t26.clear('public.t26tz', :'p' || 'public.t26tz_2024010110000000.ndjson'), 404,
  'LIVENESS: no object at chunk B''s UTC key');
select is(t26.clear('public.t26tz', :'p' || 't26tz_2024010105000005.ndjson'), 404,
  'LIVENESS: no object at the key the two chunks used to share');

-- each chunk archived from a session in the zone that rendered its lo, A first, then B
set timezone = 'Asia/Karachi';
create temp table t26_a as select (r).* from (select pgpm.archive_to_s3_ndjson('public.t26tz', :'child', :'a_lo', :'a_hi') r) s;
set timezone = 'America/Bogota';
create temp table t26_b as select (r).* from (select pgpm.archive_to_s3_ndjson('public.t26tz', :'child', :'b_lo', :'b_hi') r) s;
-- and chunk A once more, from a UTC session with its lo in UTC text: the same chunk, the same object
set timezone = 'UTC';
create temp table t26_a2 as select (r).* from (select pgpm.archive_to_s3_ndjson('public.t26tz', :'child',
  pgpm._ts_text('2024-01-01 00:00:00+00'), pgpm._ts_text('2024-01-01 01:00:00+00')) r) s;

select is((select array[a.rows_archived, b.rows_archived] from t26_a a, t26_b b), array[3, 1]::bigint[],
  'LIVENESS: the strategy archived 3 rows for chunk A and 1 for chunk B');
select is((select s3_key from t26_a), :'p' || 'public.t26tz_2024010100000000.ndjson',
  'chunk A, archived from Asia/Karachi, is keyed by its lo in UTC');
select is((select s3_key from t26_b), :'p' || 'public.t26tz_2024010110000000.ndjson',
  'chunk B, archived from America/Bogota, is keyed by its lo in UTC');
select is((select s3_key from t26_a2), (select s3_key from t26_a),
  'chunk A archived again from a UTC session lands on the same key as from Asia/Karachi');
select is(t26.ids('public.t26tz', (select s3_key from t26_a)), array[1, 2, 3]::bigint[],
  'chunk A''s object still holds ids 1, 2, 3 after chunk B was archived');
select is(t26.ids('public.t26tz', (select s3_key from t26_b)), array[4]::bigint[],
  'chunk B''s object holds id 4');
select is(t26.status('public.t26tz', 'GET', :'p' || 't26tz_2024010105000005.ndjson'), 404,
  'nothing was written at the session-rendered key the two chunks used to share');

select * from finish();
