-- Everything that drives or reconfigures a regrain in flight serialises on one per-parent lock, and
-- set_regrain refuses to retarget a run it did not start at that step (issue #554).
--
-- THE DEFECTS. Nothing in the regrain path took a per-parent lock across a step, so two drivers could act
-- on one run: a hand-driven regrain_step and a maintain tick computed their batches from the same cursor
-- and copied the same rows into the same fine child (the second died on the child's key after waiting
-- for the first); a tick that read the run's state before a regrain_cancel committed carried on from the
-- state the cancel had just torn down; and set_regrain, judging "is a run in flight" from state a
-- concurrent prepare had not committed yet, let a new target through. And set_regrain(parent, <another
-- step>) with a run in flight was accepted outright (pass-3 F8-02, pass-4 F3-02 and F9-03): nothing
-- records the run's own step, so every later tick walked the half-built run on the NEW grid, against
-- copies cut on the old one, and wedged: a CHECK violation on the old first child, or a swap re-check
-- that refused as if retention had been loosened, on every tick until someone found regrain_cancel.
--
-- THE CONTRACT.
--   (A) set_regrain(parent, X) is refused while a run is in flight unless X is the target already set; the
--       run is untouched and completes at its own step. Once it has swapped, the same call is accepted.
--   (B) regrain_to null and an operator-driven run in flight: a target is refused too (the run's step is
--       not recorded anywhere), until the run is cancelled or finished.
--   (C) two regrain_steps on one parent serialise: the second waits for the first to commit and then
--       copies the NEXT batch, never the same rows again.
--   (D) set_regrain waits for a prepare in flight in another session and then judges the run it made.
--   (E) a regrain_step issued while a regrain_cancel is uncommitted waits for it and then acts on the
--       state the cancel left, not on the run it tore down.
--
-- THE PROBES (C, D, E) use two dblink sessions ordered by lock state, never by sleeps: the first session
-- holds its step open in a transaction, the second is sent only then, and they are collected only once the
-- second is seen WAITING while the first is still idle in its transaction. Those are the liveness
-- witnesses: without them every outcome below also passes for a second call that simply ran after the
-- first had committed. bench/regrain_drivers_serialize.sh runs this file against mutants with the lock
-- removed and with the retarget refusal removed, and `./test.sh discriminate` requires it to FAIL on both.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(48);

-- ======================================================================================================
-- (A) auto-regrain toward 100 is mid-flight; retargeting it is refused, the run completes at 100
-- ======================================================================================================
create table public.rt (id bigint primary key, payload text);
insert into public.rt select g * 10, 'x' from generate_series(1, 299) g;        -- ids 10..2990, monolith [0, 3000)
call pgpm.transmute('public.rt', 'id', 1000, p_regrain_batch => 50);
insert into public.rt values (20000, 'frontier');                              -- the monolith is frozen
select pgpm.set_regrain('public.rt', '100');
select pgpm.resume('public.rt');
call pgpm.maintain('public.rt');    -- prepare
call pgpm.maintain('public.rt');    -- [0, 100): 9 rows < 50, complete
call pgpm.maintain('public.rt');    -- [100, 200): 10 rows < 50, complete
select child_name as mon_a from pgpm.part
 where parent_table = 'public.rt'::regclass and attached order by lo::numeric limit 1 \gset

select is(:'mon_a'::text, 'rt_p0000000000000000000_to_0000000000000003000',
  'fixture (A): the monolith is the frozen coarse child [0, 3000)');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rt'::regclass), '200',
  'LIVENESS (A): the run toward 100 is in flight, cursor at 200');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt'::regclass and not attached),
  array['0-100', '100-200'],
  'LIVENESS (A): two copies on the 100 grid are recorded, not yet attached');
select ok(pgpm._regrain_capture_active('public.rt', :'mon_a'), 'LIVENESS (A): capture sits on the source');

select max(id) as mark_a from pgpm.log \gset
select throws_like($$ select pgpm.set_regrain('public.rt', '500') $$,
  '%set_regrain(rt, 500) refused -- a regrain of rt is in flight%pgpm.regrain_cancel(rt)%',
  '(A) set_regrain to a different step while the run is in flight is refused, naming regrain_cancel');
