-- from_hypertable refuses, before anything is changed, two tables transmute would refuse only at the handoff
-- or would make it die raw (issues #1328 and #1221).
--
-- #1328: a hypertable whose newest time value is infinity (TimescaleDB accepts infinity; it refuses
-- -infinity). The frontier check (#792), transmute's far-future refusal asked before the swap, computed
-- v_max - now() in its own message's arguments, so it died raw 'cannot subtract infinite timestamps' (22008),
-- naming no table, column or remedy. With p_force_frontier it skipped the read altogether, and the copy died
-- raw 'timestamp out of range' on the chunk that holds the row, after committing the apparatus and the chunks
-- before it. Now the check refuses an infinity newest value in pgpm's words whatever p_force_frontier says (no
-- bound covers infinity, so there is nothing to force, as transmute's own refusal says), and the copy refuses
-- the chunk TimescaleDB makes for the value, which no chunk-bounded read can reach and which outlives the rows:
-- the remedy names the DROP TABLE that removes it.
--
-- #1221: transmute's session-zone rule (#455): a timestamptz grid records the session TimeZone, and transmute
-- refuses one pgpm._canonical_tz cannot record (a POSIX rule such as 'UTC+3', or 'localtime'). from_hypertable
-- never asked it, so under such a zone the copy ran and the cutover's swap committed, dropping the hypertable,
-- before the handoff refused, leaving a plain table pgpm does not manage. Now _from_hypertable_check_arguments
-- asks it, so from_hypertable refuses before its copy and the cutover before its pre-drain and its swap.
--
-- WHAT THE HARNESS ALLOWS. Every refused call is a committing procedure wrapped by throws_like, and one that
-- wrongly does NOT refuse dies at its first COMMIT inside that function context with 2D000 (the copy's, or
-- with p_predrain => false the swap's) and rolls back into the state a refusal leaves. So the pinned
-- messages, anchored at the start, are the discriminating assertions; the state checks after them are
-- invariants, marked so.
--
-- ASYMMETRIC FIXTURES. i370 (keyed, three rows, ids 1, 2 and 3, id 3 at infinity) for the infinity refusal
-- before the copy, j370 (rows 5 and 6, then 7 at infinity after its copy) for the cutover's, f370 (two rows, 10
-- and 20, 20 far in the future) as the control that reaches the frontier refusal's finite branch; z370 (a
-- timestamptz dimension, four rows 31 to 34) and n370 (a naive timestamp dimension, two rows 41 and 42) for the
-- zone. WITNESSES: transmute refuses an infinity newest value and the zone on plain tables with its own
-- messages, so the module asks transmute's rules; under the same POSIX zone the naive n370 migrates (a naive grid
-- is UTC, so the rule is not asked of it); and z370 and i370 (its row corrected and its chunk dropped, the remedy
-- as the message gives it) migrate afterwards, by row. bench/hypertable_infinity_and_session_zone.sh runs this
-- file against the mutants that put each defect back; it must FAIL there.
select plan(23);

