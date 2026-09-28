-- set_partition_tz judges every bound of the grid, not only the newest (issue #583).
--
-- set_partition_tz refuses a zone the grid built so far is not on, and it used to establish that from the
-- newest attached bound alone. Two zones can agree there and disagree further down: UTC and Europe/London
-- share every month edge from November to March and none from April to October. So a UTC month grid
-- whose monolith ended on October 1 and whose top was December 1 was moved to London, and the monolith
-- could then never be regrained: regrain_step clamps its sub-ranges to the child's own bounds, the last
-- one was [September 30 23:00Z, October 1 00:00Z), which renders the label of the forward cell starting
-- at October 1, gets no fine child, and the swap refused on every attempt (auto-regrain logged
-- skip_regrain on every tick, blaming a retention change that never happened).
--
-- The fix: every attached bound that is a grid boundary in the recorded zone must be one in the new zone
-- too. Only those, so a finer regrain's bounds (a day child inside a month grid, on no month lattice in
-- any zone) and the upgrade case (a grid built in a zone pgpm had not recorded) are still accepted, and
-- both are pinned below as the refusal's liveness side.
--
-- The zone pair is chosen from the current date, as the issue's reproduction does, so the premise holds
-- whenever this runs: the grid zone Y and the new zone Z agree at the grid's top and disagree at the
-- monolith's hi. March to September: UTC -> Europe/London. October to February: Atlantic/Azores -> UTC
-- (the Azores are an hour behind UTC in winter and level with it in summer). Every premise is asserted as
-- a LIVENESS witness. bench/set_partition_tz_every_bound.sh runs this file against a mutant that checks
-- the newest bound alone again (set_partition_tz_newest_bound_only), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(18);

select case when extract(month from now() at time zone 'UTC') between 3 and 9 then 'UTC' else 'Atlantic/Azores' end as y,
       case when extract(month from now() at time zone 'UTC') between 3 and 9 then 'Europe/London' else 'UTC' end as z \gset
set timezone = :'y';
-- the monolith's hi is the first grid boundary after now() in Y; obtain is chosen so the top lands where Y and Z agree
select pgpm._grid_next('time', '1 month', pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', pgpm._ts_text(now()), :'y'), :'y') as mhi \gset
select min(n) as nobt from generate_series(2, 12) n
 where (select b::timestamptz = pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', b, :'z')::timestamptz
          from (select pgpm._ts_text((((:'mhi'::timestamptz at time zone :'y') + make_interval(months => n)) at time zone :'y')) as b) s) \gset

-- ==================== (a) the grid: a Y month grid whose monolith ends where Z has no month edge ====================
-- a uuidv7 key, so that section (c) can freeze the monolith: its frontier is the newer of the data and
-- the clock, where a timestamptz column's is the clock alone
create table public.tz_u (id uuid primary key, payload text);
insert into public.tz_u
  select pgpm._ts_to_uuid(ts), 'r' || row_number() over (order by ts)
    from generate_series(:'mhi'::timestamptz - interval '5 months', now() - interval '1 hour', interval '1 day') ts;
call pgpm.transmute('public.tz_u', 'id', interval '1 month', p_obtain => :nobt, p_paused => true, p_regrain_batch => 1000);
select child_name as mono, hi as mono_hi from pgpm.part
 where parent_table = 'public.tz_u'::regclass and attached order by lo::timestamptz limit 1 \gset
select pgpm._ts_text(max(hi::timestamptz)) as top from pgpm.part where parent_table = 'public.tz_u'::regclass and attached \gset
-- the oldest attached bound that is not a month boundary in Z: the one the refusal must name
select b as off_bound from (select lo as b from pgpm.part where parent_table = 'public.tz_u'::regclass and attached
                            union select hi from pgpm.part where parent_table = 'public.tz_u'::regclass and attached) s
 where pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', b, :'z')::timestamptz <> b::timestamptz
 order by b::timestamptz limit 1 \gset
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_before from public.tz_u \gset

select is((select partition_tz from pgpm.config where parent_table = 'public.tz_u'::regclass), :'y',
  format('LIVENESS: the grid is recorded in %s', :'y'));
select is(:'mono_hi'::timestamptz, :'mhi'::timestamptz,
  'LIVENESS: the monolith ends at the first grid boundary after now() in the grid zone');
select isnt(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', :'mono_hi', :'z')::timestamptz, :'mono_hi'::timestamptz,
  format('LIVENESS: the monolith hi %s is not a month boundary in %s', :'mono_hi', :'z'));
select is(pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', :'top', :'z')::timestamptz, :'top'::timestamptz,
  format('LIVENESS: the grid top %s IS a month boundary in %s, so a newest-bound check alone would accept the zone', :'top', :'z'));

-- ==================== (b) the refusal, and what it leaves untouched ====================
select throws_like(
  format($$ select pgpm.set_partition_tz('public.tz_u', %L) $$, :'z'),
  format('%%set_partition_tz(tz_u, %s) refused -- partition tz_u_p%% has a bound at %s, which is a 1 mon grid boundary in %s (the zone the grid is recorded in) but not in %s%%',
         :'z', :'off_bound', :'y', :'z'),
  'set_partition_tz refuses a zone an older bound is not on, and names the oldest such bound');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz_u'::regclass), :'y',
  'the refusal left partition_tz untouched');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tz_u'::regclass and action = 'set_partition_tz'), 0,
  'and logged nothing');

