-- Issue #980 (review pass 9, F3-03): a regrain target step finer than a timestamp(p) or timestamptz(p)
-- control column's fractional-second precision is refused at call time and at every other regrain entry
-- point, as a step finer than a numeric column's scale is (#899).
--
-- _regrain_step_shape had a precision rule for a numeric key and none for a time key. set_regrain stored
-- '500 milliseconds' on a timestamptz(0) key, the run copied every sub-range, and at the swap ATTACH
-- PARTITION rounded each fine bound to whole seconds ('..:20.5' and '..:21' both to '..:21') and failed
-- 'empty range bound' on every tick, with the capture trigger and the TRUNCATE refusal left on the source
-- until the operator cancelled. The rule is now the column's precision: a fixed step must be a whole
-- number of 10^-p seconds, read through any domain; a month step is always whole seconds, and an
-- unconstrained timestamp keeps microseconds, below which an interval cannot go, so it refuses nothing.
--
-- Every refusal is pinned to its message and paired with a liveness witness that the same entry point
-- accepts a step the column can hold on the same table; a refused call must leave the valid target in
-- place; the completed splits are checked by which rows sit in which cell. Fixtures are asymmetric: ten
-- whole-second rows in a timestamptz(0) monolith split into 2-second cells; nine half-second rows in a
-- timestamp(1) monolith split into 0.5-second cells, every row in its own. The two monoliths are frozen by
-- waiting out one 10-second step, as the issue's reproduction does, since a time grid's frontier is now().
-- bench/regrain_target_time_precision.sh runs this file against the mutant regrain_step_time_precision_unread.
set timezone = 'UTC';
create extension if not exists pgtap;
select plan(32);

-- ============ two time grids with a frozen monolith: timestamptz(0) and naive timestamp(1) ============
create table public.tp0 (id bigint not null, ts timestamptz(0) not null, payload text, primary key (id, ts));
insert into public.tp0 select g, date_trunc('second', now()) - interval '25 seconds' + g * interval '1 second', 's' || g
  from generate_series(0, 9) g;
create table public.tp1 (id bigint not null, ts timestamp(1) not null, payload text, primary key (id, ts));
insert into public.tp1 select g, date_trunc('second', now()::timestamp) - interval '25 seconds' + g * interval '0.5 seconds', 'h' || g
  from generate_series(1, 9) g;
call pgpm.transmute('public.tp0', 'ts', interval '10 seconds', p_obtain => 3, p_paused => false);
call pgpm.transmute('public.tp1', 'ts', interval '10 seconds', p_obtain => 3, p_paused => false);
create temp table before0 as select id, ts::text as ts, payload from public.tp0;
create temp table before1 as select id, ts::text as ts, payload from public.tp1;
select pg_sleep(11);   -- the frontier moves past each monolith's hi, so it is frozen
create temp table mono as
  select parent_table, child_name from pgpm.part
   where parent_table in ('public.tp0'::regclass, 'public.tp1'::regclass) and attached
     and child_name like '%\_to\_%';

select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.tp0'::regclass and attname = 'ts'), 'timestamp(0) with time zone',
  'LIVENESS: tp0''s control column is timestamptz(0), which keeps whole seconds');
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.tp1'::regclass and attname = 'ts'), 'timestamp(1) without time zone',
  'LIVENESS: tp1''s control column is timestamp(1), which keeps tenths of a second');
select ok((select coarse_frozen from pgpm.progress('public.tp0')) > 0
          and (select coarse_frozen from pgpm.progress('public.tp1')) > 0
          and (select count(*) from mono) = 2,
  'LIVENESS: each table has a frozen coarse monolith for a regrain to pick');

select lives_ok($$ select pgpm.set_regrain('public.tp0', '2 seconds') $$,
  'LIVENESS: set_regrain accepts a whole-second finer step (2 seconds) on the timestamptz(0) column');
select throws_like($$ select pgpm.set_regrain('public.tp0', '500 milliseconds') $$,
  'pg_partition_magician: regrain target step 500 milliseconds for tp0 is finer than its control column ts can hold: it is timestamp(0) with time zone, which keeps whole seconds only%empty range bound%multiple of 1 second',
  'set_regrain refuses 500 milliseconds on a timestamptz(0) column, naming the column''s precision');
