-- maintain_obtain's back-off is honoured only over a lookahead that is BUILT, not one pgpm.part merely
-- records (issue #1078).
--
-- THE BUG. After a lost lock race arms config.obtain_retry_after, maintain_obtain sits obtain out while at
-- least ceil(obtain / 2) complete grid steps of attached coverage remain beyond the frontier's own cell.
-- It measured that by walking grid steps from the frontier's cell up to max(hi) of the attached rows,
-- assuming the coverage was contiguous. A forward cell dropped (or detached) by hand is a hole inside that
-- span: every write into it is refused, obtain would rebuild it (#908, #956), yet the walk counted it as
-- coverage, so the next tick logged obtain_backoff and the hole stayed open for the whole back-off.
--
-- THE CONTRACT. Each step of the walk, the frontier's own cell included, is judged by the predicate obtain
-- itself uses (_part_built, through _cell_attached): a step counts only when an attached partition that is
-- BUILT overlaps it. A hole within the frontier's cell or the ceil(obtain / 2) steps past it bypasses the
-- back-off and obtain rebuilds it; past that span the back-off still holds.
--   PART A  the issue's reproduction: a real lock race (a second session holds the parent) arms the
--           back-off with the first forward cell [1000, 2000) dropped. The next tick bypasses the back-off,
--           forgets the dead row, rebuilds the cell, a write into it lands, and the back-off is cleared.
--   PART B  what the back-off still protects: the third forward cell [3000, 4000) dropped, past the two
--           built steps the threshold asks for. The tick honours the back-off and builds nothing; the
--           witness tick, back-off cleared, rebuilds it (so obtain had work it was kept from).
--   PART C  the second forward cell [2000, 3000) DETACHED by hand: a hole as much as a dropped one. The
--           tick bypasses, rebuilds the cell beside the detached table, and leaves that table alone.
--   PART D  the frontier's OWN cell dropped (a time grid, where now() has moved into a forward cell): the
--           walk judges it too, so the tick bypasses and rebuilds it, and a write at now() lands.
--   PART E  a healthy lookahead: the back-off is honoured, as before.
--   PART F  a hole obtain CANNOT build: [2000, 3000) dropped and its name taken by a stranger table (#710).
--           obtain would only log fail_obtain_name for it, so it is no reason to bypass: under sustained
--           contention (a second session holds the parent across both ticks) the tick after the lost race
--           honours the back-off and queues no second lock attempt, though the top cell [4000, 5000) is
--           missing too and obtain would have tried for it.
-- The fixtures are asymmetric on purpose: the hole sits at a different step in each part (first, third,
-- second, the frontier's own), so a walk that counted holes, or always bypassed, or never did, cannot pass;
-- and F's unbuildable hole sits where A's buildable one would bypass.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(40);

-- ==================== (A) the issue's reproduction: a real lock race, first forward cell dropped ====================
create table public.bh298a (id bigint primary key, payload text);
insert into public.bh298a select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.bh298a', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
select child_name as a_hole, child_oid as a_hole_oid from pgpm.part
 where parent_table = 'public.bh298a'::regclass and lo = '1000' \gset
select format('drop table public.%I', :'a_hole') \gexec

-- a second session holds a lock on the parent, so this tick's obtain loses the race and arms the back-off
select dblink_connect('bh298', format('dbname=%s user=postgres', current_database())) as a_conn \gset
select dblink_exec('bh298', 'begin') as a_begin \gset
select dblink_exec('bh298', 'lock table public.bh298a in access share mode') as a_lock \gset
call pgpm.maintain_obtain('public.bh298a') \gset a_race_
select dblink_exec('bh298', 'commit') as a_commit \gset
select dblink_disconnect('bh298') as a_disc \gset

select is(:'a_race_p_status'::text, 'obtained=0 obtain_deferred'::text, 'LIVENESS: A''s first tick lost the lock race');
select ok((select obtain_retry_after > clock_timestamp() from pgpm.config where parent_table = 'public.bh298a'::regclass),
  'LIVENESS: the lost race armed the obtain back-off');
select ok(not exists (select 1 from pg_inherits where inhparent = 'public.bh298a'::regclass and inhrelid = :'a_hole_oid'::oid),
  'LIVENESS: the forward cell [1000, 2000) is a hole: its partition is gone');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.bh298a'::regclass and attached
                   and lo = '1000' and child_oid = :'a_hole_oid'::oid),
  'LIVENESS: its pgpm.part row is still attached (the state the walk counted as coverage)');
select throws_ok($$insert into public.bh298a values (1500, 'into the hole')$$, '23514', NULL,
  'LIVENESS: a write into the hole is refused');

create temporary table mark298a as select coalesce(max(id), 0) as id from pgpm.log;
-- the next tick, nothing holding the parent, the back-off still armed
call pgpm.maintain_obtain('public.bh298a') \gset a_next_

select is(:'a_next_p_status'::text, 'obtained=1 obtain_backoff_bypassed'::text,
  'A: a hole within the threshold bypasses the back-off, and obtain builds exactly the one cell');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.bh298a'::regclass and i.inhparent = 'public.bh298a'::regclass
                     and p.attached and p.lo = '1000' and p.hi = '2000' and p.child_oid <> :'a_hole_oid'::oid),
  'A: [1000, 2000) is rebuilt as a new partition of the table');
