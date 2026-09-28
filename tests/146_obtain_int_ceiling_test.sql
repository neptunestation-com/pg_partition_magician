-- Issue #578: obtain() on an `int` (or `smallint`) id column must stop at the TYPE's ceiling with what
-- it built, exactly as it stops at uuidv7's 48-bit ceiling (#299), instead of raising and rolling back
-- every buildable partition.
--
-- obtain's grid-ceiling guard used to trap errors from _encode only, and _encode is a passthrough for
-- `id`: it cannot know the column is int4. The out-of-range bound therefore raised from CREATE TABLE ...
-- PARTITION OF itself, which aborted the whole obtain. maintain_obtain logged skip_obtain every tick,
-- the grid froze, and a write of an id that DOES have an expressible partition was refused. The same
-- raise sat under transmute's own obtain, so a table already within the lookahead of the ceiling could
-- not be transmuted at all.
--
-- The fixtures are asymmetric on purpose: an int table with a 10000 step that runs out 17 cells into a
-- 30-step lookahead, and a smallint table with a 1000 step that runs out 12 cells into it. A check hard-
-- coded to int4 (or to either count) cannot satisfy both.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(17);

-- ======================================================================== int, via maintain_obtain
create table public.oic_int (id int primary key, payload text);
insert into public.oic_int values (2147000000, 'first');
call pgpm.transmute('public.oic_int', 'id', 10000, p_paused => false);

select is((select max(hi::numeric) from pgpm.part where parent_table = 'public.oic_int'::regclass and attached),
          2147310000::numeric,
  'LIVENESS: transmute built the int grid to 2147310000, 30 steps past the frontier cell');

insert into public.oic_int values (2147300000, 'frontier moves');
select ok(2147300000::numeric + (30 + 1) * 10000 > 2147483647,
  'LIVENESS: the 30-step lookahead from the frontier cell [2147300000, 2147310000) crosses 2^31-1');

create temporary table oic_status (tick int, status text);
do $$ declare s text; begin call pgpm.maintain_obtain('public.oic_int', s); insert into oic_status values (1, s); end $$;

select is((select status from oic_status where tick = 1), 'obtained=17',
  'int tick 1: obtain ran and built exactly the 17 cells whose upper bound int can express');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.oic_int'::regclass and attached and lo::numeric > 2147300000),
  (select array_agg(g::numeric order by g) from generate_series(2147310000, 2147470000, 10000) g),
  'int tick 1: the cells built are exactly [2147310000, 2147320000) through [2147470000, 2147480000)');
select is((select max(hi::numeric) from pgpm.part where parent_table = 'public.oic_int'::regclass and attached),
          2147480000::numeric,
  'int tick 1: the grid stops at 2147480000, the last grid bound int can express');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.oic_int'::regclass and action = 'skip_obtain'),
  'int tick 1: the ceiling is not a failure, so no skip_obtain is logged');
select is((select obtain_retry_after from pgpm.config where parent_table = 'public.oic_int'::regclass), null,
  'int tick 1: and no back-off is started');

-- Identity, not "the insert did not raise": each row must land in the very partition obtain built for it.
-- coalesce(..., false) so that a missing row or a missing partition (NULL = NULL) fails rather than passes.
insert into public.oic_int values (2147400000, 'issue repro id'), (2147479999, 'last covered id');
select ok(coalesce((select tableoid from public.oic_int where id = 2147400000)
                 = (select child_oid from pgpm.part where parent_table = 'public.oic_int'::regclass and attached and lo = '2147400000'), false),
  'int: id 2147400000 lands in the partition obtain built for [2147400000, 2147410000)');
select ok(coalesce((select tableoid from public.oic_int where id = 2147479999)
                 = (select child_oid from pgpm.part where parent_table = 'public.oic_int'::regclass and attached and lo = '2147470000'), false),
  'int: id 2147479999, the last covered value, lands in the partition for [2147470000, 2147480000)');
-- LIVENESS for the ceiling itself: the cell past 2147480000 has an upper bound int cannot express, so the
-- grid really did end there rather than obtain having stopped early for some other reason.
select throws_like($$ insert into public.oic_int values (2147480000, 'past the grid') $$,
  '%no partition of relation "oic_int" found for row%',
  'LIVENESS: id 2147480000 lies in the inexpressible cell, so the grid genuinely ran out');

do $$ declare s text; begin call pgpm.maintain_obtain('public.oic_int', s); insert into oic_status values (2, s); end $$;
select is((select status from oic_status where tick = 2), 'obtained=0',
  'int tick 2: at the ceiling a tick runs, builds nothing and does not raise');
select ok(not exists (select 1 from pgpm.log where parent_table = 'public.oic_int'::regclass and action = 'skip_obtain'),
  'int tick 2: still no skip_obtain, so the terminal ceiling does not flood the log');

-- ================================================================= smallint, via transmute's own obtain
-- The frontier is already within the lookahead of 32767 when transmute runs, so it is transmute's call to
-- obtain that meets the ceiling. It used to raise there and refuse the whole conversion.
create table public.oic_small (id smallint primary key, payload text);
insert into public.oic_small values (19500, 'first'), (20500, 'frontier');
select ok(20000::numeric + (30 + 1) * 1000 > 32767,
  'LIVENESS: the 30-step lookahead from the frontier cell [20000, 21000) crosses 2^15-1');
-- Called at top level, not under lives_ok: transmute commits, and inside pgTAP's wrapper a transmute
-- that did NOT raise would die at its first COMMIT with 2D000 instead (CLAUDE.md). The config row and the
-- grid below are the evidence it completed.
call pgpm.transmute('public.oic_small', 'id', 1000);
select ok(exists (select 1 from pgpm.config where parent_table = 'public.oic_small'::regclass),
  'smallint: transmute of a table within the lookahead of the type ceiling completes');
select is((select max(hi::numeric) from pgpm.part where parent_table = 'public.oic_small'::regclass and attached),
          32000::numeric,
  'smallint: the grid stops at 32000, the last grid bound smallint can express');
select is(
  (select array_agg(lo::numeric order by lo::numeric) from pgpm.part
    where parent_table = 'public.oic_small'::regclass and attached and lo::numeric >= 21000),
  (select array_agg(g::numeric order by g) from generate_series(21000, 31000, 1000) g),
  'smallint: the cells past the frontier are exactly [21000, 22000) through [31000, 32000)');
insert into public.oic_small values (31999, 'last covered id');
select ok(coalesce((select tableoid from public.oic_small where id = 31999)
                 = (select child_oid from pgpm.part where parent_table = 'public.oic_small'::regclass and attached and lo = '31000'), false),
  'smallint: id 31999, the last covered value, lands in the partition for [31000, 32000)');

select * from finish();
