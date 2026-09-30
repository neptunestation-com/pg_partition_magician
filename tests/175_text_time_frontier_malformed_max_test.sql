-- Issue #661: _frontier_native decoded max(control) with _decode and let it raise. On a text_time table
-- the partition bounds are strings, so PostgreSQL routes a value whose timestamp field is not in the
-- declared shape (a digit outside the alphabet, or a field shorter than the width) into an existing
-- partition by string order. Once such a row was the column's maximum, every obtain tick raised and was
-- logged as skip_obtain, and the forward grid never grew again: the stall #325 made the frontier
-- self-healing (greatest(max, now())) to prevent. An undecodable maximum now falls back to now(), the
-- way check_text_time already treats it as null rather than raising.
--
-- Fixtures, all classic cuid ('c', 8 base-36 digits, ms), every one asymmetric in what it holds:
--   fm_bad    well-formed history plus ONE id whose last timestamp digit is '~', the column's maximum
--   fm_short  well-formed history plus ONE id whose timestamp field is 7 digits, the column's maximum
--   fm_ok     fm_bad's well-formed rows only, the twin whose grid fm_bad must match cell for cell
--   fm_future well-formed history plus a well-formed id 20 days ahead, so the fallback is shown NOT to
--             replace a maximum that does decode (a frontier that always read now() would pass the rest)
create extension if not exists pgtap;
set timezone = 'UTC';
select plan(13);

create table public.fm_bad    (id text collate "C" primary key, tag text);
create table public.fm_short  (id text collate "C" primary key, tag text);
create table public.fm_ok     (id text collate "C" primary key, tag text);
create table public.fm_future (id text collate "C" primary key, tag text);
insert into public.fm_bad
  select pgpm._ts_to_text_time(ts, 'c', 8, 36, 'ms') || lpad(n::text, 16, '0'), 'r' || n
    from (select ts, row_number() over (order by ts) n
            from generate_series(now() - interval '3 months', now() - interval '1 hour', interval '1 day') ts) s;
insert into public.fm_ok select * from public.fm_bad;
insert into public.fm_short select * from public.fm_bad where tag in ('r1', 'r2', 'r3');
insert into public.fm_future select * from public.fm_bad where tag in ('r1', 'r2');
insert into public.fm_future
  values (pgpm._ts_to_text_time(now() + interval '20 days', 'c', 8, 36, 'ms') || 'future0000000000', 'future');