select throws_like($$ select pgpm.set_regrain('public.tp0', '1.5 seconds') $$,
  'pg_partition_magician: regrain target step 1.5 seconds for tp0 is finer than its control column ts can hold%',
  'set_regrain refuses 1.5 seconds as well, which is coarser than the unit but not a multiple of it');
select is((select regrain_to from pgpm.config where parent_table = 'public.tp0'::regclass), '2 seconds',
  'the refused calls left the valid target in place');

-- the operator-driven entry points go through the same check
select throws_like(format($$ select pgpm.regrain_step('public.tp0', %L, '500 milliseconds') $$,
                          (select child_name from mono where parent_table = 'public.tp0'::regclass)),
  'pg_partition_magician: regrain target step 500 milliseconds for tp0 is finer than its control column ts can hold%',
  'regrain_step refuses 500 milliseconds before it reads or mutates anything');
create function pg_temp.try_regrain(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'refused: ' || sqlerrm;
end $f$;
select alike(pg_temp.try_regrain('public.tp0', (select child_name from mono where parent_table = 'public.tp0'::regclass),
                                 '500 milliseconds'),
  'refused: pg_partition_magician: regrain target step 500 milliseconds for tp0 is finer than its control column ts can hold%',
  'regrain() refuses it too, rather than copying and failing at the swap');
select is((select count(*) from pgpm.part where parent_table = 'public.tp0'::regclass and not attached), 0::bigint,
  'the refusals minted no fine child');

-- a target an older install could have stored is refused at the tick, before anything is copied, with the
-- refusal's own words rather than the swap's 'empty range bound'
update pgpm.config set regrain_to = '500 milliseconds' where parent_table = 'public.tp0'::regclass;
set client_min_messages = warning;
call pgpm.maintain('public.tp0', null);
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.tp0'::regclass and action = 'skip_regrain'
                   and method like '%regrain target step 500 milliseconds for tp0 is finer than its control column ts can hold%'),
  'a stored 500 milliseconds makes the tick log skip_regrain with the refusal (the witness the three below lean on)');
select is((select count(*) from pgpm.log where parent_table = 'public.tp0'::regclass and action = 'skip_regrain'
            and method like '%empty range bound%'), 0::bigint,
  'and never the swap''s empty range bound');
select is((select count(*) from pgpm.part where parent_table = 'public.tp0'::regclass and not attached), 0::bigint,
  'the refused tick minted no fine child');
select is((select count(*) from pg_trigger t join mono m on t.tgrelid = format('%I.%I', 'public', m.child_name)::regclass
            where m.parent_table = 'public.tp0'::regclass
              and t.tgname in ('pgpm_regrain_capture', 'pgpm_regrain_truncate_guard')), 0::bigint,
  'and left neither the capture trigger nor the TRUNCATE refusal on the source');

-- with a whole-second target the same monolith splits, and every row is in the cell its key belongs to
select lives_ok($$ select pgpm.set_regrain('public.tp0', null) $$, 'fixture: auto-regrain off again');
select alike(pg_temp.try_regrain('public.tp0', (select child_name from mono where parent_table = 'public.tp0'::regclass),
                                '2 seconds'),
  'swapped:%', 'LIVENESS: regrain() splits the timestamptz(0) monolith into 2-second cells');
select is((select count(*) from pgpm.part where parent_table = 'public.tp0'::regclass
            and child_name = (select child_name from mono where parent_table = 'public.tp0'::regclass)), 0::bigint,
  'the monolith is gone from the record');
select is((with p as materialized (select child_name, lo, hi from pgpm.part
                                    where parent_table = 'public.tp0'::regclass and attached)
           select count(*) from public.tp0 r join pg_class c on c.oid = r.tableoid
             left join p on p.child_name = c.relname
            where p.child_name is null or not (r.ts >= p.lo::timestamptz and r.ts < p.hi::timestamptz)
               or p.hi::timestamptz - p.lo::timestamptz <> interval '2 seconds'), 0::bigint,
  'every tp0 row sits in a recorded 2-second cell that holds its key');
select set_eq($$ select id, ts::text, payload from public.tp0 $$, $$ select id, ts, payload from before0 $$,
  'every tp0 row survived the split with its own key and payload');