select is((select regrain_to from pgpm.config where parent_table = 'public.rt'::regclass), '100',
  '(A) the target the run was started at is still the one set');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rt'::regclass), '200',
  '(A) the cursor is untouched');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt'::regclass and not attached),
  array['0-100', '100-200'],
  '(A) the copies are untouched');
select lives_ok($$ select pgpm.set_regrain('public.rt', '100') $$,
  '(A) set_regrain to the target already set is accepted mid-flight (the refusal is about a change)');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rt'::regclass), '200',
  '(A) and it leaves the run where it was');

do $$ declare s text; begin
  for i in 1 .. 60 loop
    exit when exists (select 1 from pgpm.log where parent_table = 'public.rt'::regclass
                        and action = 'regrain' and method = 'copy_swap_drop');
    call pgpm.maintain('public.rt', s);
  end loop;
end $$;
select is((select count(*)::int from pgpm.log where parent_table = 'public.rt'::regclass and id > :mark_a
            and action = 'regrain' and method = 'copy_swap_drop'), 1,
  '(A) the run swapped at its own step');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rt'::regclass and id > :mark_a
            and action = 'skip_regrain'), 0,
  '(A) no tick after the refused retarget was skipped');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.rt'::regclass and attached and hi::numeric <= 3000),
  (select array_agg((g * 100) || '-' || (g * 100 + 100) order by g) from generate_series(0, 29) g),
  '(A) the source was replaced by exactly the thirty cells of the 100 grid');
select is((select array_agg(id order by id) from public.rt),
  (select array_agg(i order by i) from (select g * 10::bigint as i from generate_series(1, 299) g
                                         union all select 20000) e),
  '(A) every row is present, by identity');
select lives_ok($$ select pgpm.set_regrain('public.rt', '500') $$,
  '(A) with nothing in flight, the same retarget is accepted');
select is((select regrain_to from pgpm.config where parent_table = 'public.rt'::regclass), '500',
  '(A) and recorded');

-- ======================================================================================================
-- (C) two regrain_steps on one parent, the first held open: the second waits, then copies the next batch
-- ======================================================================================================
create table public.rd (id bigint primary key, payload text);
insert into public.rd select g, 'o' from generate_series(1, 4000) g;
insert into public.rd select g, 'o' from generate_series(10001, 10500) g;       -- monolith [0, 20000)
call pgpm.transmute('public.rd', 'id', 10000, p_regrain_batch => 1000);
insert into public.rd values (123456, 'frontier');
select child_name as mon_c from pgpm.part
 where parent_table = 'public.rd'::regclass and attached order by lo::numeric limit 1 \gset
select is(:'mon_c'::text, 'rd_p0000000000000000000_to_0000000000000020000',
  'fixture (C): the monolith is the frozen coarse child [0, 20000)');
select is(pgpm.regrain_step('public.rd', :'mon_c', '5000', 1000), 'prepared', 'fixture (C): the run is prepared');
-- A write far up the source ([10000, 15000), which the copy has not reached, so no reconcile takes the
-- steps below) gives the delta rows. That matters to the probe: a step ANALYZEs the delta while it has no
-- row estimate, and ANALYZE's SHARE UPDATE EXCLUSIVE would serialise the two steps below by accident,
-- which is exactly what hid the missing lock from a first draft of this section.
update public.rd set payload = 'u' where id = 10100;
select is(pgpm.regrain_step('public.rd', :'mon_c', '5000', 1000), 'copied:1000',
  'fixture (C): the first batch of [0, 5000) is copied');
select is(pgpm._regrain_delta_count('public.rd'), 2::bigint,
  'fixture (C): the write far up the source is captured (old + new) and not yet reconciled');
select ok((select c.reltuples > 0 from pgpm._regrain_capture_names('public.rd') n
             join pg_class c on c.oid = format('public.%I', n.delta)::regclass),
  'LIVENESS (C): the delta has a row estimate, so neither step below ANALYZEs it (no accidental serialisation)');

