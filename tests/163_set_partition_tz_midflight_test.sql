-- set_partition_tz refuses a zone change while a regrain is in flight, and waits for a concurrent step
-- rather than judging state it has not committed yet (issue #660).
--
-- THE DEFECT. set_partition_tz judged only the ATTACHED bounds: the newest must floor to itself in the new
-- zone (#455), and every recorded-zone boundary among them must too (#583). An in-flight regrain was
-- invisible to both. Its copies sit in pgpm.part, not attached, on the OLD zone's lattice, and the cursor
-- sits at one of that lattice's boundaries; the rest of the run is computed in whatever zone config holds
-- at the next step. So a UTC month grid switched to Africa/Sao_Tome (UTC+1 through 2018, UTC before and
-- since, so it agrees with UTC at every attached bound below and disagrees inside the monolith) was
-- accepted mid-regrain; the next sub-range overlapped the last copy and left a hole beside it, and the
-- swap refused on every attempt, blaming a retention change that never happened.
--
-- THE CONTRACT. A zone CHANGE is refused while a run is in flight, naming regrain_cancel; the run is
-- untouched and completes in the zone it was started in, every row intact. Re-stating the zone already
-- recorded is not a change and is accepted. Once the run is cancelled, the same change is accepted: the
-- zone itself passes every lattice check, so the refusal is the in-flight rule and nothing else. And the
-- judgement waits for another session's step (here an uncommitted prepare) instead of reading around it.
--
-- Every negative below is paired with a witness that the run really was in flight first, and the rows
-- are compared by identity (an md5 over every key and payload), not by count.
-- bench/set_partition_tz_midflight.sh runs this file against a mutant with the refusal removed, and
-- `./test.sh discriminate` requires it to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(27);

-- ======================================================================================================
-- (A) a UTC month regrain is mid-flight; a zone change is refused, the run completes in UTC
-- ======================================================================================================
create table public.tz163 (id uuid primary key, payload text);
insert into public.tz163
  select pgpm._ts_to_uuid(ts), 'r' || row_number() over (order by ts)
    from generate_series(timestamptz '2017-12-05 00:00+00', timestamptz '2019-05-20 00:00+00', interval '3 days') ts;
call pgpm.transmute('public.tz163', 'id', interval '1 month', p_obtain => 2, p_paused => true, p_regrain_batch => 1000);
select pgpm._ts_text(max(hi::timestamptz)) as top from pgpm.part where parent_table = 'public.tz163'::regclass and attached \gset
insert into public.tz163 values (pgpm._ts_to_uuid(:'top'::timestamptz - interval '15 days'), 'frontier');   -- freezes the monolith
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_before from public.tz163 \gset
select child_name as mono, lo as mono_lo, hi as mono_hi from pgpm.part
 where parent_table = 'public.tz163'::regclass and attached order by lo::timestamptz limit 1 \gset

select is(pgpm.regrain_step('public.tz163', :'mono', '1 month'), 'prepared', 'fixture (A): the run is prepared');
select is(pgpm.regrain_step('public.tz163', :'mono', '1 month'), 'copied:9', 'fixture (A): December 2017 is copied');
select is(pgpm.regrain_step('public.tz163', :'mono', '1 month'), 'copied:11', 'fixture (A): January 2018 is copied');
select is(pgpm.regrain_step('public.tz163', :'mono', '1 month'), 'copied:9', 'fixture (A): February 2018 is copied');
select is((select regrain_cursor::timestamptz from pgpm.config where parent_table = 'public.tz163'::regclass),
  timestamptz '2018-03-01 00:00:00+00', 'LIVENESS (A): the run is in flight, its cursor at 2018-03-01 00:00Z');
select is((select array_agg(child_name::text order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.tz163'::regclass and not attached),
  array['tz163_p2017_12', 'tz163_p2018_01', 'tz163_p2018_02'],
  'LIVENESS (A): three copies on the UTC month lattice, not yet attached');
select ok(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', :'mono_lo', 'Africa/Sao_Tome')::timestamptz = :'mono_lo'::timestamptz
      and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', :'mono_hi', 'Africa/Sao_Tome')::timestamptz = :'mono_hi'::timestamptz
      and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', :'top', 'Africa/Sao_Tome')::timestamptz = :'top'::timestamptz,
  'LIVENESS (A): Sao_Tome agrees with UTC at the monolith''s bounds and at the grid top (the attached checks pass it)');
select isnt(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', '2018-03-01 00:00:00+00', 'Africa/Sao_Tome')::timestamptz,
  timestamptz '2018-03-01 00:00:00+00',
  'LIVENESS (A): and disagrees at the cursor: 2018-03-01 00:00Z is not a Sao_Tome month boundary');

select max(id) as mark_a from pgpm.log \gset
select throws_like($$ select pgpm.set_partition_tz('public.tz163', 'Africa/Sao_Tome') $$,
  '%set_partition_tz(tz163, Africa/Sao_Tome) refused -- a regrain of tz163 is in flight%pgpm.regrain_cancel(tz163)%',
  '(A) a zone change while the run is in flight is refused, naming regrain_cancel');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz163'::regclass), 'UTC',
  '(A) the zone is unchanged');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tz163'::regclass and id > :mark_a
            and action = 'set_partition_tz'), 0,
  '(A) and no zone change was logged');
select lives_ok($$ select pgpm.set_partition_tz('public.tz163', 'UTC') $$,
  '(A) re-stating the recorded zone mid-flight is accepted (the refusal is about a change)');
select is((select array_agg(child_name::text order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.tz163'::regclass and not attached),
  array['tz163_p2017_12', 'tz163_p2018_01', 'tz163_p2018_02'],
  '(A) the copies are untouched');

select is(pgpm.regrain('public.tz163', :'mono', '1 month'), (select count(*)::int from generate_series(:'mono_lo'::timestamptz, :'mono_hi'::timestamptz - interval '1 month', interval '1 month')),
  '(A) the run completes in UTC: the monolith is replaced by one child per UTC month of its range');
select ok(to_regclass(format('public.%I', :'mono')) is null, '(A) the monolith is gone');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.tz163'::regclass and attached
              and lo::timestamptz >= :'mono_lo'::timestamptz and hi::timestamptz <= :'mono_hi'::timestamptz),
  (select array_agg(m order by m) from generate_series(:'mono_lo'::timestamptz, :'mono_hi'::timestamptz - interval '1 month', interval '1 month') m),
  '(A) and its children start at exactly the UTC month boundaries of its range, none in the new zone');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.tz163), :'rows_before',
  '(A) every row is still there, by identity');
