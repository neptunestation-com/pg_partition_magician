-- Issue #571: the #513 tie extension in pgpm._next_archive_chunk (a chunk that ends inside one native unit
-- is carried to the first row minted after that unit) read that row with `select min(<control>)`, and
-- PostgreSQL has no min(uuid) before 18. #507 had replaced the picker's two other aggregate reads with
-- ORDER BY ... LIMIT 1 and missed this one. So on a uuidv7 table with an archive_fn, one millisecond that
-- holds a chunk's worth of rows (a bulk import minted within one ms) raised 42883 at every pick: every
-- tick's archive step was logged skip_archive, no ledger row was written past the burst, and the aged
-- partition was never covered nor retired.
--
-- tests/125_archive_chunk_ties covers the same tie on the text_time grid and says, in its header, that
-- it leaves the uuidv7 path out; this file is that path. The fixture is tests/125's, re-encoded as uuidv7:
-- 100 ids minted in the one millisecond 2020-01-15 00:00:00.000, a 2000-byte budget that holds fewer than
-- 100 of them, one marker before the burst and two after it in the same partition, one a month on, a live
-- marker the year after and a frontier pin two years out. Counts are asymmetric (1, 100, 3, and 2
-- survivors) so no two chunk errors can cancel in a total. The monolith is split into year children by
-- a hand-driven regrain behind a frontier pinned with pgpm.extend_to, for the reason tests/125 gives.
--
-- On PostgreSQL 18, which has min(uuid), this file passes with or without the fix; the discriminate
-- track runs it against the mutant on 17, through bench/archive_chunk_uuidv7_ties.sh.
set timezone = 'UTC';
create extension if not exists pgtap;

select plan(14);

create schema pgpm_test137;