select dblink_connect('c162_a', 'dbname=' || current_database());
select dblink_connect('c162_b', 'dbname=' || current_database());
select pid as apid from dblink('c162_a', 'select pg_backend_pid()') as t(pid int) \gset
select pid as bpid from dblink('c162_b', 'select pg_backend_pid()') as t(pid int) \gset
select set_config('c162.bpid', :'bpid', false);
create table public.c162_outcome (who text primary key, state text, result text);

-- A: one step of 700, held open
select dblink_exec('c162_a', 'begin');
select is((select x from dblink('c162_a',
            format('select pgpm.regrain_step(%L, %L, %L, 700)', 'public.rd', :'mon_c', '5000')) as t(x text)),
  'copied:700', 'LIVENESS (C): session A copied its batch of 700 and holds its transaction open');
-- B: a second driver on the same parent, one step of 500
select dblink_send_query('c162_b',
  format('select pgpm.regrain_step(%L, %L, %L, 500)', 'public.rd', :'mon_c', '5000'));
do $$ begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_stat_activity where pid = current_setting('c162.bpid')::int
                       and wait_event_type = 'Lock');
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS (C): session B is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS (C): ...while session A''s step is still uncommitted');
select dblink_exec('c162_a', 'commit');
do $$ declare v text; begin
  select x into v from dblink_get_result('c162_b') as t(x text);
  insert into public.c162_outcome values ('C', '00000', v);
exception when others then
  insert into public.c162_outcome values ('C', sqlstate, left(sqlerrm, 200));
end $$;
do $$ begin perform * from dblink_get_result('c162_b') as t(x text); exception when others then null; end $$;

select is((select state || ' ' || result from public.c162_outcome where who = 'C'), '00000 copied:500',
  '(C) session B ran after A committed and copied its own batch of 500');
select is((select md5(string_agg(id::text, ',' order by id)) from public.rd_p0000000000000000000),
  (select md5(string_agg(g::text, ',' order by g)) from generate_series(1, 2200) g),
  '(C) the fine child holds exactly ids 1..2200: 1000, then A''s 700, then B''s 500, nothing twice');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rd'::regclass), '0',
  '(C) the sub-range is not complete yet, so the cursor has not moved');

-- ======================================================================================================
-- (D) set_regrain while another session's prepare is uncommitted: it waits, then sees the run and refuses
-- ======================================================================================================
create table public.rp (id bigint primary key, payload text);
insert into public.rp select g, 'o' from generate_series(1, 3000) g;
insert into public.rp select g, 'o' from generate_series(10001, 10200) g;       -- monolith [0, 20000)
call pgpm.transmute('public.rp', 'id', 10000, p_regrain_batch => 1000);
insert into public.rp values (123456, 'frontier');
select child_name as mon_d from pgpm.part
 where parent_table = 'public.rp'::regclass and attached order by lo::numeric limit 1 \gset
select is((select regrain_to from pgpm.config where parent_table = 'public.rp'::regclass), null,
  'fixture (D): auto-regrain is off; the run below is operator-driven');

select dblink_exec('c162_a', 'begin');
select is((select x from dblink('c162_a',
            format('select pgpm.regrain_step(%L, %L, %L)', 'public.rp', :'mon_d', '5000')) as t(x text)),
  'prepared', 'LIVENESS (D): session A prepared a run at 5000 and holds its transaction open');
select dblink_send_query('c162_b', $q$select pgpm.set_regrain('public.rp', '2500')::text$q$);
do $$ begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_stat_activity where pid = current_setting('c162.bpid')::int
                       and wait_event_type = 'Lock');
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS (D): set_regrain is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS (D): ...while the prepare is still uncommitted');
select dblink_exec('c162_a', 'commit');
do $$ declare v text; begin
  select x into v from dblink_get_result('c162_b') as t(x text);
  insert into public.c162_outcome values ('D', '00000', 'accepted');
exception when others then
  insert into public.c162_outcome values ('D', sqlstate, left(sqlerrm, 200));
end $$;
do $$ begin perform * from dblink_get_result('c162_b') as t(x text); exception when others then null; end $$;

select alike((select state || ' ' || result from public.c162_outcome where who = 'D'),
  'P0001 pg_partition_magician: set_regrain(rp, 2500) refused -- a regrain of rp is in flight%',
  '(D) set_regrain judged the run the prepare had committed, and refused');
