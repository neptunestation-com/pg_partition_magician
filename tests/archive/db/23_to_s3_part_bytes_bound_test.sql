-- archive.configure stored p_part_bytes without a lower bound, and archive.to_s3 read it as the size
-- of each multipart part. With part_bytes <= 0 the read loop (`while octet_length(payload) <
-- part_bytes`) is false at once, so the export never read a row: it initiated a multipart upload and
-- PUT empty parts, 10000 of them, until the store refused part 10001, all inside the caller's
-- transaction (issue #594). The knob is now refused where it is set, by archive.configure, and a row
-- that holds such a value anyway (written before the bound existed, or by a raw UPDATE) is refused by
-- archive.to_s3 before it sends anything.
--
-- "Sends nothing" is a negative, and a counter that never counted anything would satisfy it too. So a
-- counting stand-in for the http extension's http(http_request) is put in the place of the module's
-- transport, archive._s3_send (the one place every request goes through, #984), the refusal is required to leave its counter at 0,
-- and the SAME stand-in, the same child and the same counter are then required to see exactly one
-- request, the single PUT of the right key, once part_bytes is positive again. The counter is a
-- sequence because a refused call rolls back everything else it wrote.
--
-- Fixtures are asymmetric: the refused configure calls pass a prefix of their own, so a refusal that
-- wrote its row anyway would show up as a changed prefix and not only as a changed number.
select plan(13);

create schema t23;
create sequence t23.sent;
create table t23.req (n int primary key generated always as identity, method text, uri text);

-- The stand-in: same signature as public.http(http_request). Counts non-transactionally, records the
-- request, answers 200 with no body.
create function t23.http(r http_request) returns http_response language plpgsql as $$
begin
  perform nextval('t23.sent');
  insert into t23.req (method, uri) values (r.method::text, r.uri);
  return row(200, 'text/plain', array[]::http_header[], '')::http_response;
end $$;

create function t23.sent() returns bigint language sql as $$
  select case when is_called then last_value else 0 end from t23.sent
$$;

call mk_archive_table('pb23', 30, 10000, null, true);
select child_name as child from pgpm.part where parent_table = 'public.pb23'::regclass order by lo::numeric limit 1 \gset

select is((select array_agg(id order by id) from public.pb23 where tableoid = to_regclass('public.' || :'child')),
  (select array_agg(g::bigint order by g) from generate_series(1, 30) g),
  'LIVENESS: the child to export holds ids 1..30');

select mk_archive_config('pb23');
select is((select (part_bytes, prefix)::text from archive.config where parent_table = 'public.pb23'::regclass),
  '(8388608,pb23/)',
  'LIVENESS: the table is configured with the default part_bytes and its own prefix');

-- --- archive.configure refuses the knob -----------------------------------------------------------

select throws_like(
  $$ select archive.configure('public.pb23', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_part_bytes => 0) $$,
  'archive.configure: p_part_bytes must be a positive number of bytes, not 0%',
  'archive.configure refuses p_part_bytes => 0');

select throws_like(
  $$ select archive.configure('public.pb23', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'refused/', p_part_bytes => -1) $$,
  'archive.configure: p_part_bytes must be a positive number of bytes, not -1%',
  'archive.configure refuses a negative p_part_bytes');

select is((select (part_bytes, prefix)::text from archive.config where parent_table = 'public.pb23'::regclass),
  '(8388608,pb23/)',
  'the refusals wrote nothing: the row keeps its part_bytes AND its prefix');

-- The smallest size configure accepts is 5 MiB, S3's minimum non-final multipart part (#636, whose
-- own file, tests/archive/db/28, asserts the sizes between 1 byte and 5 MiB are refused).
select lives_ok(
  $$ select archive.configure('public.pb23', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                              p_prefix => 'pb23/', p_part_bytes => 5242880) $$,
  'LIVENESS: the smallest part size the store accepts, 5 MiB, is accepted');

select is((select part_bytes from archive.config where parent_table = 'public.pb23'::regclass), 5242880::bigint,
  'LIVENESS: and stored, so the refusals above are a bound and not a refusal of every value');

-- --- archive.to_s3 refuses a row that holds one anyway, before it sends anything ------------------

update archive.config set part_bytes = 0 where parent_table = 'public.pb23'::regclass;

-- The stand-in takes the place of the module's transport, archive._s3_send, while t23.standin is on
-- (#984: the signers reach the http extension only through it, never through search_path).
select mk_transport_standin('t23');

set t23.standin = on;

select is(current_setting('t23.standin'), 'on',
  'LIVENESS: the module''s transport routes to the counting stand-in while t23.standin is on');

select throws_like(
  format($$ select archive.to_s3('public.pb23', %L, '0', '10000') $$, :'child'),
  'archive.to_s3: %pb23 has archive.config.part_bytes 0; it must be a positive number of bytes%',
  'archive.to_s3 refuses part_bytes = 0 in the row');

select is(t23.sent(), 0::bigint,
  'and sends nothing: no initiate, no part, no PUT reached the transport');

update archive.config set part_bytes = 8 * 1024 * 1024 where parent_table = 'public.pb23'::regclass;
select t23.sent() as sent_before \gset
delete from t23.req;

select lives_ok(
  format($$ select archive.to_s3('public.pb23', %L, '0', '10000') $$, :'child'),
  'LIVENESS: the same export succeeds once part_bytes is positive again');

select is(t23.sent() - :sent_before, 1::bigint,
  'LIVENESS: the same counter saw that export''s one request, so a 0 above was a refusal and not a dead counter');

select is((select array_agg(method || ' ' || uri order by n) from t23.req),
  array['PUT http://minio:9000/archive-test-bucket/pb23/public.' || :'child' || '.ndjson'],
  'LIVENESS: and that request is the single PUT of this child''s key');

set t23.standin = off;

select * from finish();
