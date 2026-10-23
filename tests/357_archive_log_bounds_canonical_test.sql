-- The bounds the archive step logs for a range it aggregates name their instants the same in every session
-- (issue #1370; #814's second bullet for the second site).
--
-- THE DEFECT. Two log rows of the archive step carry a range computed over several ledger rows: pgpm._mark_gone_chunks'
-- archive_chunk_retired (the chunks of a relation dropped outside retire()) and _archive_step's #511 orphan discard,
-- archive_coverage_reset. Both rendered it as min(lo::timestamptz)::text and max(hi::timestamptz)::text, a bare ::text
-- that takes the CALLING session's DateStyle and zone, where every other native time value pgpm stores goes through
-- pgpm._ts_text (#500). An archive tick under 'SQL, DMY' in Asia/Kolkata wrote '01/12/2026 05:30:00 IST': text that
-- names no instant by itself (pgpm._native_named is false), which a default session reads as 12 January, at Israel's
-- offset, or not at all.
--
-- THE CONTRACT. Both rows' lo and hi are canonical native text (ISO, with the offset), whatever session ran the step:
-- each names its instant by itself and reads back from a session configured otherwise as exactly the range of the
-- chunks it describes.
--   PART A  archive_chunk_retired: two chunks [M2, M2 + 7 days) and [M2 + 7 days, M2 + 14 days) of a partition dropped
--           by hand; the row's range is [M2, M2 + 14 days), the two chunks together, not either one.
--   PART B  archive_coverage_reset: one chunk under a name no pgpm.part row tracks (a relation renamed aside), over
--           [M1, M1 + 10 days) of a tracked partition, discarded.
--
-- THE FIXTURE. A UTC month grid built a few months ahead of now(), so the cells are the clock's and no row of the
-- table is needed in them. Every bound the fixture writes is pgpm's own canonical text. The step runs from a session
-- under 'SQL, DMY' in Asia/Kolkata, whose bare ::text of a timestamptz names no instant (a GUARD says so), and every
-- check reads from 'ISO, MDY' in UTC and again from 'Postgres, MDY' in America/New_York. Asymmetric: two chunks marked
-- against one discarded, and a third chunk under the dropped partition's name that is NOT marked (it is retired
-- already) and must not widen the range.
--
-- Runs on pgpm_test:18 as well as 15 (it leans on DateStyle and TimeZone). bench/archive_log_bounds_canonical.sh runs
-- this file against bench/mutations/mutate.py's archive_log_bounds_session_render.
create extension if not exists pgtap;
set client_min_messages = warning;
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

select plan(12);

create schema t357;
-- a reading that cannot raise: text no session parses reads as null, so the check fails rather than the file
create function t357.ts(p text) returns timestamptz language plpgsql stable as $f$
begin return p::timestamptz; exception when data_exception then return null; end $f$;
create table t357.ev (ts timestamptz not null, body text);
insert into t357.ev values (now() - interval '40 days', 'old'), (now(), 'now');
call pgpm.transmute('t357.ev', 'ts', interval '1 month', 2, p_paused => true);
select pgpm.extend_to('t357.ev', pgpm._ts_text(date_trunc('month', now(), 'UTC') + interval '4 months'));

-- M1 and M2: the first and second month cells after this one
-- (and the ends of the ranges below, computed here in UTC: a day added in America/New_York across its DST change is
-- 23 or 25 hours)
select date_trunc('month', now(), 'UTC') + interval '1 month' as m1,
       date_trunc('month', now(), 'UTC') + interval '1 month 10 days' as m1_10,
       date_trunc('month', now(), 'UTC') + interval '2 months' as m2,
       date_trunc('month', now(), 'UTC') + interval '2 months 14 days' as m2_14 \gset
select child_name as m1_name from pgpm.part where parent_table = 't357.ev'::regclass and lo::timestamptz = :'m1'::timestamptz \gset
select child_name as m2_name, child_oid as m2_oid from pgpm.part
 where parent_table = 't357.ev'::regclass and lo::timestamptz = :'m2'::timestamptz \gset

-- PART A's chunks: two live, recorded for M2's partition, and one already retired under its name before (a partition
-- an earlier incarnation of the name held), far earlier, which the mark does not touch
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, child_oid, rows_archived)
values ('t357.ev', pgpm._ts_text(:'m2'::timestamptz), pgpm._ts_text(:'m2'::timestamptz + interval '7 days'), :'m2_name', :m2_oid, 0),
       ('t357.ev', pgpm._ts_text(:'m2'::timestamptz + interval '7 days'), pgpm._ts_text(:'m2'::timestamptz + interval '14 days'), :'m2_name', :m2_oid, 0);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, child_oid, rows_archived, retired_at)
values ('t357.ev', pgpm._ts_text(:'m2'::timestamptz - interval '5 years'), pgpm._ts_text(:'m2'::timestamptz - interval '5 years' + interval '1 day'),
        :'m2_name', 1, 0, now() - interval '1 day');