call pgpm.transmute('public.fm_bad', 'id', interval '1 month', p_obtain => 1, p_paused => true,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
call pgpm.transmute('public.fm_ok', 'id', interval '1 month', p_obtain => 1, p_paused => true,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
call pgpm.transmute('public.fm_short', 'id', interval '1 month', p_obtain => 1, p_paused => true,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
call pgpm.transmute('public.fm_future', 'id', interval '1 month', p_obtain => 1, p_paused => true,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');

-- The malformed ids go in AFTER the conversion, as a live write would: PostgreSQL routes each into the
-- partition taking writes by string order. '~' sorts above every base-36 digit, so the first sorts after
-- every well-formed id of now()'s 36 ms bucket; the second is now()'s first seven digits alone, which
-- sorts above every well-formed id of an older 1296 ms bucket (the history ends an hour ago).
insert into public.fm_bad values (left(pgpm._ts_to_text_time(now(), 'c', 8, 36, 'ms'), 8) || '~zzzz', 'malformed');
insert into public.fm_short values (left(pgpm._ts_to_text_time(now(), 'c', 8, 36, 'ms'), 8), 'short');

select is((select tag from public.fm_bad order by id desc limit 1), 'malformed',
  'LIVENESS: PostgreSQL routed the out-of-alphabet id into a partition and it is fm_bad''s maximum');
select is((select tag from public.fm_short order by id desc limit 1), 'short',
  'LIVENESS: PostgreSQL routed the 7-digit id into a partition and it is fm_short''s maximum');
select throws_ok(
  $$ select pgpm._decode('text_time', (select id from public.fm_bad order by id desc limit 1), 'c', 8, 36, 'ms') $$,
  '22P02', NULL, 'LIVENESS: fm_bad''s maximum does not decode (a digit outside the alphabet)');
select throws_ok(
  $$ select pgpm._decode('text_time', (select id from public.fm_short order by id desc limit 1), 'c', 8, 36, 'ms') $$,
  '22P02', NULL, 'LIVENESS: fm_short''s maximum does not decode (the timestamp field is short)');

-- The contract at its source: the frontier of either table is computed, and it is the clock. Read
-- through a wrapper that turns a raise into the value compared, so a frontier that raises FAILS these
-- assertions with its error as "have" and the file goes on to the obtain tick below, rather than stopping.
create function pg_temp.frontier_or_error(p_parent regclass) returns text language plpgsql as $$
begin
  return pgpm._frontier_native(p_parent);
exception when others then
  return 'raised ' || sqlstate || ': ' || sqlerrm;
end;
$$;
select is(pg_temp.frontier_or_error('public.fm_bad'), pgpm._ts_text(now()),
  'the frontier of a table whose maximum has a digit outside the alphabet falls back to now()');
select is(pg_temp.frontier_or_error('public.fm_short'), pgpm._ts_text(now()),
  'the frontier of a table whose maximum has a short timestamp field falls back to now()');
-- ... and only for a maximum that does not decode: a well-formed one ahead of the clock still leads.
select is(pgpm._frontier_native('public.fm_future')::timestamptz,
  pgpm._text_time_to_ts((select id from public.fm_future order by id desc limit 1), 'c', 8, 36, 'ms'),
  'a well-formed maximum 20 days ahead is still the frontier, not now()');
select cmp_ok(pgpm._frontier_native('public.fm_future')::timestamptz, '>', now() + interval '19 days',
  'LIVENESS: that frontier is the future row, not the clock');

-- And what the frontier feeds: ask both twins for a four-cell lookahead and run one obtain tick each
-- (maintain_obtain, obtain's own pg_cron job).
select pgpm.set_obtain('public.fm_bad', 4);
select pgpm.set_obtain('public.fm_ok', 4);
select pgpm.resume('public.fm_bad');
select pgpm.resume('public.fm_ok');
select count(*) as n_obtain_before from pgpm.log where parent_table = 'public.fm_bad'::regclass and action = 'obtain' \gset
call pgpm.maintain_obtain('public.fm_ok');
call pgpm.maintain_obtain('public.fm_bad');

select pgpm._grid_next('time', '1 month', pgpm._grid_next('time', '1 month', pgpm._grid_next('time', '1 month',
         pgpm._grid_next('time', '1 month', pgpm._grid_next('time', '1 month',
           pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', pgpm._ts_text(now()), 'UTC'), 'UTC'), 'UTC'), 'UTC'), 'UTC'), 'UTC') as want_top \gset
select is((select max(hi::timestamptz) from pgpm.part where parent_table = 'public.fm_ok'::regclass and attached),
  :'want_top'::timestamptz,
  'LIVENESS: on the well-formed twin, one tick builds the lookahead out to four cells past the current one');
select ok((select count(*) from pgpm.log where parent_table = 'public.fm_bad'::regclass and action = 'obtain') > :n_obtain_before,
  'the obtain tick on the table holding the malformed maximum built partitions (it logged obtain rows)');
select is((select string_agg(left(method, 80), ' | ') from pgpm.log
            where parent_table = 'public.fm_bad'::regclass and action = 'skip_obtain'),
  null, 'and obtain was not deferred');
-- Identity, not a count: the table holding the malformed row has exactly the twin's grid, cell for cell.
select is(
  (select string_agg(lo || ' -> ' || hi, ', ' order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.fm_bad'::regclass and attached),
  (select string_agg(lo || ' -> ' || hi, ', ' order by lo::timestamptz) from pgpm.part
    where parent_table = 'public.fm_ok'::regclass and attached),
  'one tick builds exactly the well-formed twin''s grid on the table holding the malformed maximum');
select lives_ok(
  format($$ insert into public.fm_bad values (%L, 'ahead') $$,
         pgpm._ts_to_text_time(now() + interval '2 months', 'c', 8, 36, 'ms') || 'ahead00000000000'),
  'a write two months ahead is accepted into the grid obtain built');

select * from finish();
