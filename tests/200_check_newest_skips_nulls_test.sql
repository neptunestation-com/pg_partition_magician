-- check_uuidv7 and check_text_time report the column's actual maximum however many NULLs it holds (#734).
--
-- newest_decoded is documented as the column's actual maximum, decoded, and newest_in_future as whether
-- that maximum sits more than an hour past now(): the pair exists to show the one future-dated row a
-- passing fraction hides (#457). Both functions read the maximum with ORDER BY col DESC LIMIT 1, and DESC
-- sorts NULLs FIRST, so a single NULL in the column (it is sampled before converting, when the column may
-- still be nullable) became "the maximum": newest_decoded and newest_in_future both came back null while a
-- row five years ahead sat in the table. max() would skip the NULL, but PostgreSQL has no max(uuid) before
-- 18, so the read keeps its index-assisted shape and skips NULLs in its WHERE clause.
--
-- Fixtures, asymmetric on purpose:
--   u_far   uuid: two NULLs, a 2020 row, a 2021 row and one row five years ahead -> the future row, flagged;
--   u_past  uuid: one NULL and two past rows (2022 newest)                       -> 2022, not flagged;
--   u_null  uuid: NULLs only                                                     -> null, null (nothing to decode);
--   t_far   text_time (cuid v1 shape): the same as u_far;
--   t_past  text_time: one NULL and two past rows                                -> 2022, not flagged;
--   t_bad   text_time: one NULL, a 2020 row and a non-null maximum that fails the declared shape -> null
--           (the documented "a maximum that does not match the declared shape reports null"), and not a
--           raise, so the shape check still sees the non-null maximum rather than the NULL.
-- Each expectation is a specific timestamp held in a temp table, not one recomputed the way the function
-- computes it, and every table's NULLs and future row are witnessed before the function is asked about it.
-- bench/check_newest_skips_nulls.sh runs this file against a mutant that puts the NULLS-FIRST read back
-- (check_newest_nulls_first), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(23);

set timezone = 'UTC';

create temp table want (k text primary key, ts timestamptz);
insert into want values
  ('future', date_trunc('milliseconds', now() + interval '5 years')),
  ('y2020', timestamptz '2020-01-01 00:00:00+00'),
  ('y2021', timestamptz '2021-06-01 12:00:00+00'),
  ('y2022', timestamptz '2022-03-04 05:06:07.089+00');

-- cuid v1 shape: 'c', 8 base-36 digits of epoch milliseconds, then anything
create function pg_temp.cuid(p_ts timestamptz, p_tail text) returns text language sql as $$
  select 'c' || pgpm._radix_encode(floor(extract(epoch from p_ts) * 1000), 36, 8) || p_tail
$$;

create table public.u_far (id uuid);
insert into public.u_far values
  (null), (pgpm._ts_to_uuid((select ts from want where k = 'y2020'))),
  (pgpm._ts_to_uuid((select ts from want where k = 'future'))),
  (pgpm._ts_to_uuid((select ts from want where k = 'y2021'))), (null);
create table public.u_past (id uuid);
insert into public.u_past values
  (pgpm._ts_to_uuid((select ts from want where k = 'y2020'))), (null),
  (pgpm._ts_to_uuid((select ts from want where k = 'y2022')));
create table public.u_null (id uuid);
insert into public.u_null values (null), (null), (null);

create table public.t_far (id text collate "C");
insert into public.t_far values
  (null), (pg_temp.cuid((select ts from want where k = 'y2020'), 'abc')),
  (pg_temp.cuid((select ts from want where k = 'future'), 'xyz')),
  (pg_temp.cuid((select ts from want where k = 'y2021'), 'def')), (null);
create table public.t_past (id text collate "C");
insert into public.t_past values
  (pg_temp.cuid((select ts from want where k = 'y2020'), 'abc')), (null),
  (pg_temp.cuid((select ts from want where k = 'y2022'), 'ghi'));
create table public.t_bad (id text collate "C");
insert into public.t_bad values
  (pg_temp.cuid((select ts from want where k = 'y2020'), 'abc')), (null), ('c~~~~~~~~tail');

-- LIVENESS: the NULLs are there, and so is the row each maximum should find
select is((select array[count(*) filter (where id is null), count(*)] from public.u_far), array[2, 5]::bigint[],
  'LIVENESS: u_far holds two NULLs among five rows');
select is((select pgpm._uuid_to_ts(id) from public.u_far where id is not null order by id desc limit 1),
          (select ts from want where k = 'future'),
  'LIVENESS: u_far''s non-null maximum is the row five years ahead');
select is((select array[count(*) filter (where id is null), count(*)] from public.u_past), array[1, 3]::bigint[],
  'LIVENESS: u_past holds one NULL among three rows');
select is((select count(*) filter (where id is not null) from public.u_null), 0::bigint,
  'LIVENESS: u_null holds nothing but NULLs');
select is((select array[count(*) filter (where id is null), count(*)] from public.t_far), array[2, 5]::bigint[],
  'LIVENESS: t_far holds two NULLs among five rows');
select is((select max(id) from public.t_far), pg_temp.cuid((select ts from want where k = 'future'), 'xyz'),
  'LIVENESS: t_far''s non-null maximum is the row five years ahead');
select is((select max(id) from public.t_bad), 'c~~~~~~~~tail',
  'LIVENESS: t_bad''s non-null maximum is the malformed value');
select ok((select fraction > 0 from pgpm.check_uuidv7('public.u_far', 'id'))
          and (select fraction > 0 from pgpm.check_text_time('public.t_far', 'id', 'c', 8, 36, 'ms')),
  'LIVENESS: both functions sampled plausible rows from the tables under test');

-- uuidv7
select is((select newest_decoded from pgpm.check_uuidv7('public.u_far', 'id')),
          (select ts from want where k = 'future'),
  'check_uuidv7: newest_decoded is the future row, not a NULL');
select is((select newest_in_future from pgpm.check_uuidv7('public.u_far', 'id')), true,
  'check_uuidv7: newest_in_future flags it');
select is((select newest from pgpm.check_uuidv7('public.u_far', 'id')),
          (select ts from want where k = 'future'),
  'check_uuidv7: the sample (every row here) agrees on the newest value');
select is((select newest_decoded from pgpm.check_uuidv7('public.u_past', 'id')),
          (select ts from want where k = 'y2022'),
  'check_uuidv7: a past maximum behind a NULL is the 2022 row');
select is((select newest_in_future from pgpm.check_uuidv7('public.u_past', 'id')), false,
  'check_uuidv7: and it is not flagged');
select is((select newest_decoded from pgpm.check_uuidv7('public.u_null', 'id')), null::timestamptz,
  'check_uuidv7: an all-NULL column has no maximum to decode');
select is((select newest_in_future from pgpm.check_uuidv7('public.u_null', 'id')), null::boolean,
  'check_uuidv7: and flags nothing');

-- text_time
select is((select newest_decoded from pgpm.check_text_time('public.t_far', 'id', 'c', 8, 36, 'ms')),
          (select ts from want where k = 'future'),
  'check_text_time: newest_decoded is the future row, not a NULL');
select is((select newest_in_future from pgpm.check_text_time('public.t_far', 'id', 'c', 8, 36, 'ms')), true,
  'check_text_time: newest_in_future flags it');
select is((select newest_decoded from pgpm.check_text_time('public.t_past', 'id', 'c', 8, 36, 'ms')),
          (select ts from want where k = 'y2022'),
  'check_text_time: a past maximum behind a NULL is the 2022 row');
select is((select newest_in_future from pgpm.check_text_time('public.t_past', 'id', 'c', 8, 36, 'ms')), false,
  'check_text_time: and it is not flagged');
select lives_ok($$select * from pgpm.check_text_time('public.t_bad', 'id', 'c', 8, 36, 'ms')$$,
  'check_text_time: a malformed non-null maximum behind a NULL does not raise');
select is((select newest_decoded from pgpm.check_text_time('public.t_bad', 'id', 'c', 8, 36, 'ms')),
          null::timestamptz,
  'check_text_time: and reports null for it');
select is((select array[sampled, plausible] from pgpm.check_text_time('public.t_bad', 'id', 'c', 8, 36, 'ms')),
          array[2, 1]::bigint[],
  'check_text_time: the sample still counts the malformed row as sampled and implausible');

-- a NOT NULL keyed column (the shape transmute converts) reads its maximum exactly as before
create table public.u_key (id uuid primary key);
insert into public.u_key
  select pgpm._ts_to_uuid(timestamptz '2020-01-01 00:00:00+00' + g * interval '1 minute') from generate_series(1, 2000) g;
select is((select newest_decoded from pgpm.check_uuidv7('public.u_key', 'id', 1)),
          timestamptz '2020-01-01 00:00:00+00' + interval '2000 minutes',
  'check_uuidv7: a primary-key column reports its maximum, outside a one-row sample');

select * from finish();
