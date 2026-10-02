-- from_hypertable rendered chunk bounds and control values in the session's DateStyle (issue #793).
--
-- from_hypertable_copy spliced each chunk's range_start/range_end (timestamptz) with a bare %L, which
-- renders the instant in the SESSION DateStyle. Under 'SQL' (or 'Postgres', 'German') that rendering
-- carries a zone ABBREVIATION, not an offset ('01/01/2024 08:00:00 CST' under Asia/Shanghai), and reading
-- it back resolves the abbreviation through timezone_abbreviations, where CST is US Central (-06), not
-- China (+08): every chunk bound moved 14 hours later and the oldest 14 hours of the hypertable were below
-- every chunk predicate, on a timestamptz dimension and on a naive one alike. The online drains and the
-- cutover rendered control values the same way (`max(ts)::text`, a timestamptz local's ::text) to carry a
-- watermark or a reconcile range into a literal, so under the same session the append catch-ups started 14
-- hours past the watermark and the change reconcile's control range missed the rows it re-reads. The
-- cutover's conservation check refused each swap (the source whole), after the whole online copy, blaming
-- out-of-order appends. Bounds now go through pgpm._ts_text and control values through
-- pgpm._from_hypertable_ctl_text, both pinned to DateStyle ISO, whatever the session says.
--
-- The condition for the defect (the session renders an abbreviation that reads back as another instant) is
-- witnessed, and an ISO twin copies the same fixture whole first. Every site is reached: (A) the chunk
-- bounds, timestamptz and naive; (B) the cutover's own keyless catch-up; (C) the pre-drain and its step,
-- then the keyed catch-up; (D) the change-tracking drain step and the cutover's under-lock reconcile.
-- ASYMMETRIC FIXTURES (48, 30, 10 + 3, 20 rows with 2 updates, 1 delete and 2 inserts), each asserted by
-- identity, and a cutover's result together with the relkind, since a refused cutover leaves the source
-- holding exactly the rows a successful one would. bench/hypertable_time_rendering.sh runs this file
-- against the mutations that put a session-rendered bound or control value back. Autocommit, disposable-db.
--
-- Every write to a hypertable runs under DateStyle ISO, the pgpm calls under SQL: TimescaleDB 2.16.1 itself
-- builds a NEW chunk's dimension CHECK through the same session rendering, so an insert that creates a chunk
-- under 'SQL, DMY' in Asia/Shanghai is refused by the chunk it created. That is the fixture's problem, not
-- the subject's, and keeping it out of the way keeps every write in this file landing where it is meant to.
set timezone = 'UTC';
set datestyle = 'ISO, MDY';
select plan(15);

create table public.g793_iso (ts timestamptz not null, v int not null);
create table public.g793_tz  (ts timestamptz not null, v int not null);
create table public.g793_nv  (ts timestamp   not null, v int not null);
select create_hypertable('public.g793_iso', 'ts', chunk_time_interval => interval '1 day');
select create_hypertable('public.g793_tz',  'ts', chunk_time_interval => interval '1 day');
select create_hypertable('public.g793_nv',  'ts', chunk_time_interval => interval '1 day');
insert into public.g793_iso select timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', g from generate_series(0, 47) g;
insert into public.g793_tz  select timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', g from generate_series(0, 47) g;
insert into public.g793_nv  select timestamp   '2024-01-01 00:00'    + g * interval '1 hour', g from generate_series(0, 29) g;

call pgpm.from_hypertable_copy('public.g793_iso', 'ts');
select is((select array_agg(v order by v) from public.g793_iso_pgpm_dest), (select array_agg(g) from generate_series(0, 47) g),
  'LIVENESS: under DateStyle ISO the copy holds every row 0..47');

set datestyle = 'SQL, DMY';
set timezone = 'Asia/Shanghai';
select is((timestamptz '2024-01-01 00:00+00')::text, '01/01/2024 08:00:00 CST',
  'LIVENESS: this session renders a timestamptz with the zone abbreviation CST');
select is(((timestamptz '2024-01-01 00:00+00')::text)::timestamptz - timestamptz '2024-01-01 00:00+00', interval '14 hours',
  'LIVENESS: and that rendering reads back 14 hours later');

-- ==================== (A) the chunk bounds of the copy ====================
call pgpm.from_hypertable_copy('public.g793_tz', 'ts');
call pgpm.from_hypertable_copy('public.g793_nv', 'ts');
select is(current_setting('DateStyle') || '|' || current_setting('TimeZone'), 'SQL, DMY|Asia/Shanghai',
  'LIVENESS: the copies ran in that session');
select is((select array_agg(v order by v) from public.g793_tz_pgpm_dest), (select array_agg(g) from generate_series(0, 47) g),
  'timestamptz: the copy under DateStyle SQL holds every row 0..47');
select is((select array_agg(v order by v) from public.g793_nv_pgpm_dest), (select array_agg(g) from generate_series(0, 29) g),
  'timestamp: the copy under DateStyle SQL holds every row 0..29');

-- ==================== (B) the cutover's own keyless catch-up ====================
set datestyle = 'ISO, MDY';
insert into public.g793_tz select timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', g from generate_series(48, 50) g;
set datestyle = 'SQL, DMY';
call pgpm.from_hypertable_cutover('public.g793_tz', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.g793_tz'::regclass) || '|'
          || (select array_agg(v order by v) from public.g793_tz)::text,
  'p|' || (select array_agg(g) from generate_series(0, 50) g)::text,
  'keyless: the cutover under DateStyle SQL catches up the 3 appends past the watermark and converts the table');

-- ==================== (C) the pre-drain and its step, then the keyed catch-up ====================
set datestyle = 'ISO, MDY';
create table public.g793_k (id bigint not null, ts timestamptz not null, v text not null, primary key (id, ts));
select create_hypertable('public.g793_k', 'ts', chunk_time_interval => interval '1 day');
insert into public.g793_k select g, timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', 'k' || g from generate_series(1, 10) g;
set datestyle = 'SQL, DMY';
call pgpm.from_hypertable_copy('public.g793_k', 'ts');
set datestyle = 'ISO, MDY';
insert into public.g793_k select g, timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', 'k' || g from generate_series(11, 13) g;
set datestyle = 'SQL, DMY';
call pgpm.from_hypertable_drain_appends('public.g793_k', 'ts', 1, 1);
select is((select string_agg(id::text, ',' order by id) from public.g793_k_pgpm_dest), '1,2,3,4,5,6,7,8,9,10,11,12',
  'the pre-drain under DateStyle SQL takes the appends past the watermark, leaving one for the cutover');
call pgpm.from_hypertable_cutover('public.g793_k', 'ts', interval '1 day', p_predrain => false);
select is((select relkind::text from pg_class where oid = 'public.g793_k'::regclass) || '|'
          || (select string_agg(id || '=' || v, ',' order by id) from public.g793_k),
  'p|1=k1,2=k2,3=k3,4=k4,5=k5,6=k6,7=k7,8=k8,9=k9,10=k10,11=k11,12=k12,13=k13',
  'keyed: the cutover under DateStyle SQL catches up the last append and converts the table');

-- ==================== (D) change tracking: the drain step and the under-lock reconcile ====================
set datestyle = 'ISO, MDY';
create table public.g793_d (id bigint not null, ts timestamptz not null, v text not null, primary key (id, ts));
select create_hypertable('public.g793_d', 'ts', chunk_time_interval => interval '1 day');
insert into public.g793_d select g, timestamptz '2024-01-01 00:00+00' + g * interval '1 hour', 'd' || g from generate_series(1, 20) g;
set datestyle = 'SQL, DMY';
call pgpm.from_hypertable_copy('public.g793_d', 'ts', p_track_changes => true);
set datestyle = 'ISO, MDY';
update public.g793_d set v = 'u3'  where id = 3;
update public.g793_d set v = 'u17' where id = 17;
delete from public.g793_d where id = 9;
insert into public.g793_d values (21, timestamptz '2024-01-01 00:00+00' + interval '21 hours', 'd21'),
                                 (0,  timestamptz '2024-01-01 00:00+00', 'd0');
set datestyle = 'SQL, DMY';
select is((select count(distinct id)::int from public.g793_d_pgpm_delta), 5, 'LIVENESS: the capture logged the 5 changes');
call pgpm.from_hypertable_drain_delta('public.g793_d', 'ts', 2, 0);
select is((select count(*)::int from public.g793_d_pgpm_delta), 0, 'LIVENESS: the drain took every logged change');
select is((select string_agg(id || '=' || v, ',' order by id) from public.g793_d_pgpm_dest),
  '0=d0,1=d1,2=d2,3=u3,4=d4,5=d5,6=d6,7=d7,8=d8,10=d10,11=d11,12=d12,13=d13,14=d14,15=d15,16=d16,17=u17,18=d18,19=d19,20=d20,21=d21',
  'the change drain under DateStyle SQL reconciles every changed key: the 2 updates, the delete and the 2 inserts');
-- one more change, left for the cutover's own under-lock reconcile (its pre-drain threshold is the batch)
set datestyle = 'ISO, MDY';
update public.g793_d set v = 'u5' where id = 5;
set datestyle = 'SQL, DMY';
select is((select count(distinct id)::int from public.g793_d_pgpm_delta), 1, 'LIVENESS: one change is left for the cutover');
call pgpm.from_hypertable_cutover('public.g793_d', 'ts', interval '1 day');
select is(current_setting('DateStyle') || '|' || current_setting('TimeZone'), 'SQL, DMY|Asia/Shanghai',
  'LIVENESS: the drains and cutovers ran in that session too');
select is((select relkind::text from pg_class where oid = 'public.g793_d'::regclass) || '|'
          || (select string_agg(id || '=' || v, ',' order by id) from public.g793_d),
  'p|0=d0,1=d1,2=d2,3=u3,4=d4,5=u5,6=d6,7=d7,8=d8,10=d10,11=d11,12=d12,13=d13,14=d14,15=d15,16=d16,17=u17,18=d18,19=d19,20=d20,21=d21',
  'tracked: the cutover under DateStyle SQL reconciles the last change and converts the table');

select * from finish();
