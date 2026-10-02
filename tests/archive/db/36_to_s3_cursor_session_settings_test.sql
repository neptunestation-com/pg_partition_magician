-- archive.to_s3 pages a partition by its total order (control, ctid) and carries the control half of
-- the keyset cursor from one page's query to the next. It used to carry it as `k::text`, rendered in the
-- calling session's DateStyle and TimeZone, and read it back with `$1::<type>` in that same session.
-- Under a non-ISO DateStyle a timestamptz renders its zone by ABBREVIATION, and not every abbreviation
-- reads back as the zone that wrote it. In Asia/Shanghai under DateStyle Postgres, 00:00Z renders as
-- `Mon Jan 01 08:00:00 2024 CST` and PostgreSQL 17 and older read CST as US Central (-06), 14:00Z: the
-- cursor jumped 14 hours, the next page skipped every row in between, and the conservation check (#673)
-- refused every multi-page export as "a write changed the partition" with nothing writing (issue #834).
-- In Pacific/Guam the render's `ChST` does not parse at all, on every supported version, so the second
-- page's query raised instead. The cursor is now rendered through archive._cursor_text, which pins
-- TimeZone and DateStyle the way archive._object_stem does (#551), so the text it carries reads back as
-- the same value in any session.
--
-- The contract: a multi-page to_s3 export holds every row of the partition, once, in order, whatever
-- the session's DateStyle and TimeZone. The fixture is asymmetric so the Shanghai skip names itself:
-- four rows, three an hour apart and one 20 hours in, one row per page. The misread cursor lands at
-- 14:00Z after row 1, so it pages {1, 4} and skips {2, 3}; a correct export pages {1, 2, 3, 4}. The
-- witnesses pin the conditions: each session really does fail to read its own render back (the defect's
-- mechanism), the export really is multi-page, and the same export from an ISO session succeeds (so the
-- environment, MinIO and the credentials work, and a failure above is the session's doing). PostgreSQL
-- 18 resolves the session zone's own abbreviations first, so there CST reads back as Shanghai's and that
-- one witness is skipped; Guam's is not, which is why the file exports from both. Each object's key is
-- cleared and witnessed absent first, because the bucket outlives the test database.
select plan(16);

create schema t36;
create table t36.ev (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into t36.ev values
  (1, '2024-01-01 00:00:00+00'), (2, '2024-01-01 01:00:00+00'),
  (3, '2024-01-01 02:00:00+00'), (4, '2024-01-01 20:00:00+00');
call pgpm.transmute('t36.ev', 'ts', interval '1 day', p_anchor => '2000-01-01 00:00:00+00');
select current_database() || '-t36/' as p \gset
select archive.configure('t36.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p',
                         p_fetch_rows => 1);
select p.child_name as child from pgpm.part p
 where p.parent_table = 't36.ev'::regclass and p.lo::timestamptz = '2024-01-01 00:00:00+00' \gset
select :'p' || 't36.' || :'child' || '.ndjson' as k \gset

create function t36.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- DELETE the key and report the GET status after it: 404 means the export below starts from nothing.
create function t36.clear(p_key text) returns int language sql as $$
  select (t36.req('DELETE', p_key)).status * 0 + (t36.req('GET', p_key)).status $$;
-- the ids an NDJSON object holds, in the object's line order; null when there is no object at the key
create function t36.ids(p_key text) returns bigint[] language plpgsql as $$
declare v http_response := t36.req('GET', p_key); r bigint[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg((l::jsonb ->> 'id')::bigint order by n) into r
    from regexp_split_to_table(v.content, e'\n') with ordinality as s(l, n) where l <> '';
  return r;
end $$;
-- every line's instant, read back from the object, in line order
create function t36.instants(p_key text) returns timestamptz[] language plpgsql as $$
declare v http_response := t36.req('GET', p_key); r timestamptz[];
begin
  if v.status <> 200 then return null; end if;
  select array_agg((l::jsonb ->> 'ts')::timestamptz order by n) into r
    from regexp_split_to_table(v.content, e'\n') with ordinality as s(l, n) where l <> '';
  return r;
end $$;
-- how far a row's control value moves when this session renders it and reads the text back, or the
-- error reading it back raises
create function t36.round_trip(p_id bigint) returns text language plpgsql as $$
declare v timestamptz;
begin
  select ts into v from t36.ev where id = p_id;
  return (v::text::timestamptz - v)::text;
exception when others then return sqlerrm;
end $$;
-- runs archive.to_s3 over the partition and reports 'ok' or the error it raised
create function t36.try_export(p_child name) returns text language plpgsql as $$
begin
  perform archive.to_s3('t36.ev', p_child, '2024-01-01 00:00:00+00', '2024-01-02 00:00:00+00');
  return 'ok';
exception when others then return sqlerrm;
end $$;

-- 1-3. The fixture: the four rows sit in the one partition, and a page is one row, so the export is
-- four pages and three cursor round trips.
select is((select array_agg(id order by id) from t36.ev
            where tableoid = (select child_oid from pgpm.part where parent_table = 't36.ev'::regclass and child_name = :'child')),
  array[1, 2, 3, 4]::bigint[], 'LIVENESS: the 2024-01-01 partition holds rows 1, 2, 3 and 4');
select is((select array_agg(id order by id) from only t36.ev), null::bigint[],
  'LIVENESS: the parent holds no rows of its own');
select is((select fetch_rows from archive.config where parent_table = 't36.ev'::regclass), 1,
  'LIVENESS: a page is one row, so exporting the partition crosses three page boundaries');

-- 4-8. Asia/Shanghai, DateStyle Postgres: the issue's session.
set timezone = 'Asia/Shanghai';
set datestyle = 'Postgres, MDY';
select is((select ts::text from t36.ev where id = 1), 'Mon Jan 01 08:00:00 2024 CST',
  'LIVENESS: in the Shanghai session row 1''s control value renders with the zone abbreviation CST');
select case when current_setting('server_version_num')::int >= 180000
  then skip('PostgreSQL 18 reads a session zone''s own abbreviation as that zone, so CST reads back as Shanghai''s', 1)
  else is(t36.round_trip(1), '14:00:00',
    'LIVENESS: that text reads back 14 hours later than the value it rendered (CST read as -06), past rows 2 and 3')
  end;
select is(t36.clear(:'k'), 404, 'LIVENESS: no object at the key before the Shanghai export');
select is(t36.try_export(:'child'), 'ok',
  'archive.to_s3 of the partition succeeds from a DateStyle=Postgres, TimeZone=Asia/Shanghai session with nothing writing to it');
select is(t36.ids(:'k'), array[1, 2, 3, 4]::bigint[],
  'the object holds rows 1, 2, 3 and 4, each once, in control order (the misread cursor paged 1 and 4 and skipped 2 and 3)');

-- 9-13. Pacific/Guam, DateStyle Postgres: a render that does not parse back on any version.
set timezone = 'Pacific/Guam';
select is(t36.round_trip(1), 'invalid input syntax for type timestamp with time zone: "Mon Jan 01 10:00:00 2024 ChST"',
  'LIVENESS: in the Guam session row 1''s control value renders as text that does not read back at all');
select is(t36.clear(:'k'), 404, 'LIVENESS: no object at the key before the Guam export');
select is(t36.try_export(:'child'), 'ok',
  'archive.to_s3 of the partition succeeds from a DateStyle=Postgres, TimeZone=Pacific/Guam session');
select is(t36.ids(:'k'), array[1, 2, 3, 4]::bigint[], 'the object holds rows 1, 2, 3 and 4, each once, in control order');
select is(t36.instants(:'k'), (select array_agg(ts order by ts) from t36.ev),
  'each line carries its row''s own instant');

reset timezone;
reset datestyle;

-- 14-16. The same export from an ISO session: the environment works, and the object is the same rows.
select is(current_setting('datestyle'), 'ISO, MDY', 'LIVENESS: the session is back on ISO, the DateStyle the defect does not reach');
select is(t36.clear(:'k'), 404, 'LIVENESS: no object at the key before the ISO export');
select is(t36.try_export(:'child') || ':' || coalesce(t36.ids(:'k')::text, 'none'), 'ok:{1,2,3,4}',
  'LIVENESS: from an ISO session the same export succeeds and its object holds rows 1, 2, 3 and 4');

select * from finish();
