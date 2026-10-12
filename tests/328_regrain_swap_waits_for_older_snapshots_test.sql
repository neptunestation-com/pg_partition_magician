-- The regrain swap waits for every snapshot that cannot see its copies, so a REPEATABLE READ reader whose snapshot
-- predates the copies never reads the regrained range empty (issue #1241).
--
-- THE BUG. regrain_step's swap detaches and drops the coarse source and attaches fine children whose rows were
-- written by copy transactions that committed after the reader's snapshot was taken. No snapshot can see rows
-- written after it, so a reader whose transaction spans the swap, and whose first touch of the table comes after
-- it (it held no lock, so nothing made the DETACH wait for it), read the fine children and found the range
-- empty: 1 row of 501 in the reproduction, with no error. docs/guide.md promised the opposite.
--
-- THE CONTRACT.
--   PART A  the issue's own path, auto-regrain through maintain(): with the reader open, the tick that reaches
--           the swap defers it, logged skip_regrain naming the reader by pid, and leaves the same source attached;
--           the reader reads exactly the rows it should; once it commits, the next tick swaps.
--   PART B  the hand driver, pgpm.regrain(), which copies in the swap's own transaction: it waits for a reader
--           whose transaction began before the call, under its caller's lock_timeout, and raises when the reader
--           outlasts it, the copies rolled back with it; once the reader commits it regrains.
--   PART C  the one exemption: a session waiting on a lock the regrain holds (a READ COMMITTED write queued behind
--           regrain()'s SHARE lock, #580) can never release its snapshot while the regrain waits for it, so the
--           wait passes it, naming it, and regrain() completes; the write lands in the fine children after.
--   PART D  the snapshots waited for are those older than the run's LAST write into its fine children, not its
--           first: a reader opened between the first copy and the last sees some copies and not the others, and
--           is waited for the same way.
--   PART E  the wait sees what any caller sees: maintain run by the table's non-superuser owner, without
--           pg_read_all_stats, against a reader in another role, whose backend_type and xact_start read NULL to the
--           owner. The reader is waited for exactly as in part A.
--   PART F  under regrain(), which copies in the swap's own transaction, a REPEATABLE READ reader that opened during
--           the call (before its copies committed) is waited for too, not only one older than the call, and stays
--           waited for when it starts its next statement during the wait (its snapshot is the same).
--   PART G  no exemption by state: under maintain, a reader in the middle of a statement when the budget runs out
--           defers the swap exactly as an idle one does; the swap never goes ahead under it.
--   PART H  the hand driver regrain() run by the table's non-superuser owner, without pg_read_all_stats, against a
--           reader in another role opened before the call, whose state and xact_start read NULL to the owner: the
--           reader is waited for as in part B.
--   PART I  the wait reads the sessions afresh on every poll: a REPEATABLE READ transaction that IMPORTS a snapshot
--           older than the copies (SET TRANSACTION SNAPSHOT of one another transaction exported) after the wait began
--           is waited for once the exporter has gone, and the hand regrain_step refuses rather than swap under it.
--   PART J  the same against the caller's own xid (regrain()), with a writer idle in its transaction since before the
--           exporter's snapshot: the importer's xmin EQUALS that writer's xid, the oldest still running, and it is
--           waited for all the same (at or before the newest snapshot open when the wait began).
--   PART K  the same for a run in flight across the upgrade that added config.regrain_written_xid (no recorded last
--           write, so the own-xid rule), driven by a hand regrain_step.
--   PART L  against the caller's own xid, a READ COMMITTED session E exports S1 while a writer runs and, after the
--           writer commits, a newer S2, both before regrain() is called; B imports S2 after the wait began. E's
--           backend_xmin is S1's (the oldest it holds), B's is S2's: B is waited for all the same, as every snapshot
--           older than the caller's transaction is.
--   PART M  the same for a run in flight across the upgrade (no recorded last write), driven by a hand regrain_step.
--   PART N  against the caller's own xid, a REPEATABLE READ session A opened just before regrain(), whose xmin IS the
--           call's xid (the next xid when A took its snapshot), exports it; B imports it after the wait began. B is
--           waited for: regrain() waits for every snapshot at or before its own xid, not only strictly older ones.
--   PART O  a REPEATABLE READ reader R, its snapshot older than every copy, queues its first read behind an
--           ordinary DDL that is itself queued behind a hand regrain_step's own read of the frontier (R -> DDL ->
--           step in pg_blocking_pids), the step under lock_timeout 0. R can never release its snapshot before the
--           swap, so it is neither passed nor waited for: the step refuses AT ONCE, naming R and the lock queued on
--           (releasing its lock), the DDL completes, R reads every row, and once R commits a maintain tick swaps.
--   PART P  the same chain against regrain() (copies and swap in one transaction, lock_timeout 0): a DDL queued
--           behind regrain()'s SHARE lock and an ordinary READ COMMITTED SELECT queued behind the DDL. regrain()
--           refuses at once instead of polling for the SELECT for ever; the DDL and the SELECT then complete.
--   PART Q  the same chain under maintain: the tick defers AT ONCE, logged skip_regrain naming the reader and the
--           lock, not after its budget.
--   PART R  two hand regrain() calls on two parents under lock_timeout 0, each listing the other's snapshot and
--           neither blocked on a lock of the other. The younger (M2) is in its wait first; the older (M1) then enters
--           its own. The younger yields AT ONCE naming the older, the older completes and swaps, and the younger's
--           re-run swaps. Neither waits for the other for ever, and the older never yields to the younger.
--   PART S  the same between a hand regrain_step (younger, against its run's recorded last write) already in its
--           wait and a regrain() (older) that enters its own: the step yields, regrain() completes.
--   PART T  a maintain tick against a hand regrain() (older) in its wait: the tick defers AT ONCE, skip_regrain
--           naming it; regrain() completes once its own reader ends, and the next tick swaps.
--           Every driver session in R to T runs under a statement_timeout, so a wait that came back fails by it.
--
--
-- Every negative is paired with its premise: the copies ran, the reader's snapshot cannot see them (it does not
-- even see their log rows), the reader holds no lock on the table, and the run is at the swap (the cursor at hi).
-- regrain() is a function, not a committing procedure, so its refusals are pinned by message.
-- ASYMMETRIC FIXTURES. A holds 1..500 without the multiples of 7, B the multiples of 3 to 297, C the even ids to
-- 400, D the multiples of 5 to 495, E the multiples of 6 to 498, F the multiples of 4 to 400, G the multiples of 8
-- to 496, H the multiples of 9 to 495, I the multiples of 11 to 495, J the multiples of 12 to 492, K the multiples of
-- 13 to 494, L the multiples of 14 to 490, M the multiples of 15 to 495, N the multiples of 16 to 496, each with its
-- own frontier row (O the multiples of 17 to 493, P of 18 to 486, Q of 19 to 494, R1 of 20 to 480, R2 of 21 to
-- 483, S1 of 22 to 484, S2 of 23 to 483, T1 of 24 to 480, T2 of 25 to 475), so an assertion aimed at the wrong table or
-- the wrong rows cannot pass; every row check names the ids.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(165);

-- ============================================ PART A ============================================
create table public.t328a (id bigint generated by default as identity primary key, payload text);
insert into public.t328a (id, payload) select g, 'a' || g from generate_series(1, 500) g where g % 7 <> 0;
call pgpm.transmute('public.t328a', 'id', 100, p_paused => false);                  -- monolith [0, 600)
insert into public.t328a (id, payload) values (2000, 'frontier');                    -- freezes the monolith
select pgpm.set_regrain('public.t328a', '100');
create temp table t328a_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328a'::regclass and p.attached and p.lo = '0';

-- the reader: REPEATABLE READ, its snapshot taken now, before any copy, and holding no lock on the table
select dblink_connect('r328a', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328a', 'begin isolation level repeatable read');
create temp table t328a_reader as
  select pid from dblink('r328a', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);

do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328a', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400), (500) $$,
  'LIVENESS: the copies ran, one batch for each of the six sub-ranges of [0, 600)');
select is((select n from dblink('r328a', $q$select count(*) from pgpm.log where action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: the reader''s snapshot predates every copy (it cannot see even their log rows)');
select is((select count(*) from pg_locks l, t328a_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328a'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328a'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328a'::regclass)),
  0::bigint, 'LIVENESS: the reader holds no lock on the table or any of its partitions, so no lock made the swap wait');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328a'::regclass) = '600'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'), 0::bigint,
  'the swap did not run while the reader was open');
select ok(exists (select 1 from pgpm.log l, t328a_reader r
                   where l.parent_table = 'public.t328a'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'the tick deferred it, logged skip_regrain naming the reader by pid');
select is((select p.child_oid from pgpm.part p join t328a_src s using (child_name)
            where p.parent_table = 'public.t328a'::regclass and p.attached
              and exists (select 1 from pg_inherits i where i.inhparent = 'public.t328a'::regclass and i.inhrelid = p.child_oid)),
  (select child_oid from t328a_src),
  'the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328a', 'select id from public.t328a') as t(id bigint) $$,
  $$ select g::bigint from generate_series(1, 500) g where g % 7 <> 0 union all select 2000 $$,
  'the reader reads exactly the rows its snapshot holds: 1..500 without the multiples of 7, and 2000');
select dblink_exec('r328a', 'commit');

do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328a', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328a'::regclass and action = 'regrain'), 1::bigint,
  'once the reader committed, the next tick swapped');
select bag_eq(
  $$ select lo::bigint, hi::bigint from pgpm.part where parent_table = 'public.t328a'::regclass and attached and hi::bigint <= 600 $$,
  $$ values (0::bigint, 100::bigint), (100, 200), (200, 300), (300, 400), (400, 500), (500, 600) $$,
  'the six fine children are attached in the source''s place');
select ok(not exists (select 1 from pg_class c, t328a_src s where c.oid = s.child_oid), 'and the source is dropped');
select bag_eq(
  $$ select id from public.t328a $$,
  $$ select g::bigint from generate_series(1, 500) g where g % 7 <> 0 union all select 2000 $$,
  'a fresh read after the swap holds exactly the same rows');

-- ============================================ PART B ============================================
create table public.t328b (id bigint generated by default as identity primary key, payload text);
insert into public.t328b (id, payload) select g, 'b' || g from generate_series(3, 297, 3) g;
call pgpm.transmute('public.t328b', 'id', 100, p_paused => false);                  -- monolith [0, 300)
insert into public.t328b (id, payload) values (1500, 'frontier');
create temp table t328b_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328b'::regclass and p.attached and p.lo = '0';
select is((select count(*) from t328b_src), 1::bigint, 'LIVENESS: B has a monolith at lo 0 to regrain');

select dblink_connect('r328b', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328b', 'begin isolation level repeatable read');
create temp table t328b_reader as
  select pid from dblink('r328b', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);

set lock_timeout = '300ms';
select throws_like(
  format($$ select pgpm.regrain('public.t328b', %L, '100') $$, (select child_name from t328b_src)),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from t328b_reader) || ',%',
  'regrain() waits for the reader under its lock_timeout and refuses the swap when the reader outlasts it');
reset lock_timeout;
select is((select count(*) from pgpm.part where parent_table = 'public.t328b'::regclass and not attached), 0::bigint,
  'the refusal rolled the copies back with it');
select is((select p.child_oid from pgpm.part p join t328b_src s using (child_name)
            where p.parent_table = 'public.t328b'::regclass and p.attached),
  (select child_oid from t328b_src), 'and the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328b', 'select id from public.t328b') as t(id bigint) $$,
  $$ select g::bigint from generate_series(3, 297, 3) g union all select 1500 $$,
  'the reader reads exactly its rows: the multiples of 3 to 297, and 1500');