select is((select array_agg(action || ':' || lo order by id) from pgpm.log
            where parent_table = 'public.bh298a'::regclass and id > (select id from mark298a)
              and action = 'forget_dropped_partition'),
  array['forget_dropped_partition:1000'], 'A: obtain forgot exactly the dead row of [1000, 2000)');
select is((select obtain_retry_after from pgpm.config where parent_table = 'public.bh298a'::regclass), null,
  'A: the successful obtain cleared the back-off');
select lives_ok($$insert into public.bh298a values (1500, 'into the hole')$$, 'A: a write into [1000, 2000) lands');

-- ==================== (B) a hole past the threshold: the back-off still holds ====================
create table public.bh298b (id bigint primary key, payload text);
insert into public.bh298b select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.bh298b', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
select child_name as b_hole, child_oid as b_hole_oid from pgpm.part
 where parent_table = 'public.bh298b'::regclass and lo = '3000' \gset
select format('drop table public.%I', :'b_hole') \gexec
update pgpm.config set obtain_retry_after = clock_timestamp() + interval '1 hour'
 where parent_table = 'public.bh298b'::regclass;

select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = 'public.bh298b'::regclass and i.inhparent = 'public.bh298b'::regclass
              and p.lo in ('0', '1000', '2000', '3000', '4000')),
  array['0', '1000', '2000', '4000'],
  'LIVENESS: the frontier''s cell and the two steps past it are built, [3000, 4000) is a hole');

call pgpm.maintain_obtain('public.bh298b') \gset b_tick_
select is(:'b_tick_p_status'::text, 'obtained=0 obtain_backoff'::text,
  'B: two built steps precede the hole (not < ceil(4/2)), so the back-off is honoured');
select ok(not exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                       where p.parent_table = 'public.bh298b'::regclass and i.inhparent = 'public.bh298b'::regclass
                         and p.lo = '3000'),
  'B: the hole past the threshold is left for the tick after the back-off');
select ok((select obtain_retry_after > clock_timestamp() from pgpm.config where parent_table = 'public.bh298b'::regclass),
  'B: the back-off is still in place');

-- the witness: the same tick with the back-off cleared does rebuild it, so B's tick was kept from real work
update pgpm.config set obtain_retry_after = null where parent_table = 'public.bh298b'::regclass;
call pgpm.maintain_obtain('public.bh298b') \gset b_wit_
select is(:'b_wit_p_status'::text, 'obtained=1'::text, 'B witness: without the back-off the tick builds one cell');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.bh298b'::regclass and i.inhparent = 'public.bh298b'::regclass
                     and p.lo = '3000' and p.hi = '4000' and p.child_oid <> :'b_hole_oid'::oid),
  'B witness: and that cell is [3000, 4000)');

-- ==================== (C) the second forward cell detached by hand ====================
create table public.bh298c (id bigint primary key, payload text);
insert into public.bh298c select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.bh298c', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
select child_name as c_hole, child_oid as c_hole_oid from pgpm.part
 where parent_table = 'public.bh298c'::regclass and lo = '2000' \gset
select format('alter table public.bh298c detach partition public.%I', :'c_hole') \gexec
update pgpm.config set obtain_retry_after = clock_timestamp() + interval '1 hour'
 where parent_table = 'public.bh298c'::regclass;

select ok(exists (select 1 from pg_class where oid = :'c_hole_oid'::oid)
          and not exists (select 1 from pg_inherits where inhrelid = :'c_hole_oid'::oid),
  'LIVENESS: [2000, 3000)''s table still exists but is no longer a partition of the table');
select throws_ok($$insert into public.bh298c values (2500, 'into the hole')$$, '23514', NULL,
  'LIVENESS: a write into the detached cell''s range is refused');

