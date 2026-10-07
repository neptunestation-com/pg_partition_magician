-- archive.s3_signed_request and archive.s3_signed_request_bytea stamp x-amz-date, and the credential
-- scope's date, from the clock they read when they sign. It used to be now(), which in PostgreSQL is
-- the TRANSACTION start time, so every request a transaction made carried the same stamp, and S3 and
-- MinIO refuse a request whose x-amz-date is more than 15 minutes from their own clock (HTTP 403
-- RequestTimeTooSkewed). archive.to_s3 holds one transaction for a whole multipart export and a
-- pgpm.maintain() tick holds one for every chunk pgpm._archive_step archives, so an export or a tick
-- that ran past 15 minutes had every later request refused (issue #520). The signature has to be
-- stamped with clock_timestamp(), the wall clock.
--
-- Fifteen minutes is the skew S3 tolerates, and the issue's reproduction ages a real transaction past
-- it. This file proves the same thing in two seconds by looking at the stamp itself rather than at
-- MinIO's verdict on it. A recording stand-in for the http extension's http(http_request) is put in
-- the place of the module's transport, archive._s3_send (the one place every request goes through, #984);
-- both signers are called at the start of one transaction and again after a pg_sleep; and the
-- late stamps must lie between wall-clock readings taken around the late calls AND be strictly later
-- than the transaction-start stamp. Read from now(), a late stamp IS the start stamp, so the second
-- assertion of each pair fails against the defect and the first pins down which clock was read
-- instead. The last two assertions take the stand-in out of the way and sign for real against MinIO,
-- so it is known to be out of the way of everything else the archive track exercises.
select plan(14);

create schema t17;
create table t17.req (
  n        int primary key generated always as identity,
  uri      text,
  amz_date text,
  auth     text
);

-- The stand-in: same signature as public.http(http_request); records what the signer sent, answers 200.
create function t17.http(r http_request) returns http_response language plpgsql as $$
declare h http_header; v_date text; v_auth text;
begin
  foreach h in array r.headers loop
    if lower(h.field) = 'x-amz-date' then v_date := h.value; end if;
    if lower(h.field) = 'authorization' then v_auth := h.value; end if;
  end loop;
  insert into t17.req (uri, amz_date, auth) values (r.uri, v_date, v_auth);
  return row(200, 'text/plain', array[]::http_header[], '')::http_response;
end $$;

-- one call to each signer, keyed by label so the recorded requests can be told apart by identity
create function t17.sign(p_label text) returns void language plpgsql as $$
begin
  perform archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
    't17/' || p_label || '.txt', '', 'text/plain', p_label, 'minioadmin', 'minioadmin');
  perform archive.s3_signed_request_bytea('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
    't17/' || p_label || '.bin', '', 'application/octet-stream', convert_to(p_label, 'UTF8'), 'minioadmin', 'minioadmin');
end $$;