select ok(not exists (select 1 from pgpm.part a join pgpm.part b
                        on a.parent_table = b.parent_table and a.child_name < b.child_name
                       where a.parent_table = 'public.tz163'::regclass
                         and a.lo::timestamptz < b.hi::timestamptz and b.lo::timestamptz < a.hi::timestamptz),
  '(A) no two recorded partitions of the table overlap');

-- ======================================================================================================
-- (B) set_partition_tz while another session's prepare is uncommitted: it waits, then sees the run
-- ======================================================================================================
create table public.tz163b (id uuid primary key, payload text);
insert into public.tz163b
  select pgpm._ts_to_uuid(ts), 'b' from generate_series(timestamptz '2017-12-07 00:00+00', timestamptz '2018-09-30 00:00+00', interval '5 days') ts;
call pgpm.transmute('public.tz163b', 'id', interval '1 month', p_obtain => 2, p_paused => true, p_regrain_batch => 1000);
select pgpm._ts_text(max(hi::timestamptz)) as topb from pgpm.part where parent_table = 'public.tz163b'::regclass and attached \gset
insert into public.tz163b values (pgpm._ts_to_uuid(:'topb'::timestamptz - interval '15 days'), 'frontier');
select child_name as monob from pgpm.part
 where parent_table = 'public.tz163b'::regclass and attached order by lo::timestamptz limit 1 \gset

select dblink_connect('t163_a', 'dbname=' || current_database());
select dblink_connect('t163_b', 'dbname=' || current_database());
select pid as apid from dblink('t163_a', 'select pg_backend_pid()') as t(pid int) \gset
select pid as bpid from dblink('t163_b', 'select pg_backend_pid()') as t(pid int) \gset
select set_config('t163.bpid', :'bpid', false);
create table public.t163_outcome (who text primary key, state text, result text);

select dblink_exec('t163_a', 'set timezone = ''UTC''');
select dblink_exec('t163_a', 'begin');
select is((select x from dblink('t163_a',
            format('select pgpm.regrain_step(%L, %L, %L)', 'public.tz163b', :'monob', '1 month')) as t(x text)),
  'prepared', 'LIVENESS (B): session A prepared a month run and holds its transaction open');
select dblink_send_query('t163_b', $q$select pgpm.set_partition_tz('public.tz163b', 'Africa/Sao_Tome')::text$q$);
do $$ begin
  for i in 1 .. 6000 loop
    exit when exists (select 1 from pg_stat_activity where pid = current_setting('t163.bpid')::int
                       and wait_event_type = 'Lock');
    perform pg_sleep(0.005);
  end loop;
end $$;
select ok(exists (select 1 from pg_stat_activity where pid = :bpid and wait_event_type = 'Lock'),
  'LIVENESS (B): set_partition_tz is waiting on a lock...');
select ok(exists (select 1 from pg_stat_activity where pid = :apid and state = 'idle in transaction'),
  'LIVENESS (B): ...while the prepare is still uncommitted');
select dblink_exec('t163_a', 'commit');
do $$ declare v text; begin
  select x into v from dblink_get_result('t163_b') as t(x text);
  insert into public.t163_outcome values ('B', '00000', 'accepted');
exception when others then
  insert into public.t163_outcome values ('B', sqlstate, left(sqlerrm, 200));
end $$;
do $$ begin perform * from dblink_get_result('t163_b') as t(x text); exception when others then null; end $$;
select dblink_disconnect('t163_a');
select dblink_disconnect('t163_b');

select alike((select state || ' ' || result from public.t163_outcome where who = 'B'),
  'P0001 pg_partition_magician: set_partition_tz(tz163b, Africa/Sao_Tome) refused -- a regrain of tz163b is in flight%',
  '(B) set_partition_tz judged the run the prepare had committed, and refused');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz163b'::regclass), 'UTC',
  '(B) the zone is unchanged');
select ok(pgpm._regrain_capture_active('public.tz163b', :'monob'), '(B) the run it refused for is intact: capture on the source');

select is(pgpm.regrain_cancel('public.tz163b'), 0, '(B) the operator abandons the run (a prepare has no copies yet)');
select lives_ok($$ select pgpm.set_partition_tz('public.tz163b', 'Africa/Sao_Tome') $$,
  '(B) with the run cancelled, the same zone change is accepted: it passes every lattice check');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz163b'::regclass), 'Africa/Sao_Tome',
  '(B) and recorded');

select * from finish();