-- the check is not a refusal of everything: the zone the grid IS on passes it, and is logged
select lives_ok(format($$ select pgpm.set_partition_tz('public.tz_u', %L) $$, :'y'),
  'set_partition_tz accepts the zone the grid is on');
select is((select string_agg(method, ',') from pgpm.log where parent_table = 'public.tz_u'::regclass and action = 'set_partition_tz'),
  :'y' || ' -> ' || :'y', 'exactly the accepted call was logged');

-- ==================== (c) a finer regrain's bounds are not a grid's, and do not count ====================
-- a write in the newest forward cell moves the frontier past the monolith, freezing it
insert into public.tz_u values (pgpm._ts_to_uuid(:'top'::timestamptz - interval '15 days'), 'frontier');
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_before from public.tz_u \gset
select lives_ok(format($$ select pgpm.regrain('public.tz_u', %L, '1 day') $$, :'mono'),
  'LIVENESS: the monolith regrains to days in its own zone');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.tz_u'::regclass and child_name = :'mono'),
  'LIVENESS: the monolith is gone from the catalog after the regrain');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.tz_u'::regclass and attached
                   and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', lo, :'y')::timestamptz <> lo::timestamptz),
  format('LIVENESS: attached day children now have bounds that are not month boundaries in %s', :'y'));
select lives_ok(format($$ select pgpm.set_partition_tz('public.tz_u', %L) $$, :'y'),
  'set_partition_tz still accepts the grid''s own zone with day children in it: their bounds are on no month lattice, so they are not judged');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.tz_u), :'rows_before',
  'every row is still there after the regrain, by identity');

-- ==================== (d) the upgrade case: a grid built in Z, recorded as Y ====================
set timezone = :'z';
create table public.tz_w (id bigint generated always as identity, ts timestamptz not null, payload text, primary key (id, ts));
insert into public.tz_w (ts, payload)
  select ts, 'w' || row_number() over (order by ts)
    from generate_series(now() - interval '7 months', now() - interval '1 hour', interval '2 days') ts;
call pgpm.transmute('public.tz_w', 'ts', interval '1 month', p_obtain => 4, p_paused => true);
set timezone = :'y';
-- what an install that predates the column records, in its general form: a zone the grid was not built in
update pgpm.config set partition_tz = :'y' where parent_table = 'public.tz_w'::regclass;
select ok(exists (select 1 from pgpm.part where parent_table = 'public.tz_w'::regclass and attached
                   and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', lo, :'y')::timestamptz <> lo::timestamptz),
  format('LIVENESS: tz_w has a bound that is not a month boundary in the recorded %s, so the record is really wrong', :'y'));
select ok(not exists (select 1 from pgpm.part p cross join lateral (values (p.lo), (p.hi)) b(bound)
                       where p.parent_table = 'public.tz_w'::regclass and p.attached
                         and pgpm._grid_floor('time', '1 month', '2000-01-01 00:00:00+00', b.bound, :'z')::timestamptz <> b.bound::timestamptz),
  format('LIVENESS: every bound of tz_w is a month boundary in %s, where it was built', :'z'));
select lives_ok(format($$ select pgpm.set_partition_tz('public.tz_w', %L) $$, :'z'),
  'set_partition_tz accepts the zone a grid was really built in (the upgrade case it exists for)');
select is((select partition_tz from pgpm.config where parent_table = 'public.tz_w'::regclass), :'z',
  'and records it');

select * from finish();
