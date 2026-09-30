-- archive.to_s3's conservation check compares WHICH rows it paged, not how many (issue #673).
--
-- to_s3 pages a partition by (control, ctid) across many statements, each in its own READ COMMITTED
-- snapshot, and refuses to complete an object whose rows do not match the partition's. It used to
-- compare a row COUNT taken as the export began, and one concurrent UPDATE that moves a row not yet paged
-- behind the cursor (-1) and a paged row ahead of it (+1) keeps the count: the export completed and the
-- object held the first row in neither its old nor its new form, a row the partition held before and
-- after the export. The check now sums a 64-bit hash of every exported line alongside the count and
-- compares both with the partition as it stands after the last page.
--
-- HOW THE RACE IS BUILT, the pattern tests/archive/db/15 established. The export runs in a second
-- session (dblink, asynchronously) through a wrapper that records its own start and end and hands the
-- refusal back as a value instead of an error, so this session is free to commit the UPDATE while the
-- export runs and to bracket that commit with clock readings of its own. The UPDATE is timed at 40% of
-- a calibrated quiescent export of the same partition. Pages go in id order, 10 rows each, so row B
-- (id 1) is in the first page and row A (the last id) in the last one: an UPDATE anywhere in between
-- is the compensating shape the count could not see. The fixed code refuses wherever it lands after
-- the first page.
--
-- WHAT IS ASSERTED. Part A is the positive half: a quiescent export completes and its object holds
-- exactly the partition's rows by identity, so the new check refuses nothing it should not. Part B is
-- the race: the export refuses, its message naming EQUAL counts (a count check could not have refused),
-- and no object lands at the key. Every negative is paired with its witness: the UPDATE committed
-- strictly inside the export's window, both rows moved in the partition, and the key was empty before
-- the export. bench/archive_to_s3_conservation.sh runs this file against the count-only mutant
-- (bench/mutations/mutate.py: to_s3_conservation_by_count).
select plan(9);

create extension if not exists dblink;

create schema t25;

-- 50000 rows with odd ids 1..99999, so an UPDATE can move a row onto an even id the partition does not
-- hold; one partition, [0, 1000000), holds them all and the ids 100001 above too.
create table public.t25_u (id bigint primary key, payload text);
insert into public.t25_u select g, 'row' || g from generate_series(1, 99999, 2) g;
call pgpm.transmute('public.t25_u', 'id', 1000000::bigint);
select archive.configure('public.t25_u', 'archive-test-bucket', p_endpoint => 'http://minio:9000',
                         p_prefix => 't25/', p_fetch_rows => 10);

select c.relname as child from public.t25_u t join pg_class c on c.oid = t.tableoid where t.id = 1 \gset
select lo, hi from pgpm.part where parent_table = 'public.t25_u'::regclass and child_name = :'child' \gset
select 't25/' || :'child' || '.ndjson' as key \gset

-- one signed S3 request against the test bucket, and the object's lines as jsonb
create function t25.s3(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1',
                                   p_key, '', 'text/plain', '', 'minioadmin', 'minioadmin') $$;
create function t25.lines(p_key text) returns setof jsonb language plpgsql as $$
declare r http_response := t25.s3('GET', p_key);
begin
  if r.status not between 200 and 299 then raise exception 'GET % failed: HTTP %', p_key, r.status; end if;
  return query select l::jsonb from regexp_split_to_table(r.content, e'\n') l where l <> '';
end $$;

-- the export under race, run in the second session: its own start and end, and the refusal as a value
create table t25.run (label text primary key, started_at timestamptz, ended_at timestamptz, err text);
create function t25.timed_export(p_child name, p_lo text, p_hi text)
returns table (started_at timestamptz, ended_at timestamptz, err text) language plpgsql as $$
declare s timestamptz; e text;
begin
  s := clock_timestamp();
  begin
    perform archive.to_s3('public.t25_u', p_child, p_lo, p_hi);
  exception when others then e := sqlerrm;
  end;
  return query select s, clock_timestamp(), e;
end $$;

-- ---------------------------------------------------------------------------
-- Part A: a quiescent export completes, and its object is the partition by identity
-- ---------------------------------------------------------------------------

select is((select (t25.s3('DELETE', :'key')).status is not null and (t25.s3('GET', :'key')).status = 404), true,
  'LIVENESS: no object at the key before the quiescent export');

select clock_timestamp() as cal_start \gset
select archive.to_s3('public.t25_u', :'child', :'lo', :'hi');
select round((0.4 * extract(epoch from clock_timestamp() - :'cal_start'::timestamptz))::numeric, 3) as delay \gset

select set_eq(
  format($$ select (doc ->> 'id')::bigint, doc ->> 'payload' from t25.lines(%L) doc $$, :'key'),
  $$ select id, payload from public.t25_u $$,
  'A: the quiescent export completes and its object holds exactly the partition''s rows, by identity');
select is((select count(*)::int from t25.lines(:'key')), 50000,
  'A: 50000 lines, none duplicated');

-- ---------------------------------------------------------------------------
-- Part B: one UPDATE moves a row behind the cursor and another ahead of it, mid-export
-- ---------------------------------------------------------------------------

select is((select (t25.s3('DELETE', :'key')).status is not null and (t25.s3('GET', :'key')).status = 404), true,
  'LIVENESS: the key is empty again before the export under race');

select dblink_connect('t25exp', 'dbname=' || current_database());
select dblink_send_query('t25exp', format('select * from t25.timed_export(%L, %L, %L)', :'child', :'lo', :'hi'));
select pg_sleep(:delay);
select clock_timestamp() as w_lo \gset
-- row A (99999, the last page) to id 2 (behind the cursor), row B (1, the first page) to 100001 (ahead)
update public.t25_u set id = case id when 99999 then 2 when 1 then 100001 end where id in (1, 99999);
select clock_timestamp() as w_hi \gset
insert into t25.run select 'racy', started_at, ended_at, err
  from dblink_get_result('t25exp') as t(started_at timestamptz, ended_at timestamptz, err text);
select dblink_disconnect('t25exp');

select diag(format('B: export ran %s .. %s (%s s); the update committed between %s and %s (delay %s s); err: %s',
  started_at, ended_at, round(extract(epoch from ended_at - started_at)::numeric, 2), :'w_lo', :'w_hi', :delay,
  coalesce(err, '<none, the export completed>')))
  from t25.run where label = 'racy';

select ok((select :'w_lo'::timestamptz > started_at and :'w_hi'::timestamptz < ended_at from t25.run where label = 'racy'),
  'LIVENESS: the update committed strictly inside the export''s window');
select is((select array_agg(id order by id) from public.t25_u where id in (1, 2, 3, 99997, 99999, 100001)),
  array[2, 3, 99997, 100001]::bigint[],
  'LIVENESS: the partition now holds ids 2 and 100001 and not 1 or 99999: both rows moved');
select is((select count(*)::int from public.t25_u), 50000,
  'LIVENESS: the partition still holds 50000 rows, so a count check sees nothing');

select ok((select err from t25.run where label = 'racy') like
  '%archive.to_s3 of public.' || :'child' || ' paged 50000 rows and the partition holds 50000, but not the same rows%refusing to write an incomplete object%',
  'B: the export refuses on equal counts, because the rows it paged are not the partition''s');
select is((t25.s3('GET', :'key')).status, 404,
  'B: and no object landed at the key');

select * from finish();