-- a reading of a clock in the signer's own x-amz-date form: fixed width, so string order is time order
create function t17.stamp(p_at timestamptz) returns text language sql stable as $$
  select to_char(p_at at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"')
$$;

create table t17.marks (k text primary key, v text not null);

-- The stand-in takes the place of the module's transport, archive._s3_send, while t17.standin is on
-- (#984: the signers reach the http extension only through it, never through search_path).
select mk_transport_standin('t17');

set t17.standin = on;

select is(current_setting('t17.standin'), 'on',
  'LIVENESS: the module''s transport routes to the recording stand-in while t17.standin is on');

-- One transaction, so now() is frozen across all four requests while the wall clock moves.
begin;
select ok(now() = transaction_timestamp(), 'LIVENESS: now() is this transaction''s start time');
insert into t17.marks values ('start', t17.stamp(now()));
select t17.sign('early');
select pg_sleep(2.1);
select ok(clock_timestamp() - now() >= interval '2 seconds',
  'LIVENESS: the wall clock is at least 2 s past the transaction start when the late requests are signed');
insert into t17.marks values ('before_late', t17.stamp(clock_timestamp()));
select t17.sign('late');
insert into t17.marks values ('after_late', t17.stamp(clock_timestamp()));
commit;

set t17.standin = off;

-- --- What the stand-in saw ---------------------------------------------------------------------

select is(
  (select array_agg(uri order by n) from t17.req),
  array['http://minio:9000/archive-test-bucket/t17/early.txt', 'http://minio:9000/archive-test-bucket/t17/early.bin',
        'http://minio:9000/archive-test-bucket/t17/late.txt',  'http://minio:9000/archive-test-bucket/t17/late.bin'],
  'LIVENESS: the stand-in received the four requests in order: early text, early bytea, late text, late bytea');

select is(
  (select array_agg(n order by n) from t17.req
    where amz_date ~ '^[0-9]{8}T[0-9]{6}Z$' and auth like 'AWS4-HMAC-SHA256 Credential=minioadmin/%'),
  array[1, 2, 3, 4],
  'LIVENESS: all four carry a well-formed x-amz-date and a SigV4 authorization header');

-- --- THE DEFECT: the late stamps -----------------------------------------------------------------

-- archive.s3_signed_request (text payload)
select ok(
  (select amz_date >= (select v from t17.marks where k = 'before_late')
      and amz_date <= (select v from t17.marks where k = 'after_late')
     from t17.req where uri like '%/t17/late.txt'),
  'archive.s3_signed_request stamps x-amz-date from the wall clock: the late stamp lies between the readings taken around the call');

select cmp_ok(
  (select amz_date from t17.req where uri like '%/t17/late.txt'), '>',
  (select v from t17.marks where k = 'start'),
  'and that stamp is later than the transaction start: it was not read from now()');

select is(
  (select substring(auth from 'Credential=minioadmin/([0-9]{8})/') from t17.req where uri like '%/t17/late.txt'),
  (select left(amz_date, 8) from t17.req where uri like '%/t17/late.txt'),
  'its credential scope carries the date of that same stamp');

-- archive.s3_signed_request_bytea (bytea payload)
select ok(
  (select amz_date >= (select v from t17.marks where k = 'before_late')
      and amz_date <= (select v from t17.marks where k = 'after_late')
     from t17.req where uri like '%/t17/late.bin'),
  'archive.s3_signed_request_bytea stamps x-amz-date from the wall clock: the late stamp lies between the readings taken around the call');

select cmp_ok(
  (select amz_date from t17.req where uri like '%/t17/late.bin'), '>',
  (select v from t17.marks where k = 'start'),
  'and that stamp is later than the transaction start: it was not read from now()');

select is(
  (select substring(auth from 'Credential=minioadmin/([0-9]{8})/') from t17.req where uri like '%/t17/late.bin'),
  (select left(amz_date, 8) from t17.req where uri like '%/t17/late.bin'),
  'its credential scope carries the date of that same stamp');

-- the early stamps are what a fresh transaction's now() and clock_timestamp() agree on, to the second
-- boundary, so a stand-in that recorded garbage would have shown up here rather than in a bracket above
select ok(
  (select bool_and(amz_date >= (select v from t17.marks where k = 'start')
               and amz_date <= (select v from t17.marks where k = 'before_late'))
     from t17.req where uri like '%/t17/early.%'),
  'LIVENESS: both early stamps lie between the transaction start and the pre-sleep reading, so the stand-in recorded real stamps');

-- --- Control: the stand-in is out of the way and the real signer still satisfies MinIO -------------

select is(
  (select status from archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
      't17/control.txt', '', 'text/plain', 'control', 'minioadmin', 'minioadmin')),
  200, 'control: signed for real with the wall clock, MinIO accepts the request');

select is((select count(*)::int from t17.req), 4,
  'and that request reached MinIO, not the stand-in: it still holds only the four it recorded');

select * from finish();