-- dropped by hand, outside retire(): its chunks' objects are now the only copy of its rows
select format('alter table t357.ev detach partition t357.%I', :'m2_name') \gexec
select format('drop table t357.%I', :'m2_name') \gexec

-- PART B's chunk: a relation renamed aside (it exists, so it is not marked gone), under a name pgpm.part does not
-- track, over M1's tracked partition
create table t357.moved (ts timestamptz);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, child_oid, rows_archived)
values ('t357.ev', pgpm._ts_text(:'m1'::timestamptz), pgpm._ts_text(:'m1'::timestamptz + interval '10 days'), 'moved',
        't357.moved'::regclass::oid, 0);

select pgpm.set_archive_fn('t357.ev', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);
create temporary table mark357 as select coalesce(max(id), 0) as id, clock_timestamp() as at from pgpm.log;

-- the archive step, from a session that renders a timestamptz unlike pgpm does
set datestyle = 'SQL, DMY';
set timezone = 'Asia/Kolkata';
select not pgpm._native_named('time', (:'m2'::timestamptz)::text) as session_unnamed \gset
select pgpm._archive_step('t357.ev');
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

select ok(:'session_unnamed'::boolean,
  'GUARD: the session that ran the step renders a bare ::text of an instant as text that names no instant');

-- ======== PART A: archive_chunk_retired ========
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.archive_ledger
            where parent_table = 't357.ev'::regclass and child_name = :'m2_name' and retired_at >= (select at from mark357)),
  array[:'m2'::timestamptz, :'m2'::timestamptz + interval '7 days'],
  'LIVENESS: A: the step marked both of the dropped partition''s live chunks retired');
select is((select count(*)::int from pgpm.log where parent_table = 't357.ev'::regclass and action = 'archive_chunk_retired'
            and id > (select id from mark357) and rows = 2),
  1, 'LIVENESS: A: the step logged one archive_chunk_retired row for the two chunks');
select ok((select pgpm._native_named('time', lo) and pgpm._native_named('time', hi) from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_chunk_retired' and id > (select id from mark357)),
  'A: the archive_chunk_retired row''s lo and hi name their instants by themselves');
select is((select t357.ts(lo) from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_chunk_retired' and id > (select id from mark357)),
  :'m2'::timestamptz, 'A: its lo reads back, from ISO in UTC, as the first chunk''s lo, M2');
select is((select t357.ts(hi) from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_chunk_retired' and id > (select id from mark357)),
  :'m2_14'::timestamptz, 'A: its hi reads back, from ISO in UTC, as the second chunk''s hi, M2 + 14 days');

-- ======== PART B: the orphan discard's archive_coverage_reset ========
select is_empty($$ select 1 from pgpm.archive_ledger where parent_table = 't357.ev'::regclass and child_name = 'moved' $$,
  'LIVENESS: B: the orphan chunk under the untracked name was discarded');
select ok((select pgpm._native_named('time', lo) and pgpm._native_named('time', hi) from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_coverage_reset' and id > (select id from mark357)
              and method like '%t357.moved,%'),
  'B: the archive_coverage_reset row''s lo and hi name their instants by themselves');
select is((select coalesce(t357.ts(lo)::text, 'unreadable') || ' to ' || coalesce(t357.ts(hi)::text, 'unreadable') from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_coverage_reset' and id > (select id from mark357)
              and method like '%t357.moved,%'),
  (:'m1'::timestamptz)::text || ' to ' || (:'m1_10'::timestamptz)::text,
  'B: its range reads back, from ISO in UTC, as the discarded chunk''s [M1, M1 + 10 days)');

-- ======== both, from a session configured unlike either ========
set datestyle = 'Postgres, MDY';
set timezone = 'America/New_York';
select is((select t357.ts(lo) = :'m2'::timestamptz and t357.ts(hi) = :'m2_14'::timestamptz from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_chunk_retired' and id > (select id from mark357)),
  true, 'A: from Postgres, MDY in America/New_York the archive_chunk_retired row reads as [M2, M2 + 14 days) too');
select is((select t357.ts(lo) = :'m1'::timestamptz and t357.ts(hi) = :'m1_10'::timestamptz from pgpm.log
            where parent_table = 't357.ev'::regclass and action = 'archive_coverage_reset' and id > (select id from mark357)
              and method like '%t357.moved,%'),
  true, 'B: from Postgres, MDY in America/New_York the archive_coverage_reset row reads as [M1, M1 + 10 days) too');
set datestyle = 'ISO, MDY';
set timezone = 'UTC';

select ok(exists (select 1 from pgpm.archive_ledger where parent_table = 't357.ev'::regclass and child_name = :'m2_name'
                   and lo::timestamptz = :'m2'::timestamptz - interval '5 years' and retired_at < (select at from mark357)),
  'A: the chunk retired before the step is left as it was, so the row''s range is the two live chunks''');

select * from finish();