-- a uuidv7 id minted at p_ts: the 48-bit millisecond from pgpm._ts_to_uuid, version 7, variant 10, and
-- p_n in the random bits, so ids at one millisecond are distinct and ordered by p_n
create function pgpm_test137.u7_at(p_ts timestamptz, p_n int) returns uuid language sql immutable as $$
  select (substr(pgpm._ts_to_uuid(p_ts)::text, 1, 14) || '7' || lpad(to_hex(p_n), 3, '0')
          || '-8' || lpad(to_hex(p_n), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid $$;

create table public.u7t137 (id uuid primary key, v int not null);
insert into public.u7t137 values (pgpm_test137.u7_at('2020-01-10 00:00:00+00', 1), -1);   -- before the burst
insert into public.u7t137
  select pgpm_test137.u7_at('2020-01-15 00:00:00+00', g), g from generate_series(1, 100) g; -- the burst: one ms
insert into public.u7t137 values (pgpm_test137.u7_at('2020-01-20 00:00:00+00', 1), -4);   -- after the burst,
insert into public.u7t137 values (pgpm_test137.u7_at('2020-01-21 00:00:00+00', 1), -5);   -- same partition
insert into public.u7t137 values (pgpm_test137.u7_at('2020-02-10 00:00:00+00', 1), -2);   -- a month on

-- retention pinned so the horizon is 2021-06-15 whenever this runs (floor on the year grid: 2021-01-01)
select (now() - timestamptz '2021-06-15 00:00:00+00') as ret \gset
call pgpm.transmute('public.u7t137', 'id', interval '1 year', p_obtain => 1, p_retain => :'ret'::interval,
  p_paused => false);
select pgpm.set_archive_fn('public.u7t137', 'pgpm._archive_noop(regclass,name,text,text)');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.u7t137'::regclass;

-- pin the frontier: 15 June, two years from this year, in a partition built for it
select (date_trunc('year', now()) + interval '2 years 5 months 14 days') as t_pin \gset
select pgpm.extend_to('public.u7t137', pgpm_test137.u7_at(:'t_pin'::timestamptz, 1)::text) as extended \gset
insert into public.u7t137 values (pgpm_test137.u7_at(:'t_pin'::timestamptz, 1), -9);
insert into public.u7t137 values (pgpm_test137.u7_at('2021-03-10 00:00:00+00', 1), -3);  -- live: must survive

select is((select control_kind from pgpm.config where parent_table = 'public.u7t137'::regclass), 'uuidv7',
  'LIVENESS: the table is managed as uuidv7, the control kind whose tie read used min(uuid)');
select is(pgpm._frontier_native('public.u7t137')::timestamptz, :'t_pin'::timestamptz,
  'LIVENESS: the frontier is pinned two years out by the -9 row, so the monolith is frozen and can regrain');

-- split the monolith into year children, as tests/74 and tests/125 do
create table pgpm_test137.regrain as select null::text as last_status, 0 as ticks;
do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.u7t137'::regclass
     and lo::timestamptz = '2020-01-01 00:00:00+00';
  loop
    v_status := pgpm.regrain_step('public.u7t137', v_child, '1 year', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or v_status in ('active', 'nokey', 'nosubdiv') or i > 100;
  end loop;
  update pgpm_test137.regrain set last_status = v_status, ticks = i;
end $$;
select alike((select last_status from pgpm_test137.regrain), 'swapped:%',
  'LIVENESS: the regrain swapped the monolith for year children');

select child_name as y2020 from pgpm.part
 where parent_table = 'public.u7t137'::regclass and lo::timestamptz = '2020-01-01 00:00:00+00' \gset
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.u7t137'::regclass and child_name = :'y2020'),
  timestamptz '2021-01-01 00:00:00+00',
  'LIVENESS: the 2020 child is [2020-01-01, 2021-01-01), at the horizon and so drop-eligible');

-- the conditions for the defect: one native millisecond holding more rows than the budget admits
select is((select array_agg(distinct pgpm._uuid_to_ts(id)) from public.u7t137 where v > 0),
  array[timestamptz '2020-01-15 00:00:00+00'],
  'LIVENESS: every burst row decodes to the one native millisecond 2020-01-15 00:00:00.000');
select is((select count(distinct id)::int from public.u7t137 where v > 0), 100,
  'LIVENESS: and they are 100 distinct ids, so the column has ties the native grid does not');
select cmp_ok((select floor(2000 / avg(pg_column_size(t.*)))::int from public.u7t137 t where v > 0), '<', 100,
  'LIVENESS: a 2000-byte budget holds fewer than 100 of these rows, so the burst cannot fit one chunk');

-- ---------------------------------------------------------------------------------------------------
-- tick one: the child is write-blocked and the first chunk stops at the burst's millisecond

call pgpm.maintain('public.u7t137');

select ok(pgpm._is_write_blocked('public.u7t137', :'y2020'),
  'LIVENESS: after one tick the 2020 child is write-blocked, so the archive step is working on it');
select is((select array_agg(format('[%s, %s) %s', to_char(lo::timestamptz, 'YYYY-MM-DD'),
                                   to_char(hi::timestamptz, 'YYYY-MM-DD'), rows_archived) order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 'public.u7t137'::regclass and child_name = :'y2020'),
  array['[2020-01-01, 2020-01-15) 1'],
  'LIVENESS: the first chunk ends at the burst millisecond: the next pick starts inside it and must take the tie extension');

-- ---------------------------------------------------------------------------------------------------
-- the pick the defect broke, called directly with the arguments _archive_step passes it: it must not
-- raise, and it must hand back the burst's chunk, ending at the first row minted after the millisecond.
-- The error, if any, is caught and kept as the result, so the assertion reports it as what it got.

create table pgpm_test137.pick (result text);
do $$
declare v text;
begin
  select format('[%s, %s)', to_char(lo::timestamptz, 'YYYY-MM-DD HH24:MI:SS.MS'), to_char(hi::timestamptz, 'YYYY-MM-DD'))
    into v from pgpm._next_archive_chunk('public.u7t137',
                  (select child_name from pgpm.part where parent_table = 'public.u7t137'::regclass
                      and lo::timestamptz = '2020-01-01 00:00:00+00'));
  insert into pgpm_test137.pick values (v);
exception when others then
  insert into pgpm_test137.pick values (sqlstate || ': ' || sqlerrm);
end $$;
select is((select result from pgpm_test137.pick),
  '[2020-01-15 00:00:00.000, 2020-01-20)',
  'the picker reads past the tied millisecond without min(uuid) and ends the chunk at the next row minted after it');

-- ---------------------------------------------------------------------------------------------------
-- the rest of the pipeline, up to a dozen ticks or until the child is retired

do $$ declare i int := 0; v_status text; begin
  while i < 12 and exists (select 1 from pgpm.part where parent_table = 'public.u7t137'::regclass
                            and lo::timestamptz = '2020-01-01 00:00:00+00') loop
    call pgpm.maintain('public.u7t137', v_status);
    i := i + 1;
  end loop;
end $$;

-- THE assertion: the burst travelled whole in the chunk after the first, and the short read after it
-- reached the child's hi. The defect left the ledger at the first row of this array, every tick.
select is((select array_agg(format('[%s, %s) %s', to_char(lo::timestamptz, 'YYYY-MM-DD'),
                                   to_char(hi::timestamptz, 'YYYY-MM-DD'), rows_archived) order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 'public.u7t137'::regclass and child_name = :'y2020'),
  array['[2020-01-01, 2020-01-15) 1', '[2020-01-15, 2020-01-20) 100', '[2020-01-20, 2021-01-01) 3'],
  'the chunk after the first carries the whole burst and ends at 2020-01-20; the next reaches hi');

select is(to_regclass(format('public.%I', :'y2020')), null::regclass,
  'once covered, the 2020 child was retired');
select is((select array_agg(v order by v) from public.u7t137), array[-9, -3],
  'what remains is exactly the live marker and the frontier pin: the burst and the four aged markers went with the child');

-- The symptom the issue names, paired with the ledger assertions above, which show the archive step ran.
select is((select array_agg(distinct action order by action) from pgpm.log
            where parent_table = 'public.u7t137'::regclass
              and action in ('skip_archive', 'fail_archive_identity', 'fail_archive_contract',
                             'skip_retain', 'fail_retain_drop', 'fail_retain_identity', 'fail_retain_detach',
                             'fail_retain_crossing', 'skip_write_block', 'skip_regrain')),
  null,
  'no archive, retain or regrain step was deferred or refused along the way');

select * from finish();