create temporary table mark298c as select coalesce(max(id), 0) as id from pgpm.log;
call pgpm.maintain_obtain('public.bh298c') \gset c_tick_
select is(:'c_tick_p_status'::text, 'obtained=1 obtain_backoff_bypassed'::text,
  'C: a detached cell within the threshold bypasses the back-off');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.bh298c'::regclass and i.inhparent = 'public.bh298c'::regclass
                     and p.attached and p.lo = '2000' and p.hi = '3000' and p.child_oid <> :'c_hole_oid'::oid),
  'C: [2000, 3000) is rebuilt as a new partition beside the detached table');
select is((select array_agg(action || ':' || lo order by id) from pgpm.log
            where parent_table = 'public.bh298c'::regclass and id > (select id from mark298c)
              and action in ('forget_dropped_partition', 'forget_detached_partition')),
  array['forget_detached_partition:2000'], 'C: obtain forgot exactly the detached row of [2000, 3000)');
select ok(exists (select 1 from pg_class where oid = :'c_hole_oid'::oid and relname = :'c_hole'),
  'C: the detached table is left exactly where the operator put it');
select lives_ok($$insert into public.bh298c values (2500, 'into the hole')$$, 'C: a write into [2000, 3000) lands');

-- ==================== (D) the frontier's own cell dropped, on a time grid ====================
-- A one-minute grid anchored so that now() sits about 58 seconds into the cell transmute's monolith ends
-- with; after a 2.5 second sleep now() lies in the first forward cell obtain built, and stays there for
-- about 57 seconds, far longer than the rest of this part takes.
create table public.bh298d (id bigint, ts timestamptz not null, primary key (ts, id));
insert into public.bh298d select g, now() - interval '2 hours' + g * interval '1 second' from generate_series(1, 300) g;
call pgpm.transmute('public.bh298d', 'ts', interval '1 minute', p_obtain => 4,
  p_anchor => date_trunc('second', clock_timestamp()) - interval '58 seconds', p_paused => false);
select pg_sleep(2.5);
-- a new transaction, so now() below is past the sleep
select p.child_name as d_hole, p.child_oid as d_hole_oid, p.lo as d_lo from pgpm.part p
 where p.parent_table = 'public.bh298d'::regclass and p.attached
   and p.lo::timestamptz <= now() and now() < p.hi::timestamptz \gset

select ok(:'d_lo'::timestamptz > (select min(lo::timestamptz) from pgpm.part where parent_table = 'public.bh298d'::regclass),
  'LIVENESS: now() lies in a forward cell obtain built, not in the monolith');
select format('drop table public.%I', :'d_hole') \gexec
update pgpm.config set obtain_retry_after = clock_timestamp() + interval '1 hour'
 where parent_table = 'public.bh298d'::regclass;
select is((select count(*)::int from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = 'public.bh298d'::regclass and i.inhparent = 'public.bh298d'::regclass
              and p.lo::timestamptz > :'d_lo'::timestamptz),
  3, 'LIVENESS: the three steps past the frontier''s cell are built (the threshold asks for two)');
select throws_ok($$insert into public.bh298d values (1, now())$$, '23514', NULL,
  'LIVENESS: a write at now() is refused');

call pgpm.maintain_obtain('public.bh298d') \gset d_tick_
select is(:'d_tick_p_status'::text, 'obtained=2 obtain_backoff_bypassed'::text,
  'D: the frontier''s own cell being a hole bypasses the back-off (obtain builds it and the new top cell)');
select ok(exists (select 1 from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
                   where p.parent_table = 'public.bh298d'::regclass and i.inhparent = 'public.bh298d'::regclass
                     and p.lo = :'d_lo' and p.child_oid <> :'d_hole_oid'::oid),
  'D: the frontier''s cell is rebuilt as a new partition of the table');
select lives_ok($$insert into public.bh298d values (1, now())$$, 'D: a write at now() lands');

-- ==================== a healthy lookahead: the back-off is honoured (the pre-existing contract) ====================
create table public.bh298e (id bigint primary key, payload text);
insert into public.bh298e select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.bh298e', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
insert into public.bh298e values (2001, 'frontier into [2000, 3000)');
update pgpm.config set obtain_retry_after = clock_timestamp() + interval '1 hour'
 where parent_table = 'public.bh298e'::regclass;
call pgpm.maintain_obtain('public.bh298e') \gset e_tick_
select is(:'e_tick_p_status'::text, 'obtained=0 obtain_backoff'::text,
  'E: with no hole and two built steps past the frontier''s cell, the back-off is honoured');
update pgpm.config set obtain_retry_after = null where parent_table = 'public.bh298e'::regclass;
call pgpm.maintain_obtain('public.bh298e') \gset e_wit_
select is(:'e_wit_p_status'::text, 'obtained=2'::text, 'E witness: without the back-off the same tick builds two cells');