create table public.i370 (id bigint not null, ts timestamptz not null, primary key (id, ts));
select create_hypertable('public.i370', 'ts', chunk_time_interval => interval '7 days');
insert into public.i370 values (1, now() - interval '20 days'), (2, now() - interval '1 day'), (3, 'infinity');
create table public.f370 (id bigint not null, ts timestamptz not null, primary key (id, ts));
select create_hypertable('public.f370', 'ts', chunk_time_interval => interval '7 days');
insert into public.f370 values (10, now() - interval '3 days'), (20, now() + interval '400 days');
create table public.j370 (id bigint not null, ts timestamptz not null, primary key (id, ts));
select create_hypertable('public.j370', 'ts', chunk_time_interval => interval '7 days');
insert into public.j370 values (5, now() - interval '10 days'), (6, now() - interval '3 hours');
create table public.z370 (ts timestamptz not null, v int not null);
select create_hypertable('public.z370', 'ts', chunk_time_interval => interval '7 days');
insert into public.z370 select date_trunc('hour', now()) - (g - 30) * interval '5 hours', g from generate_series(31, 34) g;
create table public.n370 (ts timestamp not null, v int not null);
select create_hypertable('public.n370', 'ts', chunk_time_interval => interval '7 days');
insert into public.n370 values (localtimestamp - interval '2 days', 41), (localtimestamp - interval '1 hour', 42);
create table public.p370 (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.p370 values (1, now() - interval '1 day'), (2, 'infinity');
create table public.q370 (id bigint primary key, ts timestamptz not null);
insert into public.q370 values (1, now() - interval '1 day');

-- ============================ #1328: the rules are transmute's ============================
select is((select max(ts) from public.i370), 'infinity'::timestamptz,
  'LIVENESS: TimescaleDB holds an infinity row: i370''s newest value is infinity');
select is((select range_end from timescaledb_information.chunks where hypertable_name = 'i370' order by range_start desc limit 1),
  'infinity'::timestamptz, 'LIVENESS: the infinity row sits in a chunk whose range ends at infinity');
select throws_like(
  $$ call pgpm.transmute('public.p370', 'ts', interval '7 days') $$,
  'pg_partition_magician: p370 cannot be partitioned on a time grid using ts: its newest value is infinity%',
  'LIVENESS: transmute refuses an infinity newest value on a plain table');
select throws_like(
  $$ call pgpm.from_hypertable('public.f370', 'ts', interval '7 days') $$,
  'pg_partition_magician: cannot migrate hypertable f370 with p_interval 7 days -- refused before anything is changed, %its newest ts is % which is % ahead of now()%',
  'LIVENESS: a finite far-future newest value reaches the frontier refusal, in pgpm''s words');

-- ============================ #1328: the contract ============================
select format('%I.%I', chunk_schema, chunk_name) as ichunk from timescaledb_information.chunks
 where hypertable_name = 'i370' and range_end = 'infinity' \gset
select throws_like(
  $$ call pgpm.from_hypertable('public.i370', 'ts', interval '7 days') $$,
  'pg_partition_magician: cannot migrate hypertable i370 -- refused before anything is changed, %its newest ts is infinity, and no partition can hold it%Delete or correct the rows whose ts is infinity, then drop the chunk TimescaleDB made for them once it is empty (DROP TABLE ' || :'ichunk' || ';%',
  'from_hypertable refuses an infinity newest value in pgpm''s words, naming the chunk to drop, not raw 22008 (#1328)');
select throws_like(
  $$ call pgpm.from_hypertable('public.i370', 'ts', interval '7 days', p_force_frontier => true) $$,
  'pg_partition_magician: cannot migrate hypertable i370 -- refused before anything is changed, %its newest ts is infinity%p_force_frontier does not accept it either%',
  'from_hypertable refuses it with p_force_frontier too, before its copy');
select throws_like(
  $$ call pgpm.from_hypertable_copy('public.i370', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable i370 -- refused before anything is changed: its chunk ' || :'ichunk' || ' covers a range that ends at infinity%',
  'from_hypertable_copy refuses it before it commits anything, not raw on the chunk that holds it');
select ok(exists (select 1 from timescaledb_information.hypertables where hypertable_name = 'i370')
          and (select array_agg(id order by id) from public.i370) = array[1, 2, 3]::bigint[]
          and not exists (select 1 from pgpm.scratch s where s.parent_oid = 'public.i370'::regclass::oid)
          and to_regclass('public.i370_pgpm_dest') is null,
  'INVARIANT: i370 is still a hypertable holding rows 1, 2 and 3, with no copy made or recorded');
-- half the remedy: the row deleted, the chunk left
delete from public.i370 where id = 3;
select throws_like(
  $$ call pgpm.from_hypertable_copy('public.i370', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable i370 -- refused before anything is changed: its chunk ' || :'ichunk' || ' covers a range that ends at infinity%DROP TABLE ' || :'ichunk' || '%',
  'with the row deleted, the copy still refuses the empty chunk it cannot read, naming the DROP');

-- the two-phase path: a copy made while the newest value was finite, then the cutover, which asks under its lock
call pgpm.from_hypertable_copy('public.j370', 'ts');
select ok(to_regclass('public.j370_pgpm_dest') is not null,
  'LIVENESS: the copy, made while the newest value was finite, succeeded');
insert into public.j370 values (7, 'infinity');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.j370', 'ts', interval '7 days', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable j370 -- refused before anything is changed, %its newest ts is infinity%',
  'the cutover refuses an infinity row that arrived after the copy, in pgpm''s words, before its swap');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.j370', 'ts', interval '7 days', p_predrain => false, p_force_frontier => true) $$,
  'pg_partition_magician: cannot migrate hypertable j370 -- refused before anything is changed, %its newest ts is infinity%',
  'and with p_force_frontier too');
select ok(exists (select 1 from timescaledb_information.hypertables where hypertable_name = 'j370')
          and (select array_agg(id order by id) from public.j370) = array[5, 6, 7]::bigint[],
  'INVARIANT: j370 is still the hypertable holding rows 5, 6 and 7');

-- the remedy works, as the message gives it: correct the row, drop the chunk, re-run
insert into public.i370 values (3, now() - interval '2 hours');
drop table :ichunk;
call pgpm.from_hypertable('public.i370', 'ts', interval '7 days', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.i370'::regclass) || ':'
          || (select string_agg(id::text, ',' order by id) from public.i370), 'p:1,2,3',
  'the remedy: with the row corrected and its chunk dropped, i370 migrates holding rows 1, 2 and 3');

-- ============================ #1221: the rule is transmute's ============================
set timezone = 'UTC+3';
select is(current_setting('TimeZone') || ':' || (pgpm._canonical_tz(current_setting('TimeZone')) is null)::text, 'UTC+3:true',
  'LIVENESS: the session runs under UTC+3, a zone _canonical_tz does not record');
select throws_like(
  $$ call pgpm.transmute('public.q370', 'ts', interval '1 day') $$,
  'pg_partition_magician: this session''s TimeZone (UTC+3) is not a zone pgpm can record%',
  'LIVENESS: transmute refuses the session zone on a plain timestamptz table');

-- ============================ #1221: the contract ============================
select throws_like(
  $$ call pgpm.from_hypertable('public.z370', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot migrate hypertable z370 -- refused before anything is changed, %this session''s TimeZone (UTC+3) is not a zone pgpm can record%re-run pgpm.from_hypertable%',
  'from_hypertable refuses the session zone before its copy (#1221)');
call pgpm.from_hypertable_copy('public.z370', 'ts');
select ok(to_regclass('public.z370_pgpm_dest') is not null,
  'LIVENESS: the two-phase copy runs under the zone (it hands nothing to transmute)');
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.z370', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable z370 -- refused before anything is changed, %this session''s TimeZone (UTC+3) is not a zone pgpm can record%',
  'the cutover refuses the session zone before its swap');
select ok(exists (select 1 from timescaledb_information.hypertables where hypertable_name = 'z370')
          and (select array_agg(v order by v) from public.z370) = array[31, 32, 33, 34],
  'INVARIANT: z370 is still the hypertable holding 31 to 34');
-- the naive dimension is not asked: its grid is UTC whatever the session's zone
call pgpm.from_hypertable('public.n370', 'ts', interval '1 day', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.n370'::regclass) || ':'
          || (select string_agg(v::text, ',' order by v) from public.n370) || ':'
          || (select partition_tz from pgpm.config where parent_table = 'public.n370'::regclass), 'p:41,42:UTC',
  'LIVENESS: under the same zone a naive timestamp hypertable migrates (its grid is UTC), so the rule is asked of timestamptz alone');

-- the remedy works: a named zone, then the cutover (the copy is the one made above)
set timezone = 'UTC';
call pgpm.from_hypertable_cutover('public.z370', 'ts', interval '1 day', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.z370'::regclass) || ':'
          || (select string_agg(v::text, ',' order by v) from public.z370) || ':'
          || (select partition_tz from pgpm.config where parent_table = 'public.z370'::regclass), 'p:31,32,33,34:UTC',
  'the remedy: under a named zone the cutover migrates z370 holding 31 to 34, its grid recorded in UTC');
select is((select count(*)::int from pgpm.config where parent_table in ('public.i370'::regclass, 'public.n370'::regclass, 'public.z370'::regclass)), 3,
  'and pgpm manages the three migrated tables');

select * from finish();