select is((select regrain_to from pgpm.config where parent_table = 'public.rp'::regclass), null,
  '(D) auto-regrain is still off');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rp'::regclass), '0',
  '(D) the operator''s run is intact, cursor at its lo');

-- (B) the same state, single-session: even the run's own step is refused, since nothing records it
select throws_like($$ select pgpm.set_regrain('public.rp', '5000') $$,
  '%set_regrain(rp, 5000) refused -- a regrain of rp is in flight%',
  '(B) with regrain_to null, a target is refused while an operator-driven run is in flight');
select is(pgpm.regrain_cancel('public.rp'), 0, '(B) the operator abandons the run (a prepare has no copies yet)');
select lives_ok($$ select pgpm.set_regrain('public.rp', '2500') $$,
  '(B) with the run cancelled, the same target is accepted');
select is((select regrain_to from pgpm.config where parent_table = 'public.rp'::regclass), '2500',
  '(B) and recorded');

-- ======================================================================================================
-- (E) a regrain_step issued while a regrain_cancel is uncommitted acts on what the cancel left
-- ======================================================================================================
create table public.rc (id bigint primary key, payload text);
insert into public.rc select g, 'o' from generate_series(1, 2000) g;
insert into public.rc select g, 'o' from generate_series(10001, 10300) g;       -- monolith [0, 20000)
call pgpm.transmute('public.rc', 'id', 10000, p_regrain_batch => 1000);
insert into public.rc values (123456, 'frontier');
select child_name as mon_e from pgpm.part
 where parent_table = 'public.rc'::regclass and attached order by lo::numeric limit 1 \gset
select is(pgpm.regrain_step('public.rc', :'mon_e', '5000', 1000), 'prepared', 'fixture (E): the run is prepared');
select is(pgpm.regrain_step('public.rc', :'mon_e', '5000', 5000), 'copied:2000',
  'fixture (E): [0, 5000) is copied whole');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rc'::regclass), '5000',
  'LIVENESS (E): the run is in flight with the cursor past its first sub-range');
select max(id) as mark_e from pgpm.log \gset

select dblink_exec('c162_a', 'begin');
select is((select x::int from dblink('c162_a', $q$select pgpm.regrain_cancel('public.rc')::text$q$) as t(x text)), 1,
  'LIVENESS (E): session A cancelled the run (one copy dropped) and holds its transaction open');
select dblink_send_query('c162_b',
  format('select pgpm.regrain_step(%L, %L, %L, 1000)', 'public.rc', :'mon_e', '5000'));
do $$ begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_stat_activity where pid = current_setting('c162.bpid')::int
                       and wait_event_type = 'Lock');
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS (E): the second step is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS (E): ...while the cancel is still uncommitted');
select dblink_exec('c162_a', 'commit');
do $$ declare v text; begin
  select x into v from dblink_get_result('c162_b') as t(x text);
  insert into public.c162_outcome values ('E', '00000', v);
exception when others then
  insert into public.c162_outcome values ('E', sqlstate, left(sqlerrm, 200));
end $$;
do $$ begin perform * from dblink_get_result('c162_b') as t(x text); exception when others then null; end $$;
select dblink_disconnect('c162_a');
select dblink_disconnect('c162_b');

select is((select state || ' ' || result from public.c162_outcome where who = 'E'), '00000 prepared',
  '(E) the step ran after the cancel committed and prepared a fresh run');
select is((select array_agg(action order by id) from pgpm.log where parent_table = 'public.rc'::regclass
            and id > :mark_e and action in ('regrain_cancel', 'regrain_restart', 'regrain_prepare')),
  array['regrain_cancel', 'regrain_prepare'],
  '(E) it started from the state the cancel left (no cursor): no restart of the run the cancel had already torn down');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rc'::regclass), '0',
  '(E) the fresh run sits at its lo');
select is((select coalesce(array_agg(child_name::text), '{}') from pgpm.part
            where parent_table = 'public.rc'::regclass and not attached), '{}'::text[],
  '(E) the cancelled run''s copy is gone and the fresh one has none yet');

select * from finish();