-- ======== timestamp(1): tenths are held, so 500 milliseconds is accepted and completes, 50 is not ========
select throws_like($$ select pgpm.set_regrain('public.tp1', '50 milliseconds') $$,
  'pg_partition_magician: regrain target step 50 milliseconds for tp1 is finer than its control column ts can hold: it is timestamp(1) without time zone, which keeps 1 fractional-second digit(s)%multiple of 0.1 seconds',
  'set_regrain refuses 50 milliseconds on a timestamp(1) column');
select lives_ok($$ select pgpm.set_regrain('public.tp1', '500 milliseconds') $$,
  'and accepts 500 milliseconds, which the column can hold');
select alike(pg_temp.try_regrain('public.tp1', (select child_name from mono where parent_table = 'public.tp1'::regclass),
                                '500 milliseconds'),
  'swapped:%', 'the 500 milliseconds regrain of the timestamp(1) monolith completes');
select is((with p as materialized (select child_name, lo, hi from pgpm.part
                                    where parent_table = 'public.tp1'::regclass and attached)
           select string_agg(r.payload || '@' || (p.hi::timestamp - p.lo::timestamp)::text
                               || case when r.ts >= p.lo::timestamp and r.ts < p.hi::timestamp then '' else ':outside' end,
                             ',' order by r.id)
             from public.tp1 r join pg_class c on c.oid = r.tableoid join p on p.child_name = c.relname),
          (select string_agg('h' || g || '@00:00:00.5', ',' order by g) from generate_series(1, 9) g),
  'every half-second row sits in its own 0.5-second cell, which holds its key');
select is((select count(distinct tableoid) from public.tp1), 9::bigint,
  'nine rows, nine distinct cells');
select set_eq($$ select id, ts::text, payload from public.tp1 $$, $$ select id, ts, payload from before1 $$,
  'every tp1 row survived the split with its own key and payload');

-- == the rule reads precision through domains, leaves month steps and unconstrained columns alone ==
-- Registered by hand, as tests/252's domain parents are: no entry point need be reached for set_regrain.
create domain public.ts0_dom as timestamptz(0);
create domain public.ts0_dom2 as public.ts0_dom;
create table public.hd (ts public.ts0_dom2 not null) partition by range (ts);
create table public.h3 (ts timestamptz(3) not null) partition by range (ts);
create table public.h6 (ts timestamptz not null) partition by range (ts);
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor)
  values ('public.hd', 'ts', 'time', '1 year', '2000-01-01 00:00:00+00'),
         ('public.h3', 'ts', 'time', '1 day', '2000-01-01 00:00:00+00'),
         ('public.h6', 'ts', 'time', '1 day', '2000-01-01 00:00:00+00');
select lives_ok($$ select pgpm.set_regrain('public.hd', '1 second') $$,
  'LIVENESS: set_regrain accepts a whole-second step on a domain over a domain over timestamptz(0)');
select throws_like($$ select pgpm.set_regrain('public.hd', '500 milliseconds') $$,
  'pg_partition_magician: regrain target step 500 milliseconds for hd is finer than its control column ts can hold: it is timestamp(0) with time zone, which keeps whole seconds only%',
  'and refuses 500 milliseconds there, reading the precision through both domains');
select lives_ok($$ select pgpm.set_regrain('public.hd', '1 month') $$,
  'a month step is whole seconds, so the timestamptz(0) column accepts it');
select throws_like($$ select pgpm.set_regrain('public.hd', '1 day 0.5 seconds') $$,
  'pg_partition_magician: regrain target step 1 day 0.5 seconds for hd is finer than its control column ts can hold%',
  'a step longer than a second is still refused when it is not a whole number of seconds');
select lives_ok($$ select pgpm.set_regrain('public.h3', '1 millisecond') $$,
  'LIVENESS: set_regrain accepts 1 millisecond on a timestamptz(3) column');
select throws_like($$ select pgpm.set_regrain('public.h3', '500 microseconds') $$,
  'pg_partition_magician: regrain target step 500 microseconds for h3 is finer than its control column ts can hold: it is timestamp(3) with time zone, which keeps 3 fractional-second digit(s)%multiple of 0.001 seconds',
  'and refuses 500 microseconds there');
select lives_ok($$ select pgpm.set_regrain('public.h6', '1 microsecond') $$,
  'an unconstrained timestamptz keeps microseconds, so the finest interval is accepted');

select * from finish();
