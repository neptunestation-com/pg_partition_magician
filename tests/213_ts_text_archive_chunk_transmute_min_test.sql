-- The archive picker's chunk and transmute's monolith lo are the same from every session's DateStyle
-- (issue #788, the #500/#570 class at two more sites).
--
-- Both sites rendered a timestamptz control value with a bare ::text, in the SESSION's DateStyle and
-- TimeZone, and parsed the text back in the same session. Under a DateStyle that renders zone
-- abbreviations (SQL, Postgres, German) that round trip is not the identity: Europe/Dublin's summer time
-- renders 'IST', and the default timezone_abbreviations read 'IST' as Israel (+02), so a value reads one
-- hour early; Asia/Kolkata also renders 'IST', so there a value reads 3.5 hours late. Now both go through
-- _ts_text, which pins ISO (#500), and ISO text parses back to the same instant under every DateStyle.
--
-- 1. _next_archive_chunk (F2-05) read the window's newest value, the next distinct value past it and the
--    tie extension with a bare ::text and handed them to _col_to_native (and the first one, as a
--    literal, to the next-distinct probe). From a SQL/Dublin session every value read an hour early, the
--    chunk's stop fell below its lo, the picker returned no chunk, and _archive_step skipped the child
--    silently every tick: the aged partition was never archived and so never retired. The fixture is
--    six rows of one size, so a budget of three and a half rows makes a batch of exactly three, and the
--    batch's newest value (+20 s) is one of a TIE (ids 3 and 4), so the right chunk is [+0 s, +30 s) and
--    holds four rows. It is asserted by its exact bounds from an ISO session (the liveness witness that
--    the picker returns this chunk at all) and from the SQL/Dublin one, then end to end: two maintenance
--    ticks from the SQL/Dublin session write that chunk to the ledger.
-- 2. _transmute (F2-06) read min(control) as `t.col::text` and parsed it back with ::timestamptz. From a
--    SQL/Kolkata session the minimum (2026-03-31 23:00 IST, the last hour of March) read as 2026-04-01
--    02:30 IST, floored into April, the monolith's bound CHECK excluded the table's own oldest row, phase
--    2's VALIDATE failed and the NOT VALID bound was left behind. A control table converted from an ISO
--    session is the witness that the conversion and its expected lo are reachable.
--
-- PostgreSQL 18 resolves an abbreviation the SESSION's own zone uses to that zone's offset before
-- consulting timezone_abbreviations, so on 18 the bare round trip is the identity in either zone and the
-- defect is unreachable in one session (tests/136 says the same). The round-trip witnesses below say so
-- by version: an hour (Dublin) and 3.5 hours (Kolkata) before 18, none on 18. The guard,
-- bench/ts_text_archive_chunk_transmute_min.sh, runs before 18 against the mutants
-- (archive_chunk_bare_text, transmute_min_bare_text) that put each bare render back.
create extension if not exists pgtap;

select plan(20);
set timezone = 'UTC';
set datestyle = 'ISO, MDY';

select case when current_setting('server_version_num')::int >= 180000 then interval '0'
            else interval '1 hour' end as dub_gap \gset
select case when current_setting('server_version_num')::int >= 180000 then interval '0'
            else interval '3 hours 30 minutes' end as kol_gap \gset

-- ======================================================================================================
-- 1. _next_archive_chunk (F2-05)
-- ======================================================================================================
create table public.arc213 (id bigint not null, ts timestamptz not null, pad text not null, primary key (id, ts));
insert into public.arc213 values
  (1, '2025-07-01 00:00:00+00', repeat('a', 200)),
  (2, '2025-07-01 00:00:10+00', repeat('b', 200)),
  (3, '2025-07-01 00:00:20+00', repeat('c', 200)),
  (4, '2025-07-01 00:00:20+00', repeat('d', 200)),   -- the tie at the batch's newest value
  (5, '2025-07-01 00:00:30+00', repeat('e', 200)),
  (6, '2025-07-01 00:00:40+00', repeat('f', 200));
call pgpm.transmute('public.arc213', 'ts', interval '1 second', p_obtain => 2, p_retain => interval '0 seconds');
select child_name as arc_mono from pgpm.part
 where parent_table = 'public.arc213'::regclass and attached order by lo::timestamptz limit 1 \gset
-- a budget of three and a half rows of this one size: the batch is exactly three
update pgpm.config
   set archive_byte_budget = (select (avg(pg_column_size(t.*)) * 3.5)::bigint from public.arc213 t)
 where parent_table = 'public.arc213'::regclass;
select pgpm.set_archive_fn('public.arc213', 'pgpm._archive_noop(regclass,name,text,text)');

select is((select array_agg(pg_column_size(t.*)) = array_fill(min(pg_column_size(t.*)), array[6]) from public.arc213 t),
  true, 'LIVENESS: every row is the same size, so the budget makes a batch of exactly three');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.arc213'::regclass and child_name = :'arc_mono'),
  timestamptz '2025-07-01 00:00:00+00', 'LIVENESS: the monolith starts at the first row');

select results_eq(
  format($$select lo::timestamptz, hi::timestamptz from pgpm._next_archive_chunk('public.arc213', %L)$$, :'arc_mono'),
  $$values (timestamptz '2025-07-01 00:00:00+00', timestamptz '2025-07-01 00:00:30+00')$$,
  'LIVENESS: from an ISO session the picker returns [+0 s, +30 s), the batch extended past the tie at +20 s');

set datestyle = 'SQL, DMY';
set timezone = 'Europe/Dublin';
select ok((select ts::text from public.arc213 where id = 3) like '% IST',
  'LIVENESS: this session renders the rows'' instants with the abbreviation IST');
select is((select ts - (ts::text)::timestamptz from public.arc213 where id = 3), :'dub_gap'::interval,
  'LIVENESS: a bare ::text round trip in this session reads the instant early by the abbreviation gap (an hour before PG 18, none on 18)');
create temp table chunk_dub as
  select c.lo, c.hi, c.hi = pgpm._ts_text(timestamptz '2025-07-01 00:00:30+00') as hi_iso
    from pgpm._next_archive_chunk('public.arc213', :'arc_mono') c;
set datestyle = 'ISO, MDY';
set timezone = 'UTC';
select results_eq($$select lo::timestamptz, hi::timestamptz from chunk_dub$$,
  $$values (timestamptz '2025-07-01 00:00:00+00', timestamptz '2025-07-01 00:00:30+00')$$,
  'from a SQL/Dublin session the picker returns the same chunk [+0 s, +30 s)');
select is((select hi_iso from chunk_dub), true,
  'and its hi is canonical ISO text, the form every later session parses back to the same instant');

-- end to end: the monolith ages past a retain of 0 on its 1 s grid, then two ticks from SQL/Dublin
select pgpm.resume('public.arc213');
select pg_sleep(2.5);
select ok((select retain_backlog from pgpm.status() where parent = 'public.arc213'::regclass) >= 1,
  'LIVENESS: the monolith is aged (retain_backlog >= 1)');
set datestyle = 'SQL, DMY';
set timezone = 'Europe/Dublin';
call pgpm.maintain('public.arc213');
call pgpm.maintain('public.arc213');
set datestyle = 'ISO, MDY';
set timezone = 'UTC';
select ok(exists (select 1 from pgpm.archive_ledger
                   where parent_table = 'public.arc213'::regclass and child_name = :'arc_mono'
                     and lo::timestamptz = timestamptz '2025-07-01 00:00:00+00'
                     and hi::timestamptz = timestamptz '2025-07-01 00:00:30+00'),
  'two ticks from the SQL/Dublin session archived the monolith''s first chunk [+0 s, +30 s)');
select is((select array_agg(extract(epoch from lo::timestamptz - timestamptz '2025-07-01 00:00:00+00')::int || ':' || rows_archived
                            order by lo::timestamptz)
             from pgpm.archive_ledger
            where parent_table = 'public.arc213'::regclass and child_name = :'arc_mono'),
          array['0:4', '30:2'],
  'the ledger holds exactly the two chunks the six rows make: [+0 s, +30 s) with the tie''s four rows, then the other two');
select ok(to_regclass('public.' || :'arc_mono') is null
          and exists (select 1 from pgpm.log where parent_table = 'public.arc213'::regclass and action = 'retain_drop'
                         and lo::timestamptz = timestamptz '2025-07-01 00:00:00+00'),
  'and the covered monolith was retired (dropped, logged as retain_drop)');

-- ======================================================================================================
-- 2. _transmute's monolith lo (F2-06)
-- ======================================================================================================
set timezone = 'Asia/Kolkata';
create table public.kol213_iso (id bigint not null, ts timestamptz not null, primary key (id, ts));
create table public.kol213 (id bigint not null, ts timestamptz not null, primary key (id, ts));
-- row 1: 2026-03-31 23:00 IST (17:30Z), the last hour of March in Kolkata; the others well inside April and now
insert into public.kol213_iso values (1, '2026-03-31 17:30:00+00'), (2, '2026-04-15 00:00:00+00'), (3, now() - interval '1 day');
insert into public.kol213 select * from public.kol213_iso;

call pgpm.transmute('public.kol213_iso', 'ts', interval '1 month', p_obtain => 1);
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.kol213_iso'::regclass order by lo::timestamptz limit 1),
  timestamptz '2026-03-01 00:00:00+05:30',
  'LIVENESS: from an ISO session in Asia/Kolkata the table converts with its monolith starting 2026-03-01 IST');

