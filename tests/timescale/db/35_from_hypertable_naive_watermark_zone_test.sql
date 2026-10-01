-- from_hypertable_cutover held the append-only watermark of a NAIVE dimension as timestamptz (issue #791).
--
-- The cutover reads its catch-up watermark, max(control) of the destination, into a local and splices it
-- back as the bound of the catch-up (`control > watermark` keyless, `control >= watermark` keyed, with the
-- anti-join taking the tie). That local was declared timestamptz, so a `timestamp` (no tz) watermark went
-- through the SESSION TimeZone on the way in and came back out with an offset that the timestamp
-- comparison discards. Outside a zone's spring-forward gap the round trip returns the same wall clock, by
-- luck; inside it the wall clock does not exist, the conversion moves it an hour forward, and the in-order
-- appends between the true watermark and that hour are below the catch-up's bound. The conservation check
-- then refuses the swap (no loss: the source is whole), blaming out-of-order appends that never happened.
-- The reference promises the copy is exact under any session TimeZone and that the catch-up takes every
-- row past max(control). The watermark is now carried as the column's own text, never through a zone.
--
-- America/New_York's 2024-03-10 02:00-03:00 does not exist; every subject's watermark is put inside it,
-- and that is witnessed (the gap is the condition for the defect). A UTC twin of the keyless fixture cuts
-- over first, so a refusal of the subject cannot be the fixture's own fault. ASYMMETRIC FIXTURES: 11 copied
-- + 3 appended keyless rows, 7 copied + 3 pre-drained + 1 caught-up keyed rows, each asserted by identity
-- together with the relkind, because a REFUSED cutover leaves the source hypertable holding exactly the
-- rows a successful one would (an assertion on the rows alone passes for the wrong reason).
-- bench/hypertable_time_rendering.sh runs this file against the mutation that puts the timestamptz local
-- back. Autocommit, disposable-db: every copy, drain and cutover commits, so each is a top-level CALL.
set timezone = 'UTC';
select plan(8);

-- ==================== (A) keyless, the cutover's own catch-up ====================
create table public.g791_twin (ts timestamp not null, v int not null);
create table public.g791_a    (ts timestamp not null, v int not null);
select create_hypertable('public.g791_twin', 'ts', chunk_time_interval => interval '1 day');
select create_hypertable('public.g791_a',    'ts', chunk_time_interval => interval '1 day');
insert into public.g791_twin select timestamp '2024-03-10 00:00' + g * interval '15 minutes', g from generate_series(0, 10) g;
insert into public.g791_a    select timestamp '2024-03-10 00:00' + g * interval '15 minutes', g from generate_series(0, 10) g;
call pgpm.from_hypertable_copy('public.g791_twin', 'ts');
call pgpm.from_hypertable_copy('public.g791_a', 'ts');
-- the in-order appends past the watermark: two inside the gap's hour, one after it
insert into public.g791_twin values ('2024-03-10 02:45', 11), ('2024-03-10 03:00', 12), ('2024-03-10 03:45', 13);
insert into public.g791_a    values ('2024-03-10 02:45', 11), ('2024-03-10 03:00', 12), ('2024-03-10 03:45', 13);

select is((select max(ts) from public.g791_a_pgpm_dest), timestamp '2024-03-10 02:30',
  'LIVENESS: the copy watermark is the naive 2024-03-10 02:30');
set timezone = 'America/New_York';
select is((timestamp '2024-03-10 02:30')::timestamptz::timestamp, timestamp '2024-03-10 03:30',
  'LIVENESS: in America/New_York that wall clock is in the spring-forward gap, so a trip through the zone moves it an hour');

set timezone = 'UTC';
call pgpm.from_hypertable_cutover('public.g791_twin', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.g791_twin'::regclass) || '|'
          || (select string_agg(to_char(ts, 'HH24:MI') || '=' || v, ',' order by v) from public.g791_twin),
  'p|00:00=0,00:15=1,00:30=2,00:45=3,01:00=4,01:15=5,01:30=6,01:45=7,02:00=8,02:15=9,02:30=10,02:45=11,03:00=12,03:45=13',
  'LIVENESS: the UTC twin cuts over, with the 11 copied rows and the 3 appends');

set timezone = 'America/New_York';
call pgpm.from_hypertable_cutover('public.g791_a', 'ts', interval '1 day');
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: the subject''s cutover ran in America/New_York');
select is((select relkind::text from pg_class where oid = 'public.g791_a'::regclass) || '|'
          || (select string_agg(to_char(ts, 'HH24:MI') || '=' || v, ',' order by v) from public.g791_a),
  'p|00:00=0,00:15=1,00:30=2,00:45=3,01:00=4,01:15=5,01:30=6,01:45=7,02:00=8,02:15=9,02:30=10,02:45=11,03:00=12,03:45=13',
  'keyless: the cutover under America/New_York catches up the appends past a gap watermark and converts the table');

-- ==================== (B) keyed, after a pre-drain that leaves the watermark in the gap ====================
-- The copy itself runs in America/New_York (its chunk bounds are exact there, #459). The explicit pre-drain
-- (batch 1, threshold 1) carries its watermark as text and takes the appends up to 02:50, leaving one past
-- it; the cutover's own keyed catch-up (p_predrain => false) must take that one from a watermark of 02:50.
create table public.g791_b (id bigint not null, ts timestamp not null, v text not null, primary key (id, ts));
select create_hypertable('public.g791_b', 'ts', chunk_time_interval => interval '1 day');
insert into public.g791_b select g, timestamp '2024-03-10 00:00' + (g - 1) * interval '20 minutes', 'b' || g from generate_series(1, 7) g;
call pgpm.from_hypertable_copy('public.g791_b', 'ts');
insert into public.g791_b values (8, '2024-03-10 02:35', 'b8'), (9, '2024-03-10 02:40', 'b9'),
                                 (10, '2024-03-10 02:50', 'b10'), (11, '2024-03-10 03:15', 'b11');
call pgpm.from_hypertable_drain_appends('public.g791_b', 'ts', 1, 1);
select is((select max(ts)::text || '|' || string_agg(id::text, ',' order by id) from public.g791_b_pgpm_dest),
  '2024-03-10 02:50:00|1,2,3,4,5,6,7,8,9,10',
  'LIVENESS: the pre-drain took the three appends inside the gap and left the watermark at 02:50, in it');
call pgpm.from_hypertable_cutover('public.g791_b', 'ts', interval '1 day', p_predrain => false);
select is(current_setting('TimeZone'), 'America/New_York', 'LIVENESS: the keyed cutover ran in America/New_York');
select is((select relkind::text from pg_class where oid = 'public.g791_b'::regclass) || '|'
          || (select string_agg(id || '@' || to_char(ts, 'HH24:MI') || '=' || v, ',' order by id) from public.g791_b),
  'p|1@00:00=b1,2@00:20=b2,3@00:40=b3,4@01:00=b4,5@01:20=b5,6@01:40=b6,7@02:00=b7,8@02:35=b8,9@02:40=b9,10@02:50=b10,11@03:15=b11',
  'keyed: the cutover catches up the append past a gap watermark of 02:50 and converts the table');

select * from finish();