select dblink_exec('r328b', 'commit');
select is(pgpm.regrain('public.t328b', (select child_name from t328b_src), '100'), 3,
  'LIVENESS: once the reader committed, regrain() splits the monolith into its three fine children');
select bag_eq(
  $$ select id from public.t328b $$,
  $$ select g::bigint from generate_series(3, 297, 3) g union all select 1500 $$,
  'and every row is read after it');

-- ============================================ PART C ============================================
create table public.t328c (id bigint generated by default as identity primary key, payload text);
insert into public.t328c (id, payload) select g, 'c' || g from generate_series(2, 400, 2) g;
call pgpm.transmute('public.t328c', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328c (id, payload) values (1700, 'frontier');
create temp table t328c_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328c'::regclass and p.attached and p.lo = '0';
select is((select count(*) from t328c_src), 1::bigint, 'LIVENESS: C has a monolith at lo 0 to regrain');

select dblink_connect('r328c', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328c', 'begin');
create temp table t328c_reader as
  select pid from dblink('r328c', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);
create temp table t328c_passed (passed int[], err text);

-- this session drives the regrain and holds regrain()'s SHARE lock first; the writer's INSERT queues behind it
begin;
lock table public.t328c in share mode;
select dblink_send_query('r328c', $q$insert into public.t328c (id, payload) values (1601, 'queued')$q$);
do $$
begin
  for i in 1..200 loop
    exit when pg_backend_pid() = any(pg_blocking_pids((select pid from t328c_reader)));
    perform pg_sleep(0.025);
  end loop;
end $$;
select ok(pg_backend_pid() = any(pg_blocking_pids((select pid from t328c_reader)))
          and (select backend_xmin is not null from pg_stat_activity where pid = (select pid from t328c_reader)),
  'LIVENESS: the writer, its statement''s snapshot held, is waiting on a lock this session holds');
-- a budget of 3 s: a wait that did not pass it would spend the budget on it and refuse
set local lock_timeout = '3s';
do $$
begin
  insert into t328c_passed (passed) values (pgpm._snapshot_wait(null, 'probe swap', 'the probe range', 'Probe'));
exception when others then
  insert into t328c_passed (err) values (sqlerrm);
end $$;
select is((select coalesce(passed::text, err) from t328c_passed), array[(select pid from t328c_reader)]::text,
  'the wait passes the session that waits on a lock of this one, and names it');
select lives_ok(
  format($$ select pgpm.regrain('public.t328c', %L, '100') $$, (select child_name from t328c_src)),
  'so regrain() completes inside its budget rather than waiting for a snapshot that cannot be released first');
commit;
select is((select r from dblink_get_result('r328c') as t(r text)), 'INSERT 0 1',
  'LIVENESS: the queued write went through once this session let go');
select count(*) from dblink_get_result('r328c') as t(r text);   -- drains the connection for the next command
select dblink_exec('r328c', 'commit');
select bag_eq(
  $$ select lo::bigint, hi::bigint from pgpm.part where parent_table = 'public.t328c'::regclass and attached and hi::bigint <= 500 $$,
  $$ values (0::bigint, 100::bigint), (100, 200), (200, 300), (300, 400), (400, 500) $$,
  'the five fine children are attached in the source''s place');
select ok(not exists (select 1 from pg_class c, t328c_src s where c.oid = s.child_oid), 'and the source is dropped');
select bag_eq(
  $$ select id from public.t328c $$,
  $$ select g::bigint from generate_series(2, 400, 2) g union all values (1601::bigint), (1700) $$,
  'and every row is read after it, the queued write included');

-- ============================================ PART D ============================================
create table public.t328d (id bigint generated by default as identity primary key, payload text);
insert into public.t328d (id, payload) select g, 'd' || g from generate_series(5, 495, 5) g;
call pgpm.transmute('public.t328d', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328d (id, payload) values (2500, 'frontier');
select pgpm.set_regrain('public.t328d', '100');

-- the first copy batch, and only it, before the reader opens
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy');
  end loop;
end $$;
select dblink_connect('r328d', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328d', 'begin isolation level repeatable read');
create temp table t328d_reader as
  select pid from dblink('r328d', 'select pg_backend_pid() from pgpm.config limit 1') as t(pid int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400) $$,
  'LIVENESS: the copies ran, one batch for each of the five sub-ranges of [0, 500)');
select bag_eq(
  $$ select lo from dblink('r328d', $q$select lo::bigint from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain_copy'$q$) as t(lo bigint) $$,
  $$ values (0::bigint) $$,
  'LIVENESS: the reader opened between the first copy and the rest: it sees the [0, 100) batch and no other');
select is((select count(*) from pg_locks l, t328d_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328d'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328d'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328d'::regclass)),
  0::bigint, 'LIVENESS: that reader holds no lock on the table or any of its partitions');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328d'::regclass) = '500'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'), 0::bigint,
  'the swap did not run while a reader that misses the later copies was open');
select ok(exists (select 1 from pgpm.log l, t328d_reader r
                   where l.parent_table = 'public.t328d'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'the tick deferred it, logged skip_regrain naming that reader by pid');
select bag_eq(
  $$ select id from dblink('r328d', 'select id from public.t328d') as t(id bigint) $$,
  $$ select g::bigint from generate_series(5, 495, 5) g union all select 2500 $$,
  'that reader reads exactly its rows: the multiples of 5 to 495, and 2500');
select dblink_exec('r328d', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328d', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328d'::regclass and action = 'regrain'), 1::bigint,
  'once it committed, the next tick swapped');
select bag_eq(
  $$ select id from public.t328d $$,
  $$ select g::bigint from generate_series(5, 495, 5) g union all select 2500 $$,
  'and a fresh read after the swap holds exactly the same rows');

-- ============================================ PART E ============================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't328_owner') then create role t328_owner login; end if;
  if not exists (select 1 from pg_roles where rolname = 't328_reporter') then create role t328_reporter login; end if;
end $$;
grant usage, create on schema pgpm to t328_owner;
grant all on all tables in schema pgpm to t328_owner;
grant all on all sequences in schema pgpm to t328_owner;
grant execute on all functions in schema pgpm to t328_owner;
grant execute on all procedures in schema pgpm to t328_owner;
grant create, usage on schema public to t328_owner;
grant usage on schema pgpm to t328_reporter;
grant select on pgpm.log to t328_reporter;

set role t328_owner;
create table public.t328e (id bigint generated by default as identity primary key, payload text);
insert into public.t328e (id, payload) select g, 'e' || g from generate_series(6, 498, 6) g;
grant select on public.t328e to t328_reporter;
call pgpm.transmute('public.t328e', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328e (id, payload) values (1800, 'frontier');
select pgpm.set_regrain('public.t328e', '100');
reset role;

select dblink_connect('r328e', 'dbname=' || current_database() || ' user=t328_reporter');
select dblink_exec('r328e', 'begin isolation level repeatable read');
create temp table t328e_reader as
  select pid from dblink('r328e', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
grant select on t328e_reader to t328_owner;

select ok(not (select rolsuper from pg_roles where rolname = 't328_owner')
          and not pg_has_role('t328_owner', 'pg_read_all_stats', 'usage')
          and (select relowner::regrole::text from pg_class where oid = 'public.t328e'::regclass) = 't328_owner',
  'GUARD: the table''s owner, which runs maintain here, is no superuser and lacks pg_read_all_stats');
set role t328_owner;
select ok((select backend_xmin is not null and backend_type is null and xact_start is null
             from pg_stat_activity where pid = (select pid from t328e_reader)),
  'LIVENESS: to the owner the reader shows its snapshot (backend_xmin) but not its backend_type or xact_start');
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328e', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
reset role;

select bag_eq(
  $$ select lo::bigint from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain_copy' $$,
  $$ values (0::bigint), (100), (200), (300), (400) $$,
  'LIVENESS: the owner''s ticks ran the copies, one batch for each of the five sub-ranges of [0, 500)');
select is((select n from dblink('r328e', $q$select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: the reader''s snapshot predates every copy');
select is((select count(*) from pg_locks l, t328e_reader r
            where l.pid = r.pid and l.locktype = 'relation'
              and l.relation in (select 'public.t328e'::regclass::oid
                                 union all select i.inhrelid from pg_inherits i where i.inhparent = 'public.t328e'::regclass
                                 union all select p.child_oid from pgpm.part p where p.parent_table = 'public.t328e'::regclass)),
  0::bigint, 'LIVENESS: the reader holds no lock on the table or any of its partitions');
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328e'::regclass) = '500'
          or exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'),
  'LIVENESS: the run reached the swap (every sub-range copied and the cursor at hi, or the swap made)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'), 0::bigint,
  'the owner''s tick did not swap under the other role''s reader');
select ok(exists (select 1 from pgpm.log l, t328e_reader r
                   where l.parent_table = 'public.t328e'::regclass and l.action = 'skip_regrain'
                     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  'it deferred the swap, logged skip_regrain naming the reader by pid');
select bag_eq(
  $$ select id from dblink('r328e', 'select id from public.t328e') as t(id bigint) $$,
  $$ select g::bigint from generate_series(6, 498, 6) g union all select 1800 $$,
  'the reader reads exactly its rows: the multiples of 6 to 498, and 1800');
select dblink_exec('r328e', 'commit');
set role t328_owner;
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328e', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain');
  end loop;
end $$;
reset role;
select is((select count(*) from pgpm.log where parent_table = 'public.t328e'::regclass and action = 'regrain'), 1::bigint,
  'once the reader committed, the owner''s next tick swapped');
select bag_eq(
  $$ select id from public.t328e $$,
  $$ select g::bigint from generate_series(6, 498, 6) g union all select 1800 $$,
  'and a fresh read after the swap holds exactly the same rows');

-- ============================================ PART F ============================================
create table public.t328f (id bigint generated by default as identity primary key, payload text);
insert into public.t328f (id, payload) select g, 'f' || g from generate_series(4, 400, 4) g;
call pgpm.transmute('public.t328f', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328f (id, payload) values (1900, 'frontier');
create temp table t328f_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328f'::regclass and p.attached and p.lo = '0';

-- W holds ROW EXCLUSIVE, so the driver's regrain() opens its transaction and then waits for its SHARE lock
select dblink_connect('w328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328f', 'begin');
select dblink_exec('w328f', 'lock table public.t328f in row exclusive mode');
select dblink_connect('d328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('d328f', 'set lock_timeout = ''3s''');
create temp table t328f_driver as select pid from dblink('d328f', 'select pg_backend_pid()') as t(pid int);
select dblink_send_query('d328f', format('select pgpm.regrain(''public.t328f'', %L, ''100'')', (select child_name from t328f_src)));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328f_driver) and not granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks where pid = (select pid from t328f_driver) and not granted),
  'LIVENESS: the regrain() call has opened its transaction (it waits for its SHARE lock)');
-- the reader opens DURING the call, before any copy is made
select dblink_connect('r328f', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328f', 'begin isolation level repeatable read');
create temp table t328f_reader as
  select pid from dblink('r328f', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
select ok((select r.xact_start > d.xact_start and r.backend_xmin is not null
             from pg_stat_activity r, pg_stat_activity d
            where r.pid = (select pid from t328f_reader) and d.pid = (select pid from t328f_driver)),
  'LIVENESS: the reader''s transaction began after the call''s, and holds a snapshot');
select dblink_exec('w328f', 'commit');
-- the driver copies and reaches its wait; the reader, idle there, then runs its next statement in the same snapshot
do $$
begin
  for i in 1..600 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select pid from t328f_driver) and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
select dblink_send_query('r328f', 'select pg_sleep(1.5)');
select pg_sleep(0.2);
select ok((select state = 'active' and backend_xmin is not null from pg_stat_activity where pid = (select pid from t328f_reader)),
  'LIVENESS: the reader is running its next statement, its snapshot still held');
select is(dblink_is_busy('d328f'), 1, 'LIVENESS: while regrain() is still in its wait (no swap yet)');
create temp table t328f_result as select r from dblink_get_result('d328f', false) as t(r text);
select count(*) from dblink_get_result('r328f') as t(r text);
select count(*) from dblink_get_result('r328f') as t(r text);
-- (this session's own statement, waiting on d328f, is one of the snapshots too: regrain() waits for every one)
select ok(dblink_error_message('d328f') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                          || (select pid from t328f_reader) || '(, [0-9]+)*\)'),
  'regrain() waited for the reader opened during the call, through its next statement, and refused the swap when it outlasted the budget');
select is((select count(*) from t328f_result), 0::bigint, 'and returned no result');
select is((select count(*) from pgpm.part where parent_table = 'public.t328f'::regclass and not attached), 0::bigint,
  'the refusal rolled the copies back with it');
select is((select n from dblink('r328f',
  'select count(*) from pg_locks where locktype = ''relation'' and relation = ''public.t328f''::regclass and pid = pg_backend_pid()') as t(n bigint)),
  0::bigint, 'LIVENESS: the reader held no lock on the table through the call');
select bag_eq(
  $$ select id from dblink('r328f', 'select id from public.t328f') as t(id bigint) $$,
  $$ select g::bigint from generate_series(4, 400, 4) g union all select 1900 $$,
  'the reader reads exactly its rows: the multiples of 4 to 400, and 1900');
select dblink_exec('r328f', 'commit');
select is(pgpm.regrain('public.t328f', (select child_name from t328f_src), '100'), 5,
  'LIVENESS: once the reader committed, regrain() splits the monolith into its five fine children');
select bag_eq(
  $$ select id from public.t328f $$,
  $$ select g::bigint from generate_series(4, 400, 4) g union all select 1900 $$,
  'and every row is read after it');

-- ============================================ PART G ============================================
create table public.t328g (id bigint generated by default as identity primary key, payload text);
insert into public.t328g (id, payload) select g, 'g' || g from generate_series(8, 496, 8) g;
call pgpm.transmute('public.t328g', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328g (id, payload) values (2600, 'frontier');
select pgpm.set_regrain('public.t328g', '100');
select dblink_connect('r328g', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328g', 'begin isolation level repeatable read');
create temp table t328g_reader as select pid from dblink('r328g', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328g', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328g'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
create temp table t328g_skips as
  select count(*) as n from pgpm.log l, t328g_reader r
   where l.parent_table = 'public.t328g'::regclass and l.action = 'skip_regrain'
     and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%';
select ok((select n from t328g_skips) = 1
          and (select regrain_cursor from pgpm.config where parent_table = 'public.t328g'::regclass) = '500',
  'LIVENESS: the run is at the swap and one tick has deferred it for the idle reader');
-- the reader starts a statement that does not touch the table and outlasts the next tick's budget
select dblink_send_query('r328g', 'select pg_sleep(1.5)');
select pg_sleep(0.2);
select ok((select state = 'active' and backend_xmin is not null from pg_stat_activity where pid = (select pid from t328g_reader)),
  'LIVENESS: the reader is in the middle of a statement, its snapshot still held');
do $$
declare v_status text;
begin
  call pgpm.maintain('public.t328g', v_status);
end $$;
select is((select count(*) from pgpm.log l, t328g_reader r
            where l.parent_table = 'public.t328g'::regclass and l.action = 'skip_regrain'
              and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid ' || r.pid || ',%'),
  2::bigint, 'the tick deferred the swap again, naming the reader mid-statement');
select is((select count(*) from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain'), 0::bigint,
  'and did not swap under it');
select count(*) from dblink_get_result('r328g') as t(r text);
select count(*) from dblink_get_result('r328g') as t(r text);
select bag_eq(
  $$ select id from dblink('r328g', 'select id from public.t328g') as t(id bigint) $$,
  $$ select g::bigint from generate_series(8, 496, 8) g union all select 2600 $$,
  'the reader reads exactly its rows: the multiples of 8 to 496, and 2600');
select dblink_exec('r328g', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328g', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328g'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: once the reader committed, the next tick swapped');

-- ============================================ PART H ============================================
set role t328_owner;
create table public.t328h (id bigint generated by default as identity primary key, payload text);
insert into public.t328h (id, payload) select g, 'h' || g from generate_series(9, 495, 9) g;
grant select on public.t328h to t328_reporter;
call pgpm.transmute('public.t328h', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328h (id, payload) values (2700, 'frontier');
reset role;
create temp table t328h_src as
  select p.child_name, p.child_oid from pgpm.part p
   where p.parent_table = 'public.t328h'::regclass and p.attached and p.lo = '0';
grant select on t328h_src to t328_owner;
select dblink_connect('r328h', 'dbname=' || current_database() || ' user=t328_reporter');
select dblink_exec('r328h', 'begin isolation level repeatable read');
create temp table t328h_reader as select pid from dblink('r328h', 'select pg_backend_pid() from pg_class limit 1') as t(pid int);
grant select on t328h_reader to t328_owner;
set role t328_owner;
select ok((select backend_xmin is not null and state is null and xact_start is null and backend_type is null
             from pg_stat_activity where pid = (select pid from t328h_reader)),
  'LIVENESS: to the owner the reader shows its snapshot (backend_xmin) and nothing else: state, xact_start, backend_type NULL');
set lock_timeout = '500ms';
select throws_like(
  format($$ select pgpm.regrain('public.t328h', %L, '100') $$, (select child_name from t328h_src)),
  'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select pid from t328h_reader) || ',%',
  'regrain() run by the owner waits for the other role''s reader and refuses the swap when it outlasts the budget');
reset lock_timeout;
reset role;
select is((select p.child_oid from pgpm.part p join t328h_src s using (child_name)
            where p.parent_table = 'public.t328h'::regclass and p.attached),
  (select child_oid from t328h_src), 'the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('r328h', 'select id from public.t328h') as t(id bigint) $$,
  $$ select g::bigint from generate_series(9, 495, 9) g union all select 2700 $$,
  'the reader reads exactly its rows: the multiples of 9 to 495, and 2700');
select dblink_exec('r328h', 'commit');
set role t328_owner;
select is(pgpm.regrain('public.t328h', (select child_name from t328h_src), '100'), 5,
  'LIVENESS: once the reader committed, the owner''s regrain() splits the monolith into its five fine children');
reset role;

select dblink_disconnect('r328h');

-- ============================================ PART I ============================================
create table public.t328i (id bigint generated by default as identity primary key, payload text);
insert into public.t328i (id, payload) select g, 'i' || g from generate_series(11, 495, 11) g;
call pgpm.transmute('public.t328i', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328i (id, payload) values (2800, 'frontier');
select pgpm.set_regrain('public.t328i', '100');
create temp table t328i_state (k text primary key, v text);
-- A: REPEATABLE READ, its snapshot taken before the copies and exported, no lock on the table
select dblink_connect('a328i', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328i', 'begin isolation level repeatable read');
insert into t328i_state select 'snap', s from dblink('a328i', 'select pg_export_snapshot()') as t(s text);
insert into t328i_state select 'apid', p::text from dblink('a328i', 'select pg_backend_pid()') as t(p int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328i', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328i'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328i'::regclass) = '500'
          and exists (select 1 from pgpm.log l where l.parent_table = 'public.t328i'::regclass and l.action = 'skip_regrain'
                       and l.method like 'pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
                                          || (select v from t328i_state where k = 'apid') || ',%'),
  'LIVENESS: the run is at the swap, and the tick deferred it for the exporter A');
-- M: the swap by hand, one regrain_step in its own transaction, against the run's recorded last write
select dblink_connect('m328i', 'dbname=' || current_database() || ' user=postgres');
insert into t328i_state select 'mpid', p::text from dblink('m328i', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328i', 'set lock_timeout = ''3s''');
select dblink_send_query('m328i', format('select pgpm.regrain_step(%L, %L, %L)', 'public.t328i',
  (select child_name from pgpm.part where parent_table = 'public.t328i'::regclass and attached and lo = '0'), '100'));
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328i_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328i_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328i_state where k = 'm_waiting_at'), 'LIVENESS: M is in its snapshot wait (waiting for A)');
-- B: opened NOW, after the wait began, importing A's snapshot
select dblink_connect('b328i', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328i', 'begin isolation level repeatable read');
select dblink_exec('b328i', format('set transaction snapshot %L', (select v from t328i_state where k = 'snap')));
insert into t328i_state select 'bpid', p::text from dblink('b328i', 'select pg_backend_pid()') as t(p int);
select ok((select b.backend_xmin = a.backend_xmin and b.xact_start > (select v::timestamptz from t328i_state where k = 'm_waiting_at')
             from pg_stat_activity a, pg_stat_activity b
            where a.pid = (select v::int from t328i_state where k = 'apid') and b.pid = (select v::int from t328i_state where k = 'bpid')),
  'LIVENESS: B began after M''s wait did, and holds A''s snapshot (the same backend_xmin)');
select is((select n from dblink('b328i', $q$select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain_copy'$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: B''s snapshot predates every copy');
-- A ends; B, imported after the wait began, must still be waited for
select dblink_exec('a328i', 'commit');
create temp table t328i_result as select r from dblink_get_result('m328i', false) as t(r text);
select alike(dblink_error_message('m328i'),
  'ERROR:  pg_partition_magician: regrain swap deferred: 1 snapshot(s) older than the copies still open (oldest: pid '
    || (select v from t328i_state where k = 'bpid') || ',%',
  'once A committed, M waited for B, the importer, and refused the swap when B outlasted the budget');
select is((select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain'), 0::bigint,
  'and nothing swapped under B');
select bag_eq(
  $$ select id from dblink('b328i', 'select id from public.t328i') as t(id bigint) $$,
  $$ select g::bigint from generate_series(11, 495, 11) g union all select 2800 $$,
  'B reads exactly its rows: the multiples of 11 to 495, and 2800');
select dblink_exec('b328i', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328i', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328i'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: once B committed, the next tick swapped');
select dblink_disconnect('a328i');
select dblink_disconnect('b328i');
select dblink_disconnect('m328i');

-- ============================================ PART J ============================================
create table public.t328j (id bigint generated by default as identity primary key, payload text);
insert into public.t328j (id, payload) select g, 'j' || g from generate_series(12, 492, 12) g;
call pgpm.transmute('public.t328j', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328j (id, payload) values (2900, 'frontier');
create temp table t328j_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328j'::regclass and p.attached and p.lo = '0';
create temp table t328j_state (k text primary key, v text);
create table public.t328j_w (x int);
-- W: a writer idle in its transaction from here on, holding the oldest running xid
select dblink_connect('w328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328j', 'begin');
select dblink_exec('w328j', 'insert into public.t328j_w values (1)');
insert into t328j_state select 'wpid', p::text from dblink('w328j', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken now, before the copies, and exported
select dblink_connect('a328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328j', 'begin isolation level repeatable read');
insert into t328j_state select 'snap', s from dblink('a328j', 'select pg_export_snapshot()') as t(s text);
insert into t328j_state select 'apid', p::text from dblink('a328j', 'select pg_backend_pid()') as t(p int);
-- (at or before, not equal: the suite runs other files' transactions beside this one, cluster-wide xids)
select ok((select w.backend_xid is not null and age(a.backend_xmin) >= age(w.backend_xid) from pg_stat_activity a, pg_stat_activity w
            where a.pid = (select v::int from t328j_state where k = 'apid') and w.pid = (select v::int from t328j_state where k = 'wpid')),
  'LIVENESS: (J) A''s snapshot cannot see W, idle in its transaction: its xmin is at or before W''s xid');

-- M: the swap's wait, in its own session
select dblink_connect('m328j', 'dbname=' || current_database() || ' user=postgres');
insert into t328j_state select 'mpid', p::text from dblink('m328j', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328j', 'set lock_timeout = ''3s''');
select dblink_send_query('m328j', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328j', (select child_name from t328j_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328j_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328j_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328j_state where k = 'm_waiting_at'), 'LIVENESS: (J) M is in its snapshot wait');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b328j', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328j', 'begin isolation level repeatable read');
select dblink_exec('b328j', format('set transaction snapshot %L', (select v from t328j_state where k = 'snap')));
insert into t328j_state select 'bpid', p::text from dblink('b328j', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328j_state where k = 'm_waiting_at')
                  and b.backend_xmin = a.backend_xmin and w.backend_xid is not null and age(b.backend_xmin) >= age(w.backend_xid)
             from pg_stat_activity b, pg_stat_activity w, pg_stat_activity a
            where b.pid = (select v::int from t328j_state where k = 'bpid') and w.pid = (select v::int from t328j_state where k = 'wpid')
              and a.pid = (select v::int from t328j_state where k = 'apid')),
  'LIVENESS: (J) B began after M''s wait did, holds A''s snapshot (the same xmin), at or before W''s xid (equal to it when no other transaction runs)');
select dblink_exec('a328j', 'commit');
create temp table t328j_result as select r from dblink_get_result('m328j', false) as t(r text);
select ok(dblink_error_message('m328j') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328j_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(J) once A committed, M waited for B, the importer, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328j'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328j_src s where p.parent_table = 'public.t328j'::regclass and p.attached and p.child_oid = s.child_oid),
  '(J) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328j', 'select id from public.t328j') as t(id bigint) $$,
  $$ select g::bigint from generate_series(12, 492, 12) g union all select 2900 $$,
  '(J) B reads exactly its rows: the multiples of 12 to 492, and 2900');
select dblink_exec('b328j', 'commit');
select dblink_exec('w328j', 'rollback');
select is(pgpm.regrain('public.t328j', (select child_name from t328j_src), '100'), 5,
  'LIVENESS: (J) with B and W gone, regrain() splits the monolith into its five fine children');
select dblink_disconnect('a328j');
select dblink_disconnect('b328j');
select dblink_disconnect('m328j');
select dblink_disconnect('w328j');

-- ============================================ PART K ============================================
create table public.t328k (id bigint generated by default as identity primary key, payload text);
insert into public.t328k (id, payload) select g, 'k' || g from generate_series(13, 494, 13) g;
call pgpm.transmute('public.t328k', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328k (id, payload) values (3000, 'frontier');
create temp table t328k_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328k'::regclass and p.attached and p.lo = '0';
create temp table t328k_state (k text primary key, v text);
create table public.t328k_w (x int);
-- W: a writer idle in its transaction from here on, holding the oldest running xid
select dblink_connect('w328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328k', 'begin');
select dblink_exec('w328k', 'insert into public.t328k_w values (1)');
insert into t328k_state select 'wpid', p::text from dblink('w328k', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken now, before the copies, and exported
select dblink_connect('a328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328k', 'begin isolation level repeatable read');
insert into t328k_state select 'snap', s from dblink('a328k', 'select pg_export_snapshot()') as t(s text);
insert into t328k_state select 'apid', p::text from dblink('a328k', 'select pg_backend_pid()') as t(p int);
-- (at or before, not equal: the suite runs other files' transactions beside this one, cluster-wide xids)
select ok((select w.backend_xid is not null and age(a.backend_xmin) >= age(w.backend_xid) from pg_stat_activity a, pg_stat_activity w
            where a.pid = (select v::int from t328k_state where k = 'apid') and w.pid = (select v::int from t328k_state where k = 'wpid')),
  'LIVENESS: (K) A''s snapshot cannot see W, idle in its transaction: its xmin is at or before W''s xid');
select pgpm.set_regrain('public.t328k', '100');
do $$
declare v_status text;
begin
  for i in 1..40 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.t328k'::regclass) = '500';
    call pgpm.maintain('public.t328k', v_status);
  end loop;
end $$;
-- the state an install from before regrain_written_xid leaves an in-flight run in: no recorded last write (no
-- maintain tick runs on this table from here on, so the run stays in flight until the hand regrain_step below)
update pgpm.config set regrain_written_xid = null where parent_table = 'public.t328k'::regclass;
select ok((select regrain_cursor = '500' and regrain_written_xid is null from pgpm.config where parent_table = 'public.t328k'::regclass)
          and (select count(*) from pgpm.log where parent_table = 'public.t328k'::regclass and action = 'regrain_copy') = 5,
  'LIVENESS: (K) the run''s five copies are made, the cursor at hi, and no last write recorded (as across the upgrade)');
-- M: the swap's wait, in its own session
select dblink_connect('m328k', 'dbname=' || current_database() || ' user=postgres');
insert into t328k_state select 'mpid', p::text from dblink('m328k', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328k', 'set lock_timeout = ''3s''');
select dblink_send_query('m328k', format('select pgpm.regrain_step(%L, %L, ''100'')', 'public.t328k', (select child_name from t328k_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328k_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328k_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328k_state where k = 'm_waiting_at'), 'LIVENESS: (K) M is in its snapshot wait');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b328k', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328k', 'begin isolation level repeatable read');
select dblink_exec('b328k', format('set transaction snapshot %L', (select v from t328k_state where k = 'snap')));
insert into t328k_state select 'bpid', p::text from dblink('b328k', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328k_state where k = 'm_waiting_at')
                  and b.backend_xmin = a.backend_xmin and w.backend_xid is not null and age(b.backend_xmin) >= age(w.backend_xid)
             from pg_stat_activity b, pg_stat_activity w, pg_stat_activity a
            where b.pid = (select v::int from t328k_state where k = 'bpid') and w.pid = (select v::int from t328k_state where k = 'wpid')
              and a.pid = (select v::int from t328k_state where k = 'apid')),
  'LIVENESS: (K) B began after M''s wait did, holds A''s snapshot (the same xmin), at or before W''s xid (equal to it when no other transaction runs)');
select dblink_exec('a328k', 'commit');
create temp table t328k_result as select r from dblink_get_result('m328k', false) as t(r text);
select ok(dblink_error_message('m328k') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328k_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(K) once A committed, M waited for B, the importer, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328k'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328k_src s where p.parent_table = 'public.t328k'::regclass and p.attached and p.child_oid = s.child_oid),
  '(K) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328k', 'select id from public.t328k') as t(id bigint) $$,
  $$ select g::bigint from generate_series(13, 494, 13) g union all select 3000 $$,
  '(K) B reads exactly its rows: the multiples of 13 to 494, and 3000');
select dblink_exec('b328k', 'commit');
select dblink_exec('w328k', 'rollback');
select is((select r from (select pgpm.regrain_step('public.t328k', (select child_name from t328k_src), '100') as r) x), 'swapped:5',
  'LIVENESS: (K) with B and W gone, the hand regrain_step swaps in the five fine children');
select dblink_disconnect('a328k');
select dblink_disconnect('b328k');
select dblink_disconnect('m328k');
select dblink_disconnect('w328k');

-- ============================================ PART L ============================================
create table public.t328l (id bigint generated by default as identity primary key, payload text);
insert into public.t328l (id, payload) select g, 'l' || g from generate_series(14, 490, 14) g;
call pgpm.transmute('public.t328l', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328l (id, payload) values (3100, 'frontier');
create temp table t328l_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328l'::regclass and p.attached and p.lo = '0';
create temp table t328l_state (k text primary key, v text);
create table public.t328l_w (x int);

-- W: a writer; E, READ COMMITTED, exports S1 while W runs
select dblink_connect('w328l', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328l', 'begin');
select dblink_exec('w328l', 'insert into public.t328l_w values (1)');
select dblink_connect('e328l', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('e328l', 'begin isolation level read committed');
insert into t328l_state select 's1', s from dblink('e328l', 'select pg_export_snapshot()') as t(s text);
insert into t328l_state select 'epid', p::text from dblink('e328l', 'select pg_backend_pid()') as t(p int);
-- W commits; E exports S2, a newer snapshot, still before the call
select dblink_exec('w328l', 'commit');
insert into t328l_state select 's2', s from dblink('e328l', 'select pg_export_snapshot()') as t(s text);
select dblink_disconnect('w328l');
-- M: the swap's wait, in its own session
select dblink_connect('m328l', 'dbname=' || current_database() || ' user=postgres');
insert into t328l_state select 'mpid', p::text from dblink('m328l', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328l', 'set lock_timeout = ''3s''');
select dblink_send_query('m328l', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328l', (select child_name from t328l_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328l_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328l_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328l_state where k = 'm_waiting_at'), 'LIVENESS: (L) M is in its snapshot wait (E holds S1 and S2)');
-- B: opened after the wait began, importing S2
select dblink_connect('b328l', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328l', 'begin isolation level repeatable read');
select dblink_exec('b328l', format('set transaction snapshot %L', (select v from t328l_state where k = 's2')));
insert into t328l_state select 'bpid', p::text from dblink('b328l', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328l_state where k = 'm_waiting_at')
                  and age(b.backend_xmin) <= age(e.backend_xmin)
                  and age(b.backend_xmin) > age(m.backend_xid)
             from pg_stat_activity b, pg_stat_activity e, pg_stat_activity m
            where b.pid = (select v::int from t328l_state where k = 'bpid') and e.pid = (select v::int from t328l_state where k = 'epid')
              and m.pid = (select v::int from t328l_state where k = 'mpid')),
  'LIVENESS: (L) B began after M''s wait did; its xmin (S2''s) is at or after its exporter E''s (S1''s; after it when no other database''s transaction pins both) and older than M''s xid');
select dblink_exec('e328l', 'commit');
create temp table t328l_result as select r from dblink_get_result('m328l', false) as t(r text);
select ok(dblink_error_message('m328l') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328l_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(L) once E committed, M waited for B, the importer of S2, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328l'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328l_src s where p.parent_table = 'public.t328l'::regclass and p.attached and p.child_oid = s.child_oid),
  '(L) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328l', 'select id from public.t328l') as t(id bigint) $$,
  $$ select g::bigint from generate_series(14, 490, 14) g union all select 3100 $$,
  '(L) B reads exactly its rows: the multiples of 14 to 490, and 3100');
select dblink_exec('b328l', 'commit');
select is(pgpm.regrain('public.t328l', (select child_name from t328l_src), '100'), 5,
  'LIVENESS: (L) with E and B gone, regrain() splits the monolith into its five fine children');
select dblink_disconnect('e328l');
select dblink_disconnect('b328l');
select dblink_disconnect('m328l');

-- ============================================ PART M ============================================
create table public.t328m (id bigint generated by default as identity primary key, payload text);
insert into public.t328m (id, payload) select g, 'm' || g from generate_series(15, 495, 15) g;
call pgpm.transmute('public.t328m', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328m (id, payload) values (3200, 'frontier');
create temp table t328m_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328m'::regclass and p.attached and p.lo = '0';
create temp table t328m_state (k text primary key, v text);
create table public.t328m_w (x int);
select pgpm.set_regrain('public.t328m', '100');
do $$
declare v_status text;
begin
  for i in 1..40 loop
    exit when (select regrain_cursor from pgpm.config where parent_table = 'public.t328m'::regclass) = '500';
    call pgpm.maintain('public.t328m', v_status);
  end loop;
end $$;
-- the state an install from before regrain_written_xid leaves an in-flight run in (no maintain tick runs on this
-- table from here on)
update pgpm.config set regrain_written_xid = null where parent_table = 'public.t328m'::regclass;
select ok((select regrain_cursor = '500' and regrain_written_xid is null from pgpm.config where parent_table = 'public.t328m'::regclass),
  'LIVENESS: (M) the run''s copies are made, the cursor at hi, and no last write recorded (as across the upgrade)');
-- W: a writer; E, READ COMMITTED, exports S1 while W runs
select dblink_connect('w328m', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('w328m', 'begin');
select dblink_exec('w328m', 'insert into public.t328m_w values (1)');
select dblink_connect('e328m', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('e328m', 'begin isolation level read committed');
insert into t328m_state select 's1', s from dblink('e328m', 'select pg_export_snapshot()') as t(s text);
insert into t328m_state select 'epid', p::text from dblink('e328m', 'select pg_backend_pid()') as t(p int);
-- W commits; E exports S2, a newer snapshot, still before the call
select dblink_exec('w328m', 'commit');
insert into t328m_state select 's2', s from dblink('e328m', 'select pg_export_snapshot()') as t(s text);
select dblink_disconnect('w328m');
-- M: the swap's wait, in its own session
select dblink_connect('m328m', 'dbname=' || current_database() || ' user=postgres');
insert into t328m_state select 'mpid', p::text from dblink('m328m', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328m', 'set lock_timeout = ''3s''');
select dblink_send_query('m328m', format('select pgpm.regrain_step(%L, %L, ''100'')', 'public.t328m', (select child_name from t328m_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328m_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328m_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328m_state where k = 'm_waiting_at'), 'LIVENESS: (M) M is in its snapshot wait (E holds S1 and S2)');
-- B: opened after the wait began, importing S2
select dblink_connect('b328m', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328m', 'begin isolation level repeatable read');
select dblink_exec('b328m', format('set transaction snapshot %L', (select v from t328m_state where k = 's2')));
insert into t328m_state select 'bpid', p::text from dblink('b328m', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328m_state where k = 'm_waiting_at')
                  and age(b.backend_xmin) < age(e.backend_xmin)
                  and age(b.backend_xmin) > age(m.backend_xid)
             from pg_stat_activity b, pg_stat_activity e, pg_stat_activity m
            where b.pid = (select v::int from t328m_state where k = 'bpid') and e.pid = (select v::int from t328m_state where k = 'epid')
              and m.pid = (select v::int from t328m_state where k = 'mpid')),
  'LIVENESS: (M) B began after M''s wait did; its xmin (S2''s) is newer than its exporter E''s (S1''s) and older than M''s xid');
select dblink_exec('e328m', 'commit');
create temp table t328m_result as select r from dblink_get_result('m328m', false) as t(r text);
select ok(dblink_error_message('m328m') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                              || (select v from t328m_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(M) once E committed, M waited for B, the importer of S2, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328m'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328m_src s where p.parent_table = 'public.t328m'::regclass and p.attached and p.child_oid = s.child_oid),
  '(M) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328m', 'select id from public.t328m') as t(id bigint) $$,
  $$ select g::bigint from generate_series(15, 495, 15) g union all select 3200 $$,
  '(M) B reads exactly its rows: the multiples of 15 to 495, and 3200');
select dblink_exec('b328m', 'commit');
select is((select r from (select pgpm.regrain_step('public.t328m', (select child_name from t328m_src), '100') as r) x), 'swapped:5',
  'LIVENESS: (M) with E and B gone, the hand regrain_step swaps in the five fine children');
select dblink_disconnect('e328m');
select dblink_disconnect('b328m');
select dblink_disconnect('m328m');

-- ============================================ PART N ============================================
create table public.t328n (id bigint generated by default as identity primary key, payload text);
insert into public.t328n (id, payload) select g, 'n' || g from generate_series(16, 496, 16) g;
call pgpm.transmute('public.t328n', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328n (id, payload) values (3300, 'frontier');
create temp table t328n_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328n'::regclass and p.attached and p.lo = '0';
create temp table t328n_state (k text primary key, v text);
-- M first (connected and configured, so nothing below assigns an xid between A's snapshot and M's first write)
select dblink_connect('m328n', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('m328n', 'set lock_timeout = ''3s''');
insert into t328n_state select 'mpid', p::text from dblink('m328n', 'select pg_backend_pid()') as t(p int);
-- A: REPEATABLE READ, its snapshot taken by the export, just before the call. Kept in psql variables, not written to
-- a table: a write here would take the very xid A's xmin names, and M's own would come after it.
select dblink_connect('a328n', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('a328n', 'begin isolation level repeatable read');
select s as n_snap from dblink('a328n', 'select pg_export_snapshot()') as t(s text) \gset
select p as n_apid from dblink('a328n', 'select pg_backend_pid()') as t(p int) \gset
select dblink_send_query('m328n', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328n', (select child_name from t328n_src)));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where pid = (select v::int from t328n_state where k = 'mpid') and wait_event = 'PgSleep') then
      insert into t328n_state values ('m_waiting_at', clock_timestamp()::text);   -- as observed: a moment later it may be between polls
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328n_state where k = 'm_waiting_at'), 'LIVENESS: (N) M (regrain() in one transaction) is in its snapshot wait');
-- (at or before, not equal: the suite runs other files' transactions beside this one, cluster-wide xids)
select ok((select a.backend_xmin is not null and m.backend_xid is not null and age(a.backend_xmin) >= age(m.backend_xid)
             from pg_stat_activity a, pg_stat_activity m
            where a.pid = :n_apid and m.pid = (select v::int from t328n_state where k = 'mpid')),
  'LIVENESS: (N) A''s snapshot predates the call: its xmin is at or before M''s own xid (equal to it when nothing else runs)');
-- B: opened after the wait began, importing A's snapshot
select dblink_connect('b328n', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('b328n', 'begin isolation level repeatable read');
select dblink_exec('b328n', format('set transaction snapshot %L', :'n_snap'));
insert into t328n_state select 'bpid', p::text from dblink('b328n', 'select pg_backend_pid()') as t(p int);
select ok((select b.xact_start > (select v::timestamptz from t328n_state where k = 'm_waiting_at') and b.backend_xmin = a.backend_xmin
             from pg_stat_activity b, pg_stat_activity a
            where b.pid = (select v::int from t328n_state where k = 'bpid') and a.pid = :n_apid),
  'LIVENESS: (N) B began after M''s wait did, and holds A''s snapshot (the same xmin)');
select is((select n from dblink('b328n', $q$select count(*) from pgpm.log where parent_table = 'public.t328n'::regclass and action in ('regrain_copy', 'regrain')$q$) as t(n bigint)),
  0::bigint, 'LIVENESS: (N) B''s snapshot sees no copy and no swap');
select dblink_exec('a328n', 'commit');
create temp table t328n_result as select r from dblink_get_result('m328n', false) as t(r text);
select ok(dblink_error_message('m328n') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred: [0-9]+ snapshot\(s\) older than the copies still open \(oldest: pid [0-9]+, open [^;]*; pids ([0-9]+, )*'
                                          || (select v from t328n_state where k = 'bpid') || '(, [0-9]+)*\)'),
  '(N) once A committed, M waited for B, the importer of A''s snapshot, and refused the swap, naming it');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328n'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328n_src s where p.parent_table = 'public.t328n'::regclass and p.attached and p.child_oid = s.child_oid),
  '(N) nothing swapped: the same source is still attached, by oid');
select bag_eq(
  $$ select id from dblink('b328n', 'select id from public.t328n') as t(id bigint) $$,
  $$ select g::bigint from generate_series(16, 496, 16) g union all select 3300 $$,
  '(N) B reads exactly its rows: the multiples of 16 to 496, and 3300');
select dblink_exec('b328n', 'commit');
select dblink_disconnect('a328n');
select dblink_disconnect('b328n');
select dblink_disconnect('m328n');

-- ============================================ PART O ============================================
create table public.t328o (id bigint generated by default as identity primary key, payload text);
insert into public.t328o (id, payload) select g, 'o' || g from generate_series(17, 493, 17) g;
call pgpm.transmute('public.t328o', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328o (id, payload) values (3400, 'frontier');
select pgpm.set_regrain('public.t328o', '100');
create temp table t328o_pids (role text primary key, pid int);
-- R: REPEATABLE READ, its snapshot taken now, before any copy, and no lock on the table
select dblink_connect('r328o', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328o', 'begin isolation level repeatable read');
insert into t328o_pids select 'r', p from dblink('r328o', 'select pg_backend_pid() from pgpm.config limit 1') as t(p int);
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328o', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328o'::regclass
                       and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328o'::regclass) = '500'
          and exists (select 1 from pgpm.log where parent_table = 'public.t328o'::regclass and action = 'skip_regrain'),
  'LIVENESS: (O) the copies are made and a maintain tick has deferred the swap for R');
-- M: the swap by hand, against the run's recorded last write, budget 3 s
select dblink_connect('m328o', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('z328o', 'dbname=' || current_database() || ' user=postgres');
insert into t328o_pids select 'm', p from dblink('m328o', 'select pg_backend_pid()') as t(p int);
insert into t328o_pids select 'z', p from dblink('z328o', 'select pg_backend_pid()') as t(p int);
select dblink_exec('m328o', 'set lock_timeout = 0');
select dblink_exec('m328o', 'set statement_timeout = ''20s''');   -- a step that waits instead of refusing fails by it
select dblink_send_query('m328o', format('select pgpm.regrain_step(%L, %L, %L)', 'public.t328o',
  (select child_name from pgpm.part where parent_table = 'public.t328o'::regclass and attached and lo = '0'), '100'));
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_stat_activity where pid = (select pid from t328o_pids where role = 'm') and wait_event = 'PgSleep');
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks l where l.pid = (select pid from t328o_pids where role = 'm')
                   and l.relation = 'public.t328o'::regclass and l.mode = 'AccessShareLock' and l.granted),
  'LIVENESS: (O) M, in its wait, holds AccessShare on the table (its read of the frontier)');
-- Z: an ordinary migration DDL, ACCESS EXCLUSIVE, queued behind M's AccessShare
select dblink_send_query('z328o', $q$alter table public.t328o alter column payload set default 'z'$q$);
do $$
begin
  for i in 1..400 loop
    exit when (select pid from t328o_pids where role = 'm') = any(pg_blocking_pids((select pid from t328o_pids where role = 'z')));
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok((select pid from t328o_pids where role = 'm') = any(pg_blocking_pids((select pid from t328o_pids where role = 'z')))
          and exists (select 1 from pg_locks l where l.pid = (select pid from t328o_pids where role = 'z') and not l.granted
                       and l.relation = 'public.t328o'::regclass and l.mode = 'AccessExclusiveLock'),
  'LIVENESS: (O) Z''s ACCESS EXCLUSIVE request on the table waits on M''s AccessShare');
-- R's first read of the table, a plain AccessShare queued behind Z
select dblink_send_query('r328o', 'select count(*) from public.t328o');
-- observed inside the loop: M refuses as soon as R queues, after which R is no longer blocked at all
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    if (select pid from t328o_pids where role = 'z') = any(pg_blocking_pids((select pid from t328o_pids where role = 'r')))
       and not (select pid from t328o_pids where role = 'm') = any(pg_blocking_pids((select pid from t328o_pids where role = 'r')))
       and (select backend_xmin is not null from pg_stat_activity where pid = (select pid from t328o_pids where role = 'r')) then
      insert into t328o_pids values ('r_queued', 1);
      exit;
    end if;
    perform pg_sleep(0.001);
  end loop;
end $$;
select ok(exists (select 1 from t328o_pids where role = 'r_queued'),
  'LIVENESS: (O) R''s read is queued behind Z, not behind M directly (R -> Z -> M), its pre-copy snapshot still held');
create temp table t328o_m as select x from dblink_get_result('m328o', false) as t(x text);
select ok(dblink_error_message('m328o') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                          || (select pid from t328o_pids where role = 'r') || '(, [0-9]+)* hold a snapshot older than the copies and wait on a lock this session holds, directly or behind another queued request \(queued on '),
  '(O) M refused at once, naming R, queued behind Z queued behind M''s own lock (not a statement timeout)');
create temp table t328o_z as select x from dblink_get_result('z328o', false) as t(x text);
select count(*) from dblink_get_result('z328o', false) as t(x text);
select is((select x from t328o_z), 'ALTER TABLE', 'LIVENESS: (O) once M let go, Z''s DDL completed');
create temp table t328o_r as select n from dblink_get_result('r328o', false) as t(n bigint);
select count(*) from dblink_get_result('r328o', false) as t(n bigint);
select is((select n from t328o_r), 30::bigint, '(O) R''s queued read counts every row (29 in the range and the frontier)');
select bag_eq(
  $$ select id from dblink('r328o', 'select id from public.t328o') as t(id bigint) $$,
  $$ select g::bigint from generate_series(17, 493, 17) g union all select 3400 $$,
  '(O) and R reads exactly its rows: the multiples of 17 to 493, and 3400');
select is((select count(*) from pgpm.log where parent_table = 'public.t328o'::regclass and action = 'regrain'), 0::bigint,
  '(O) nothing swapped under R');
select dblink_exec('r328o', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328o', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328o'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328o'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: (O) once R committed, the next maintain tick swapped');
select dblink_disconnect('r328o');
select dblink_disconnect('m328o');
select dblink_disconnect('z328o');

-- ============================================ PART P ============================================
create table public.t328p (id bigint generated by default as identity primary key, payload text);
insert into public.t328p (id, payload) select g, 'p' || g from generate_series(18, 486, 18) g;
call pgpm.transmute('public.t328p', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328p (id, payload) values (3050, 'frontier');
create temp table t328p_src as
  select p.child_name, p.child_oid from pgpm.part p where p.parent_table = 'public.t328p'::regclass and p.attached and p.lo = '0';
create temp table t328p_pids (role text primary key, pid int);
select dblink_connect('b328p', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('d328p', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('z328p', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('r328p', 'dbname=' || current_database() || ' user=postgres');
insert into t328p_pids select 'd', p from dblink('d328p', 'select pg_backend_pid()') as t(p int);
insert into t328p_pids select 'z', p from dblink('z328p', 'select pg_backend_pid()') as t(p int);
insert into t328p_pids select 'r', p from dblink('r328p', 'select pg_backend_pid()') as t(p int);
-- B holds the parent's pgpm.config row, so regrain() stops at its first config write with its SHARE lock held
select dblink_exec('b328p', 'begin');
select count(*) from dblink('b328p', $q$select 1 from pgpm.config where parent_table = 'public.t328p'::regclass for update$q$) as t(x int);
select dblink_exec('d328p', 'set lock_timeout = 0');
select dblink_exec('d328p', 'set statement_timeout = ''20s''');   -- a regrain() that waits instead of refusing fails by it
select dblink_send_query('d328p', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328p', (select child_name from t328p_src)));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328p_pids where role = 'd')
                       and relation = 'public.t328p'::regclass and mode = 'ShareLock' and granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from pg_locks where pid = (select pid from t328p_pids where role = 'd')
                   and relation = 'public.t328p'::regclass and mode = 'ShareLock' and granted),
  'LIVENESS: (P) regrain() holds its SHARE lock on the parent (paused by B before its copies)');
-- Z: a migration's DDL, queued behind regrain()'s SHARE
select dblink_send_query('z328p', 'alter table public.t328p add column note text');
do $$
begin
  for i in 1..400 loop
    exit when (select pid from t328p_pids where role = 'd') = any(pg_blocking_pids((select pid from t328p_pids where role = 'z')));
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok((select pid from t328p_pids where role = 'd') = any(pg_blocking_pids((select pid from t328p_pids where role = 'z'))),
  'LIVENESS: (P) the ALTER TABLE is queued behind regrain()''s lock');
-- R: an ordinary READ COMMITTED SELECT, queued behind Z
select dblink_send_query('r328p', 'select count(*) from public.t328p');
do $$
begin
  for i in 1..400 loop
    exit when (select pid from t328p_pids where role = 'z') = any(pg_blocking_pids((select pid from t328p_pids where role = 'r')));
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok((select pid from t328p_pids where role = 'z') = any(pg_blocking_pids((select pid from t328p_pids where role = 'r')))
          and not (select pid from t328p_pids where role = 'd') = any(pg_blocking_pids((select pid from t328p_pids where role = 'r')))
          and (select age(r.backend_xmin) >= age(d.backend_xid) from pg_stat_activity r, pg_stat_activity d
                where r.pid = (select pid from t328p_pids where role = 'r') and d.pid = (select pid from t328p_pids where role = 'd'))
          and exists (select 1 from pg_locks where pid = (select pid from t328p_pids where role = 'r') and relation = 'public.t328p'::regclass and not granted),
  'LIVENESS: (P) the SELECT waits ungranted behind the ALTER TABLE, not behind regrain() directly, holding a snapshot at or before regrain()''s xid');
-- B lets go: regrain() copies, reaches its wait, and meets the chain
select dblink_exec('b328p', 'commit');
create temp table t328p_d as select x from dblink_get_result('d328p', false) as t(x text);
select ok(dblink_error_message('d328p') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                          || (select pid from t328p_pids where role = 'r') || '(, [0-9]+)* hold a snapshot older than the copies and wait on a lock this session holds, directly or behind another queued request \(queued on '),
  '(P) regrain() refused at once, naming the SELECT queued behind the DDL queued behind its own lock (not a statement timeout)');
create temp table t328p_z as select x from dblink_get_result('z328p', false) as t(x text);
select count(*) from dblink_get_result('z328p', false) as t(x text);
select is((select x from t328p_z), 'ALTER TABLE', 'LIVENESS: (P) once regrain() let go, the ALTER TABLE completed');
create temp table t328p_r as select n from dblink_get_result('r328p', false) as t(n bigint);
select count(*) from dblink_get_result('r328p', false) as t(n bigint);
select is((select n from t328p_r), 28::bigint, '(P) and the SELECT queued behind it counts every row (27 in the range and the frontier)');
select ok((select count(*) from public.t328p) = 28
          and exists (select 1 from pg_attribute where attrelid = 'public.t328p'::regclass and attname = 'note'),
  'LIVENESS: (P) the table is readable, the DDL''s column in place');
select ok((select count(*) from pgpm.log where parent_table = 'public.t328p'::regclass and action = 'regrain') = 0
          and exists (select 1 from pgpm.part p, t328p_src s where p.parent_table = 'public.t328p'::regclass and p.attached and p.child_oid = s.child_oid),
  '(P) nothing swapped: the same source is still attached, by oid');
select is(pgpm.regrain('public.t328p', (select child_name from t328p_src), '100'), 5,
  'LIVENESS: (P) run again with the queue drained, regrain() splits the monolith into its five fine children');
select dblink_disconnect('b328p');
select dblink_disconnect('d328p');
select dblink_disconnect('z328p');
select dblink_disconnect('r328p');

-- ============================================ PART Q ============================================
create table public.t328q (id bigint generated by default as identity primary key, payload text);
insert into public.t328q (id, payload) select g, 'q' || g from generate_series(19, 494, 19) g;
call pgpm.transmute('public.t328q', 'id', 100, p_paused => false);                  -- monolith [0, 500)
insert into public.t328q (id, payload) values (3150, 'frontier');
select pgpm.set_regrain('public.t328q', '100');
create temp table t328q_pids (role text primary key, pid int);
-- R: REPEATABLE READ, its snapshot older than every copy, no lock on the table
select dblink_connect('r328q', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('z328q', 'dbname=' || current_database() || ' user=postgres');
select dblink_exec('r328q', 'create temp table r_out (n bigint)');
select dblink_exec('r328q', 'begin isolation level repeatable read');
insert into t328q_pids select 'r', p from dblink('r328q', 'select pg_backend_pid() from pgpm.config limit 1') as t(p int);
insert into t328q_pids select 'z', p from dblink('z328q', 'select pg_backend_pid()') as t(p int);
insert into t328q_pids values ('tick', pg_backend_pid());
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328q', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328q'::regclass and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328q'::regclass) = '500'
          and exists (select 1 from pgpm.log where parent_table = 'public.t328q'::regclass and action = 'skip_regrain'),
  'LIVENESS: (Q) the copies are made and a tick has deferred the swap for R (by its budget: R alone holds it)');
-- armed: Z issues its DDL the moment this session's next tick sits in its wait holding AccessShare on the table,
-- and R issues its first read the moment Z is queued
select dblink_send_query('z328q', format($q$do $z$ begin
  for i in 1..15000 loop
    if exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where l.pid = %s and l.relation = 'public.t328q'::regclass and l.mode = 'AccessShareLock' and l.granted
                  and a.wait_event = 'PgSleep') then
      execute $e$alter table public.t328q alter column payload set default 'q'$e$;
      return;
    end if;
    perform pg_sleep(0.001);
    perform pg_stat_clear_snapshot();
  end loop;
end $z$$q$, pg_backend_pid()));
select dblink_send_query('r328q', format($q$do $r$ begin
  for i in 1..15000 loop
    if exists (select 1 from pg_locks where pid = %s and relation = 'public.t328q'::regclass and not granted) then
      insert into r_out select count(*) from public.t328q;
      return;
    end if;
    perform pg_sleep(0.001);
  end loop;
end $r$$q$, (select pid from t328q_pids where role = 'z')));
select pg_sleep(0.2);
do $$
declare v_status text;
begin
  call pgpm.maintain('public.t328q', v_status);
end $$;
select ok(exists (select 1 from pgpm.log l where l.parent_table = 'public.t328q'::regclass and l.action = 'skip_regrain'
                   and l.method ~ ('^pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                   || (select pid from t328q_pids where role = 'r') || '(, [0-9]+)* hold a snapshot older than the copies')),
  '(Q) the tick deferred AT ONCE for the chain, logged skip_regrain naming R (not the budget''s deferral)');
select is((select count(*) from pgpm.log where parent_table = 'public.t328q'::regclass and action = 'regrain'), 0::bigint,
  '(Q) and did not swap under R');
select count(*) from dblink_get_result('z328q', false) as t(x text);
select count(*) from dblink_get_result('z328q', false) as t(x text);
select ok((select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
            where d.adrelid = 'public.t328q'::regclass and a.attname = 'payload') = '''q''::text',
  'LIVENESS: (Q) once the tick let go, Z''s DDL completed');
select count(*) from dblink_get_result('r328q', false) as t(x text);
select count(*) from dblink_get_result('r328q', false) as t(x text);
select is((select n from dblink('r328q', 'select n from r_out') as t(n bigint)), 27::bigint,
  'LIVENESS: (Q) R''s read, queued behind Z, ran once Z was done (its 27 rows)');
select bag_eq(
  $$ select id from dblink('r328q', 'select id from public.t328q') as t(id bigint) $$,
  $$ select g::bigint from generate_series(19, 494, 19) g union all select 3150 $$,
  '(Q) R reads exactly its rows: the multiples of 19 to 494, and 3150');
select dblink_exec('r328q', 'commit');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328q', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328q'::regclass and action = 'regrain');
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.t328q'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: (Q) once R committed, the next tick swapped');
select dblink_disconnect('r328q');
select dblink_disconnect('z328q');

-- ============================================ PART R ============================================
create table public.t328r1 (id bigint generated by default as identity primary key, payload text);
insert into public.t328r1 (id, payload) select g, 'r1-' || g from generate_series(20, 480, 20) g;
call pgpm.transmute('public.t328r1', 'id', 100, p_paused => false);                -- monolith [0, 500)
insert into public.t328r1 (id, payload) values (3250, 'frontier');
create table public.t328r2 (id bigint generated by default as identity primary key, payload text);
insert into public.t328r2 (id, payload) select g, 'r2-' || g from generate_series(21, 483, 21) g;
call pgpm.transmute('public.t328r2', 'id', 100, p_paused => false);                -- monolith [0, 500)
insert into public.t328r2 (id, payload) values (3350, 'frontier');
create table public.t328_seen (who text primary key, at timestamptz);
create temp table t328r_src as
  select p.parent_table::text as parent, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table in ('public.t328r1'::regclass, 'public.t328r2'::regclass) and p.attached and p.lo = '0';
create temp table t328r_pids (role text primary key, pid int);
select dblink_connect('b1328r', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('b2328r', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('m1328r', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('m2328r', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('o328r', 'dbname=' || current_database() || ' user=postgres');
insert into t328r_pids select 'm1', p from dblink('m1328r', 'select pg_backend_pid()') as t(p int);
insert into t328r_pids select 'm2', p from dblink('m2328r', 'select pg_backend_pid()') as t(p int);
insert into t328r_pids select 'o', p from dblink('o328r', 'select pg_backend_pid()') as t(p int);
select pid as r_m1 from t328r_pids where role = 'm1' \gset
select pid as r_m2 from t328r_pids where role = 'm2' \gset
select pid as r_o from t328r_pids where role = 'o' \gset
-- B1 and B2 hold the parents' config rows, so each regrain() stops at its first config write, SHARE held
select dblink_exec('b1328r', 'begin');
select count(*) from dblink('b1328r', $q$select 1 from pgpm.config where parent_table = 'public.t328r1'::regclass for update$q$) as t(x int);
select dblink_exec('b2328r', 'begin');
select count(*) from dblink('b2328r', $q$select 1 from pgpm.config where parent_table = 'public.t328r2'::regclass for update$q$) as t(x int);
select dblink_exec('m1328r', 'set lock_timeout = 0');
select dblink_exec('m1328r', 'set statement_timeout = ''15s''');   -- a wait that never ends fails by it
select dblink_exec('m2328r', 'set lock_timeout = 0');
select dblink_exec('m2328r', 'set statement_timeout = ''15s''');
-- M1 first: the older
select dblink_send_query('m1328r', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328r1', (select child_name from t328r_src where parent = 't328r1')));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328r_pids where role = 'm1')
                       and relation = 'public.t328r1'::regclass and mode = 'ShareLock' and granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
select dblink_send_query('m2328r', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328r2', (select child_name from t328r_src where parent = 't328r2')));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328r_pids where role = 'm2')
                       and relation = 'public.t328r2'::regclass and mode = 'ShareLock' and granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok((select age(m1.backend_xid) > age(m2.backend_xid) from pg_stat_activity m1, pg_stat_activity m2
            where m1.pid = (select pid from t328r_pids where role = 'm1') and m2.pid = (select pid from t328r_pids where role = 'm2'))
          and (select count(*) from pg_locks l, t328r_pids r where l.pid = r.pid and r.role in ('m1', 'm2') and l.mode = 'ShareLock'
                and l.granted and l.relation in ('public.t328r1'::regclass, 'public.t328r2'::regclass)) = 2,
  'LIVENESS: (R) both regrain() calls hold SHARE on their own parent, M1''s transaction the older');
-- B2 lets go: M2 copies and enters its wait, listing M1 (whose snapshot predates M2's xid), and marks itself
select dblink_exec('b2328r', 'commit');
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity a where a.pid = (select pid from t328r_pids where role = 'm2') and a.wait_event = 'PgSleep')
       and exists (select 1 from pg_locks where pid = (select pid from t328r_pids where role = 'm2') and objid = (select pid from t328r_pids where role = 'm2')::oid
                    and locktype = 'advisory' and classid = 1885826423::oid and objsubid = 2 and granted) then
      insert into t328r_pids values ('m2_waiting', 1);   -- as observed: in its wait, its marker held
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328r_pids where role = 'm2_waiting'),
  'LIVENESS: (R) the younger, M2, is in its snapshot wait first, its marker held');
select ok(not exists (select 1 from pg_stat_activity a, t328r_pids m1, t328r_pids m2 where m1.role = 'm1' and m2.role = 'm2'
                       and a.pid in (m1.pid, m2.pid) and (m1.pid = any(pg_blocking_pids(m2.pid)) or m2.pid = any(pg_blocking_pids(m1.pid)))),
  'GUARD: (R) neither call is blocked on a lock of the other');
-- O watches for M1's marker: proof that the older entered its own wait
select dblink_send_query('o328r', format($q$do $o$ begin
  for i in 1..15000 loop
    if exists (select 1 from pg_locks where pid = %1$s and objid = %1$s::oid and locktype = 'advisory' and classid = 1885826423::oid and objsubid = 2 and granted) then
      insert into public.t328_seen values ('r', clock_timestamp());
      return;
    end if;
    perform pg_sleep(0.001);
  end loop;
end $o$$q$, (select pid from t328r_pids where role = 'm1')));
-- B1 lets go: M1 copies and enters its wait, listing M2
select dblink_exec('b1328r', 'commit');
-- wait from the shell: this session holds no snapshot while M1 waits
\setenv T328_DB :DBNAME
\setenv T328_PIDS :r_m1,:r_m2,:r_o
\! for i in $(seq 1 400); do [ "$(psql -X -U postgres -d "$T328_DB" -Atc "select count(*) from pg_stat_activity where pid in ($T328_PIDS) and state = 'active'")" = "0" ] && break; sleep 0.1; done
select ok(exists (select 1 from public.t328_seen where who = 'r'),
  'LIVENESS: (R) the older, M1, entered its own snapshot wait (its marker seen) while M2 waited');
create temp table t328r_m2 as select x from dblink_get_result('m2328r', false) as t(x int);
select ok(dblink_error_message('m2328r') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                           || (select pid from t328r_pids where role = 'm1') || '(, [0-9]+)* are snapshot waits of other pgpm swaps, older than this one'),
  '(R) the younger regrain() yielded at once, naming the older (not a statement timeout)');
create temp table t328r_m1 as select x from dblink_get_result('m1328r', false) as t(x int);
select count(*) from dblink_get_result('m1328r', false) as t(x int);
select is((select x from t328r_m1), 5, '(R) the older regrain() did not yield: it completed, splitting its monolith into five');
select ok(exists (select 1 from pgpm.part p, t328r_src s where s.parent = 't328r2' and p.parent_table = 'public.t328r2'::regclass
                   and p.attached and p.child_oid = s.child_oid)
          and (select count(*) from pgpm.log where parent_table = 'public.t328r2'::regclass and action = 'regrain') = 0,
  '(R) the younger swapped nothing: its source still attached, by oid');
select bag_eq($$ select id from public.t328r1 $$, $$ select g::bigint from generate_series(20, 480, 20) g union all select 3250 $$,
  '(R) the older''s table reads exactly its rows after the swap: the multiples of 20 to 480, and 3250');
select is(pgpm.regrain('public.t328r2', (select child_name from t328r_src where parent = 't328r2'), '100'), 5,
  'LIVENESS: (R) run again on its own, the younger regrain() swaps');
select bag_eq($$ select id from public.t328r2 $$, $$ select g::bigint from generate_series(21, 483, 21) g union all select 3350 $$,
  '(R) and its table reads exactly its rows: the multiples of 21 to 483, and 3350');
select dblink_disconnect('b1328r');
select dblink_disconnect('b2328r');
select dblink_disconnect('m1328r');
select dblink_disconnect('m2328r');
select dblink_disconnect('o328r');

-- ============================================ PART S ============================================
create table public.t328s1 (id bigint generated by default as identity primary key, payload text);
insert into public.t328s1 (id, payload) select g, 's1-' || g from generate_series(22, 484, 22) g;
call pgpm.transmute('public.t328s1', 'id', 100, p_paused => false);                -- monolith [0, 500), regrain()
insert into public.t328s1 (id, payload) values (3260, 'frontier');
create table public.t328s2 (id bigint generated by default as identity primary key, payload text);
insert into public.t328s2 (id, payload) select g, 's2-' || g from generate_series(23, 483, 23) g;
call pgpm.transmute('public.t328s2', 'id', 100, p_paused => false);                -- monolith [0, 500), the step
insert into public.t328s2 (id, payload) values (3360, 'frontier');
select pgpm.set_regrain('public.t328s2', '100');
create temp table t328s_src as
  select p.parent_table::text as parent, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table in ('public.t328s1'::regclass, 'public.t328s2'::regclass) and p.attached and p.lo = '0';
create temp table t328s_pids (role text primary key, pid int);
select dblink_connect('b328s', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('m328s', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('h328s', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('o328s', 'dbname=' || current_database() || ' user=postgres');
insert into t328s_pids select 'm', p from dblink('m328s', 'select pg_backend_pid()') as t(p int);
insert into t328s_pids select 'h', p from dblink('h328s', 'select pg_backend_pid()') as t(p int);
insert into t328s_pids select 'o', p from dblink('o328s', 'select pg_backend_pid()') as t(p int);
select pid as s_m from t328s_pids where role = 'm' \gset
select pid as s_h from t328s_pids where role = 'h' \gset
select pid as s_o from t328s_pids where role = 'o' \gset
select dblink_exec('b328s', 'begin');
select count(*) from dblink('b328s', $q$select 1 from pgpm.config where parent_table = 'public.t328s1'::regclass for update$q$) as t(x int);
select dblink_exec('m328s', 'set lock_timeout = 0');
select dblink_exec('m328s', 'set statement_timeout = ''15s''');
select dblink_exec('h328s', 'set lock_timeout = 0');
select dblink_exec('h328s', 'set statement_timeout = ''15s''');
-- M: regrain() of s1, paused by B with its xid and SHARE: the older
select dblink_send_query('m328s', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328s1', (select child_name from t328s_src where parent = 't328s1')));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328s_pids where role = 'm')
                       and relation = 'public.t328s1'::regclass and mode = 'ShareLock' and granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
-- s2's copies, by maintain ticks, all after M's xid; the swap tick defers at its budget for M (not yet in a wait)
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328s2', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328s2'::regclass and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328s2'::regclass) = '500'
          and (select count(*) from pgpm.log where parent_table = 'public.t328s2'::regclass and action = 'regrain') = 0
          and (select age(m.backend_xmin) >= age(c.regrain_written_xid::xid) from pg_stat_activity m, pgpm.config c
                where m.pid = (select pid from t328s_pids where role = 'm') and c.parent_table = 'public.t328s2'::regclass),
  'LIVENESS: (S) s2''s copies are made after M began (M''s snapshot predates their last write), the swap not yet made');
-- H: the hand regrain_step at the swap: the younger; it lists M and enters its wait
select dblink_send_query('h328s', format('select pgpm.regrain_step(%L, %L, %L)', 'public.t328s2', (select child_name from t328s_src where parent = 't328s2'), '100'));
do $$
begin
  for i in 1..800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity a where a.pid = (select pid from t328s_pids where role = 'h') and a.wait_event = 'PgSleep')
       and exists (select 1 from pg_locks where pid = (select pid from t328s_pids where role = 'h') and objid = (select pid from t328s_pids where role = 'h')::oid
                    and locktype = 'advisory' and classid = 1885826423::oid and objsubid = 2 and granted) then
      insert into t328s_pids values ('h_waiting', 1);
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328s_pids where role = 'h_waiting')
          and (select age(m.backend_xid) > age(h.backend_xid) from pg_stat_activity m, pg_stat_activity h
                where m.pid = (select pid from t328s_pids where role = 'm') and h.pid = (select pid from t328s_pids where role = 'h')),
  'LIVENESS: (S) the hand regrain_step, the younger, is in its snapshot wait first, its marker held');
select dblink_send_query('o328s', format($q$do $o$ begin
  for i in 1..15000 loop
    if exists (select 1 from pg_locks where pid = %1$s and objid = %1$s::oid and locktype = 'advisory' and classid = 1885826423::oid and objsubid = 2 and granted) then
      insert into public.t328_seen values ('s', clock_timestamp());
      return;
    end if;
    perform pg_sleep(0.001);
  end loop;
end $o$$q$, (select pid from t328s_pids where role = 'm')));
select dblink_exec('b328s', 'commit');
\setenv T328_PIDS :s_m,:s_h,:s_o
\! for i in $(seq 1 400); do [ "$(psql -X -U postgres -d "$T328_DB" -Atc "select count(*) from pg_stat_activity where pid in ($T328_PIDS) and state = 'active'")" = "0" ] && break; sleep 0.1; done
select ok(exists (select 1 from public.t328_seen where who = 's'),
  'LIVENESS: (S) regrain(), the older, entered its own snapshot wait (its marker seen) while the step waited');
create temp table t328s_h as select x from dblink_get_result('h328s', false) as t(x text);
select ok(dblink_error_message('h328s') ~ ('^ERROR:  pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                          || (select pid from t328s_pids where role = 'm') || '(, [0-9]+)* are snapshot waits of other pgpm swaps, older than this one'),
  '(S) the hand regrain_step yielded at once, naming regrain() (not a statement timeout)');
create temp table t328s_m as select x from dblink_get_result('m328s', false) as t(x int);
select count(*) from dblink_get_result('m328s', false) as t(x int);
select is((select x from t328s_m), 5, '(S) regrain(), the older, did not yield: it completed, splitting its monolith into five');
select ok(exists (select 1 from pgpm.part p, t328s_src s where s.parent = 't328s2' and p.parent_table = 'public.t328s2'::regclass
                   and p.attached and p.child_oid = s.child_oid)
          and (select count(*) from pgpm.log where parent_table = 'public.t328s2'::regclass and action = 'regrain') = 0,
  '(S) the step swapped nothing: its source still attached, by oid');
select bag_eq($$ select id from public.t328s1 $$, $$ select g::bigint from generate_series(22, 484, 22) g union all select 3260 $$,
  '(S) regrain()''s table reads exactly its rows after the swap: the multiples of 22 to 484, and 3260');
select is(pgpm.regrain_step('public.t328s2', (select child_name from t328s_src where parent = 't328s2'), '100'), 'swapped:5',
  'LIVENESS: (S) run again on its own, the hand regrain_step swaps');
select bag_eq($$ select id from public.t328s2 $$, $$ select g::bigint from generate_series(23, 483, 23) g union all select 3360 $$,
  '(S) and its table reads exactly its rows: the multiples of 23 to 483, and 3360');
select dblink_disconnect('b328s');
select dblink_disconnect('m328s');
select dblink_disconnect('h328s');
select dblink_disconnect('o328s');

-- ============================================ PART T ============================================
create table public.t328t1 (id bigint generated by default as identity primary key, payload text);
insert into public.t328t1 (id, payload) select g, 't1-' || g from generate_series(24, 480, 24) g;
call pgpm.transmute('public.t328t1', 'id', 100, p_paused => false);                -- monolith [0, 500), regrain()
insert into public.t328t1 (id, payload) values (3270, 'frontier');
create table public.t328t2 (id bigint generated by default as identity primary key, payload text);
insert into public.t328t2 (id, payload) select g, 't2-' || g from generate_series(25, 475, 25) g;
call pgpm.transmute('public.t328t2', 'id', 100, p_paused => false);                -- monolith [0, 500), maintain
insert into public.t328t2 (id, payload) values (3370, 'frontier');
select pgpm.set_regrain('public.t328t2', '100');
create temp table t328t_src as
  select p.parent_table::text as parent, p.child_name, p.child_oid from pgpm.part p
   where p.parent_table in ('public.t328t1'::regclass, 'public.t328t2'::regclass) and p.attached and p.lo = '0';
create temp table t328t_pids (role text primary key, pid int);
select dblink_connect('x328t', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('b328t', 'dbname=' || current_database() || ' user=postgres');
select dblink_connect('m328t', 'dbname=' || current_database() || ' user=postgres');
-- X: a REPEATABLE READ reader opened before regrain(), holding no lock on either table, which regrain() waits for
select dblink_exec('x328t', 'begin isolation level repeatable read');
insert into t328t_pids select 'x', p from dblink('x328t', 'select pg_backend_pid() from pgpm.config limit 1') as t(p int);
insert into t328t_pids select 'm', p from dblink('m328t', 'select pg_backend_pid()') as t(p int);
select pid as t_m from t328t_pids where role = 'm' \gset
select dblink_exec('b328t', 'begin');
select count(*) from dblink('b328t', $q$select 1 from pgpm.config where parent_table = 'public.t328t1'::regclass for update$q$) as t(x int);
select dblink_exec('m328t', 'set lock_timeout = 0');
select dblink_exec('m328t', 'set statement_timeout = ''15s''');
select dblink_send_query('m328t', format('select pgpm.regrain(%L, %L, ''100'')', 'public.t328t1', (select child_name from t328t_src where parent = 't328t1')));
do $$
begin
  for i in 1..400 loop
    exit when exists (select 1 from pg_locks where pid = (select pid from t328t_pids where role = 'm')
                       and relation = 'public.t328t1'::regclass and mode = 'ShareLock' and granted);
    perform pg_sleep(0.01);
  end loop;
end $$;
-- t2's copies by maintain ticks, after M's xid; the swap tick defers at its budget (M is not in a wait yet)
set statement_timeout = '15s';   -- this session drives the ticks
do $$
declare v_status text;
begin
  for i in 1..40 loop
    call pgpm.maintain('public.t328t2', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328t2'::regclass and action in ('skip_regrain', 'regrain'));
  end loop;
end $$;
select ok((select regrain_cursor from pgpm.config where parent_table = 'public.t328t2'::regclass) = '500'
          and (select count(*) from pgpm.log where parent_table = 'public.t328t2'::regclass and action = 'regrain') = 0
          and not exists (select 1 from pgpm.log where parent_table = 'public.t328t2'::regclass and action = 'skip_regrain'
                           and method like '%are snapshot waits of other pgpm swaps%'),
  'LIVENESS: (T) t2''s copies are made after regrain() began, and the swap tick deferred by its budget (regrain() not yet in a wait)');
-- B lets go: regrain() copies and enters its wait, for X (and marks itself)
select dblink_exec('b328t', 'commit');
do $$
begin
  for i in 1..800 loop
    if exists (select 1 from pg_locks where pid = (select pid from t328t_pids where role = 'm') and objid = (select pid from t328t_pids where role = 'm')::oid
                and locktype = 'advisory' and classid = 1885826423::oid and objsubid = 2 and granted) then
      insert into t328t_pids values ('m_waiting', 1);
      exit;
    end if;
    perform pg_sleep(0.01);
  end loop;
end $$;
select ok(exists (select 1 from t328t_pids where role = 'm_waiting'),
  'LIVENESS: (T) regrain() is in its snapshot wait (for X), its marker held');
-- the tick: it lists regrain() (whose snapshot predates t2's copies), an older snapshot wait, and yields at once
do $$
declare v_status text;
begin
  call pgpm.maintain('public.t328t2', v_status);
end $$;
select ok(exists (select 1 from pgpm.log l where l.parent_table = 'public.t328t2'::regclass and l.action = 'skip_regrain'
                   and l.method ~ ('^pg_partition_magician: regrain swap deferred at once: pids ([0-9]+, )*'
                                   || (select pid from t328t_pids where role = 'm') || '(, [0-9]+)* are snapshot waits of other pgpm swaps, older than this one')),
  '(T) the tick deferred AT ONCE for regrain(), an older snapshot wait, logged skip_regrain naming it');
select is((select count(*) from pgpm.log where parent_table = 'public.t328t2'::regclass and action = 'regrain'), 0::bigint,
  '(T) and the tick did not swap');
select dblink_exec('x328t', 'commit');
\setenv T328_PIDS :t_m
\! for i in $(seq 1 400); do [ "$(psql -X -U postgres -d "$T328_DB" -Atc "select count(*) from pg_stat_activity where pid in ($T328_PIDS) and state = 'active'")" = "0" ] && break; sleep 0.1; done
create temp table t328t_m as select x from dblink_get_result('m328t', false) as t(x int);
select count(*) from dblink_get_result('m328t', false) as t(x int);
select is((select x from t328t_m), 5, '(T) regrain(), the older, completed once X ended, splitting its monolith into five');
do $$
declare v_status text;
begin
  for i in 1..10 loop
    call pgpm.maintain('public.t328t2', v_status);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.t328t2'::regclass and action = 'regrain');
  end loop;
end $$;
reset statement_timeout;
select is((select count(*) from pgpm.log where parent_table = 'public.t328t2'::regclass and action = 'regrain'), 1::bigint,
  'LIVENESS: (T) the next tick swapped');
select bag_eq($$ select id from public.t328t2 $$, $$ select g::bigint from generate_series(25, 475, 25) g union all select 3370 $$,
  '(T) t2 reads exactly its rows after the swap: the multiples of 25 to 475, and 3370');
select bag_eq($$ select id from public.t328t1 $$, $$ select g::bigint from generate_series(24, 480, 24) g union all select 3270 $$,
  '(T) t1 reads exactly its rows after regrain(): the multiples of 24 to 480, and 3270');
select dblink_disconnect('x328t');
select dblink_disconnect('b328t');
select dblink_disconnect('m328t');
select dblink_disconnect('r328g');
select dblink_disconnect('r328a');
select dblink_disconnect('r328b');
select dblink_disconnect('r328c');
select dblink_disconnect('r328d');
select dblink_disconnect('r328e');
select dblink_disconnect('r328f');
select dblink_disconnect('d328f');
select dblink_disconnect('w328f');
drop table public.t328e;
drop table public.t328h;
reassign owned by t328_owner, t328_reporter to current_user;
drop owned by t328_owner, t328_reporter;
drop role t328_owner;
drop role t328_reporter;
select * from finish();