set datestyle = 'SQL, DMY';
select ok((select ts::text from public.kol213 where id = 1) like '% IST',
  'LIVENESS: this session renders row 1 with the abbreviation IST');
select is((select (ts::text)::timestamptz - ts from public.kol213 where id = 1), :'kol_gap'::interval,
  'LIVENESS: a bare ::text round trip in this session reads row 1 late by the abbreviation gap (3.5 hours before PG 18, none on 18), past the end of March');
\set ON_ERROR_STOP 0
call pgpm.transmute('public.kol213', 'ts', interval '1 month', p_obtain => 1);
\set ON_ERROR_STOP 1
set datestyle = 'ISO, MDY';

select is((select relkind::text from pg_class where oid = 'public.kol213'::regclass), 'p',
  'transmute converts the table from a SQL/Kolkata session');
select is((select lo::timestamptz from pgpm.part where parent_table = 'public.kol213'::regclass order by lo::timestamptz limit 1),
  timestamptz '2026-03-01 00:00:00+05:30',
  'its monolith starts 2026-03-01 IST, the floor of the true minimum');
select is((select lo from pgpm.part where parent_table = 'public.kol213'::regclass order by lo::timestamptz limit 1),
  (select lo from pgpm.part where parent_table = 'public.kol213_iso'::regclass order by lo::timestamptz limit 1),
  'and its lo is the same text the ISO session wrote');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.kol213'::regclass
                        and conname = 'pgpm_monolith_bound' and not convalidated),
  'no NOT VALID pgpm_monolith_bound is left on it');
select is((select array_agg(k.id order by k.id) from public.kol213 k join pgpm.part p
             on p.parent_table = 'public.kol213'::regclass and p.child_name = k.tableoid::regclass::text
          where p.attached and k.ts >= p.lo::timestamptz and k.ts < p.hi::timestamptz),
  array[1, 2, 3]::bigint[],
  'rows 1, 2 and 3 are each served by the partition whose range holds them');
select is((select array_agg(id order by id) from public.kol213_iso), array[1, 2, 3]::bigint[],
  'LIVENESS: the ISO control still holds rows 1, 2 and 3');

select * from finish();