-- ==================== (F) a hole obtain cannot build: the back-off holds ====================
create table public.bh298f (id bigint primary key, payload text);
insert into public.bh298f select g, 'x' from generate_series(1, 500) g;
call pgpm.transmute('public.bh298f', 'id', 1000::bigint, p_obtain => 4, p_paused => false);
-- [2000, 3000) dropped by hand and its name taken by a stranger, so obtain cannot build it
select child_name as f_held from pgpm.part where parent_table = 'public.bh298f'::regclass and lo = '2000' \gset
select format('drop table public.%I', :'f_held') \gexec
select format('create table public.%I (x int)', :'f_held') \gexec
select to_regclass(format('public.%I', :'f_held'))::oid as f_stranger_oid \gset
-- the top cell [4000, 5000) dropped too, past the threshold: a cell obtain CAN build, so a tick that runs
-- obtain takes the parent's lock for it
select child_name as f_top from pgpm.part where parent_table = 'public.bh298f'::regclass and lo = '4000' \gset
select format('drop table public.%I', :'f_top') \gexec

-- sustained contention: a second session holds the parent across both ticks below
select dblink_connect('bh298f', format('dbname=%s user=postgres', current_database())) as f_conn \gset
select dblink_exec('bh298f', 'begin') as f_begin \gset
select dblink_exec('bh298f', 'lock table public.bh298f in access share mode') as f_lock \gset
call pgpm.maintain_obtain('public.bh298f') \gset f_race_
create temporary table mark298f as select coalesce(max(id), 0) as id from pgpm.log;
call pgpm.maintain_obtain('public.bh298f') \gset f_tick_
select dblink_exec('bh298f', 'commit') as f_commit \gset
select dblink_disconnect('bh298f') as f_disc \gset

select is(:'f_race_p_status'::text, 'obtained=0 obtain_deferred'::text,
  'LIVENESS: F''s first tick lost the lock race (obtain had a cell to build and queued the lock)');
select ok((select obtain_retry_after > clock_timestamp() from pgpm.config where parent_table = 'public.bh298f'::regclass),
  'LIVENESS: the lost race armed the obtain back-off');
select ok(:'f_stranger_oid'::oid is not null
          and to_regclass(format('public.%I', :'f_held'))::oid = :'f_stranger_oid'::oid
          and not exists (select 1 from pg_inherits where inhrelid = :'f_stranger_oid'::oid),
  'LIVENESS: [2000, 3000)''s plain name is held by a stranger table that is no partition');
select is((select array_agg(p.lo order by p.lo::numeric) from pgpm.part p join pg_inherits i on i.inhrelid = p.child_oid
            where p.parent_table = 'public.bh298f'::regclass and i.inhparent = 'public.bh298f'::regclass),
  array['0', '1000', '3000'], 'GUARD: [0, 1000), [1000, 2000) and [3000, 4000) are built, nothing else');

select is(:'f_tick_p_status'::text, 'obtained=0 obtain_backoff'::text,
  'F: a hole obtain cannot build does not bypass the back-off');
select is((select count(*)::int from pgpm.log where parent_table = 'public.bh298f'::regclass
            and id > (select id from mark298f) and action = 'skip_obtain'), 0,
  'F: no second lock attempt was queued behind the contention inside the back-off window');
select ok(exists (select 1 from pg_class where oid = :'f_stranger_oid'::oid and relname = :'f_held'),
  'F: the stranger is left exactly as it is');

-- the witness: the back-off cleared and the contention gone, the same tick builds the top cell and logs the
-- held cell as one it cannot build, so F's tick was kept from real work and the hole is really unbuildable
update pgpm.config set obtain_retry_after = null where parent_table = 'public.bh298f'::regclass;
create temporary table mark298f2 as select coalesce(max(id), 0) as id from pgpm.log;
call pgpm.maintain_obtain('public.bh298f') \gset f_wit_
select is(:'f_wit_p_status'::text, 'obtained=1'::text, 'F witness: without the back-off the tick builds one cell');
select is((select array_agg(action || ':' || lo order by id) from pgpm.log
            where parent_table = 'public.bh298f'::regclass and id > (select id from mark298f2)
              and (action in ('fail_obtain_name', 'skip_obtain') or (action = 'forget_dropped_partition' and lo = '4000'))),
  array['fail_obtain_name:2000', 'forget_dropped_partition:4000'],
  'F witness: it cannot build [2000, 3000) (fail_obtain_name) and rebuilds [4000, 5000)');

select * from finish();
