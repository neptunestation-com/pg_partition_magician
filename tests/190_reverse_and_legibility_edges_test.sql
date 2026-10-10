-- What the reverse carries back, and what maintenance now says or stops doing (issue #710).
--
--   A. untransmute hands the table back with the PARENT's owner and comments. ALTER TABLE ... OWNER TO and
--      COMMENT ON a partitioned table do not reach its partitions, so after either the monolith still had
--      the conversion-time owner and comments, and the reverse handed those back: the role that owned the
--      managed table lost every privilege on it, and the comments went back to what they were.
--   B. _install_write_block re-enables a write block an operator disabled, and now logs it
--      (write_block_reenable) instead of doing it silently.
--   C. A cell obtain or extend_to leaves unbuilt because its name is held elsewhere is logged
--      (fail_obtain_name) instead of being found through refused writes.
--   D. _part_name labels a BC year apart from the same year AD (to_char's YYYY drops the era).
--   E. A regrain step re-ANALYZEs its change-capture delta only when it has never been analyzed, not on
--      every step while it stays empty (each ANALYZE takes SHARE UPDATE EXCLUSIVE on it).
--   F. _grid_floor adds a fixed step's offset from the anchor exactly, so a fractional-second step far from
--      the anchor stays on its lattice.
--
-- Fixtures are asymmetric and every "no longer" assertion has a LIVENESS witness that the stale or silent
-- state really was there to carry or to log: the monolith really kept the old owner and comments at the
-- reverse, the trigger really was disabled, the name really is held by something else, the old label
-- really is shared, the step really did take the lock while the delta was unanalyzed, the double product
-- really is inexact.
create extension if not exists pgtap;

select plan(40);

-- Roles are cluster-wide and the database is per-file, so they are created only when absent and never
-- dropped (see tests/72 for why a DROP ROLE here would be the worse choice).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't190_old') then create role t190_old; end if;
  if not exists (select 1 from pg_roles where rolname = 't190_new') then create role t190_new; end if;
end $$;

-- ================================= A. owner and comments on the reverse =================================
-- three columns, three fates: a comment changed since the conversion, one removed, one added
create table public.ow190 (id bigint primary key, a text, b text, c text);
alter table public.ow190 owner to t190_old;
comment on table public.ow190 is 'conversion-time table comment';
comment on column public.ow190.a is 'conversion-time a';
comment on column public.ow190.b is 'conversion-time b';
insert into public.ow190 values (1, 'x', 'y', 'z'), (2, 'x', 'y', 'z');
create temp table orig190 as select 'public.ow190'::regclass::oid as oid;
call pgpm.transmute('public.ow190', 'id', 1000, p_obtain => 1);

alter table public.ow190 owner to t190_new;
comment on table public.ow190 is 'managed table comment';
comment on column public.ow190.a is 'managed a';
comment on column public.ow190.b is null;
comment on column public.ow190.c is 'managed c';

select is((select pg_get_userbyid(relowner)::text from pg_class where oid = (select oid from orig190)), 't190_old',
  'LIVENESS: (A) the monolith still has the conversion-time owner at the reverse');
select is(obj_description((select oid from orig190), 'pg_class'), 'conversion-time table comment',
  'LIVENESS: (A) and the conversion-time table comment');
select is(array[col_description((select oid from orig190), 2), col_description((select oid from orig190), 3),
                col_description((select oid from orig190), 4)],
  array['conversion-time a', 'conversion-time b', null],
  'LIVENESS: (A) and the conversion-time column comments');
select ok(not has_table_privilege('t190_new', (select oid from orig190), 'SELECT'),
  'LIVENESS: (A) t190_new, the managed table''s owner, has no privilege on the monolith');

select is(pgpm.untransmute('public.ow190')::text, 'ow190', 'A: untransmute returns the restored table');
select is((select oid from pg_class where oid = 'public.ow190'::regclass), (select oid from orig190),
  'A: the restored table is the original relation');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.ow190'::regclass), 't190_new',
  'A: the restored table is owned by the role that owned the managed table');
select ok(has_table_privilege('t190_new', 'public.ow190', 'SELECT,INSERT,UPDATE,DELETE'),
  'A: and that role can read and write it');
select ok(not has_table_privilege('t190_old', 'public.ow190', 'SELECT'),
  'A: and the conversion-time owner cannot');
select is(obj_description('public.ow190'::regclass, 'pg_class'), 'managed table comment',
  'A: the restored table carries the managed table''s comment');
select is(array[col_description('public.ow190'::regclass, 2), col_description('public.ow190'::regclass, 3),
                col_description('public.ow190'::regclass, 4)],
  array['managed a', null, 'managed c'],
  'A: and its column comments: a changed, b removed, c added');
select is((select array_agg(id order by id) from public.ow190), array[1, 2]::bigint[],
  'A: and its rows');

-- ================================= B. a disabled write block re-enabled =================================
create table public.wb190 (id bigint primary key, v text);
insert into public.wb190 values (5, 'a'), (150, 'b');
call pgpm.transmute('public.wb190', 'id', 100, p_obtain => 2);
select child_name as wb_child, lo as wb_lo, hi as wb_hi from pgpm.part
 where parent_table = 'public.wb190'::regclass order by lo::numeric desc limit 1 \gset
select pgpm._install_write_block('public.wb190', :'wb_child');
select is((select tgenabled::text from pg_trigger
            where tgrelid = format('public.%I', :'wb_child')::regclass and tgname = 'pgpm_write_block'), 'A',
  'LIVENESS: (B) the block is installed ENABLE ALWAYS');
select is((select count(*) from pgpm.log where parent_table = 'public.wb190'::regclass and action = 'write_block_reenable'),
  0::bigint, 'LIVENESS: (B) installing a block logs no re-enable');

select pgpm._install_write_block('public.wb190', :'wb_child');
select is((select count(*) from pgpm.log where parent_table = 'public.wb190'::regclass and action = 'write_block_reenable'),
  0::bigint, 'B: revisiting a block that is already ENABLE ALWAYS logs nothing');

select format('alter table public.%I disable trigger pgpm_write_block', :'wb_child') \gexec
select is((select tgenabled::text from pg_trigger
            where tgrelid = format('public.%I', :'wb_child')::regclass and tgname = 'pgpm_write_block'), 'D',
  'LIVENESS: (B) an operator disabled the block');
select pgpm._install_write_block('public.wb190', :'wb_child');
select is((select tgenabled::text from pg_trigger
            where tgrelid = format('public.%I', :'wb_child')::regclass and tgname = 'pgpm_write_block'), 'A',
  'LIVENESS: (B) the next revisit re-enabled it');
select is((select array_agg(lo || '|' || hi) from pgpm.log
            where parent_table = 'public.wb190'::regclass and action = 'write_block_reenable'),
  array[:'wb_lo' || '|' || :'wb_hi'],
  'B: and logged write_block_reenable once, against that partition''s range');
select ok((select method from pgpm.log where parent_table = 'public.wb190'::regclass and action = 'write_block_reenable')
            like format('public.%I: pgpm_write_block was disabled and is ENABLE ALWAYS again%%', :'wb_child'),
  'B: naming the partition and the state it found');

-- ================================ C. a cell left unbuilt, now logged ================================
-- monolith [0, 100), forward [100, 200) [200, 300) [300, 400); a view holds the name of [400, 500)
create table public.ob190 (id bigint primary key, v text);
insert into public.ob190 values (5, 'a'), (50, 'b');
call pgpm.transmute('public.ob190', 'id', 100, p_obtain => 3);
create view public.ob190_p0000000000000000400 as select 1 as squatter;
insert into public.ob190 values (350, 'c');   -- frontier 350: obtain asks for [300, 400) .. [600, 700)

select is((select count(*) from pgpm.log where parent_table = 'public.ob190'::regclass and action = 'fail_obtain_name'),
  0::bigint, 'LIVENESS: (C) nothing logged before obtain meets the held name');
select is(pgpm.obtain('public.ob190'), 2, 'LIVENESS: (C) obtain built two cells past the held one');
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.ob190'::regclass and attached),
  array['0', '100', '200', '300', '500', '600'],
  'LIVENESS: (C) [500, 600) and [600, 700) were built, [400, 500) was not');
select throws_ok($$ insert into public.ob190 values (450, 'hole') $$, '23514', NULL,
  'LIVENESS: (C) a write into [400, 500) is refused: the hole is real');
select is((select array_agg(lo || '|' || hi) from pgpm.log
            where parent_table = 'public.ob190'::regclass and action = 'fail_obtain_name'),
  array['400|500'],
  'C: obtain logged fail_obtain_name once, for [400, 500) alone');
select ok((select method from pgpm.log where parent_table = 'public.ob190'::regclass and action = 'fail_obtain_name')
            like '%its name public.ob190_p0000000000000000400 is held by view ob190_p0000000000000000400, which is not a partition of this table%',
  'C: naming the relation that holds the name and what it is');
select is(pgpm.extend_to('public.ob190', '450'), 0, 'LIVENESS: (C) extend_to over the same cell builds nothing');
select is((select array_agg(lo || '|' || hi order by id) from pgpm.log
            where parent_table = 'public.ob190'::regclass and action = 'fail_obtain_name'),
  array['400|500', '400|500'],
  'C: and logs it too');

-- ===================================== D. a BC year's label =====================================
select is(to_char('0001-06-01 00:00:00+00 BC'::timestamptz at time zone 'UTC', 'YYYY_MM_DD'),
          to_char('0001-06-01 00:00:00+00'::timestamptz at time zone 'UTC', 'YYYY_MM_DD'),
  'LIVENESS: (D) to_char renders 1 BC and 1 AD alike');
select is(array[pgpm._part_name('d190', 'time', '1 day', '0001-06-01 00:00:00+00 BC', null, 'UTC')::text,
                pgpm._part_name('d190', 'time', '1 day', '0001-06-01 00:00:00+00', null, 'UTC')::text],
  array['d190_p0001_06_01_bc', 'd190_p0001_06_01'],
  'D: a day cell in 1 BC and the same day in 1 AD get two names, the AD one unchanged');
select is(array[pgpm._part_name('d190', 'time', '1 year', '0001-01-01 00:00:00+00 BC', null, 'UTC')::text,
                pgpm._part_name('d190', 'time', '1 year', '0001-01-01 00:00:00+00', null, 'UTC')::text,
                pgpm._part_name('d190', 'time', '1 year', '2026-01-01 00:00:00+00', null, 'UTC')::text],
  array['d190_p0001_bc', 'd190_p0001', 'd190_p2026'],
  'D: and so do the years, every AD label as it was');
select is(pgpm._part_name('d190', 'time', '1 day', '0002-12-30 00:00:00+00 BC', '0001-01-02 00:00:00+00', 'UTC')::text,
  'd190_p0002_12_30_bc_to_0001_01_02',
  'D: a coarse range across the era marks the BC end only');

-- ================================= E. the delta analyzed once per run =================================
-- monolith [0, 200) frozen once a write lands past it; a step of 10 subdivides it, one row per step
create table public.rc190 (id bigint primary key, v text);
insert into public.rc190 select i, 'r' || i from generate_series(1, 30) i;
insert into public.rc190 values (120, 'x');
call pgpm.transmute('public.rc190', 'id', 100, p_obtain => 2);
insert into public.rc190 values (250, 'y');
-- one regrain step per call, each call its own transaction: whether this backend holds SHARE UPDATE
-- EXCLUSIVE on the delta when the step returns is whether the step ANALYZEd it (nothing else in a step
-- takes that lock on the delta, and a lock is held to the end of the transaction that took it)
create function public.t190_step_analyzes() returns boolean language plpgsql as $$
declare v_delta regclass;
begin
  perform pgpm.regrain_step('public.rc190', 'rc190_p0000000000000000000_to_0000000000000000200', '10', 1);
  v_delta := to_regclass('public.rc190_pgpm_regrain_delta');
  return exists (select 1 from pg_locks l where l.pid = pg_backend_pid() and l.relation = v_delta
                   and l.mode = 'ShareUpdateExclusiveLock' and l.granted);
end $$;
select is(array[public.t190_step_analyzes(), public.t190_step_analyzes()], array[false, true],
  'LIVENESS: (E) the step after the prepare analyzes the never-analyzed delta (the probe sees that lock)');
select is((select reltuples from pg_class where oid = 'public.rc190_pgpm_regrain_delta'::regclass), 0::real,
  'LIVENESS: (E) the delta is analyzed and empty (reltuples = 0, which the old test read as unanalyzed)');
select is(array[public.t190_step_analyzes(), public.t190_step_analyzes()], array[false, false],
  'E: later steps over the empty delta do not ANALYZE it again');
select is((select count(*) from pgpm.part where parent_table = 'public.rc190'::regclass and not attached), 1::bigint,
  'LIVENESS: (E) those steps were copying (the regrain is in flight, one copy started)');

-- ================================= F. a fixed step's offset, exactly =================================
-- '1.000001 seconds' from a year-1 anchor: about 6.4e10 steps, so k * step has 17 significant digits in
-- microseconds, more than double precision carries
select ok((select (k * 1.000001)::float8::numeric <> k * 1.000001
             from (select floor(extract(epoch from ('2026-09-30 12:34:56.789012+00'::timestamptz
                                                    - '0001-01-01 00:00:00+00'::timestamptz)) / 1.000001) as k) s),
  'LIVENESS: (F) the offset k * step is not exact in double precision');
select is((select extract(epoch from (pgpm._grid_floor('time', '1.000001 seconds', '0001-01-01 00:00:00+00',
                                                      '2026-09-30 12:34:56.789012+00', 'UTC')::timestamptz
                                      - '0001-01-01 00:00:00+00'::timestamptz)) % 1.000001),
  0::numeric,
  'F: the floor lies on the step''s lattice from the anchor');
select ok((select f::timestamptz <= '2026-09-30 12:34:56.789012+00'::timestamptz
                  and pgpm._grid_next('time', '1.000001 seconds', f, 'UTC')::timestamptz > '2026-09-30 12:34:56.789012+00'::timestamptz
             from (select pgpm._grid_floor('time', '1.000001 seconds', '0001-01-01 00:00:00+00',
                                           '2026-09-30 12:34:56.789012+00', 'UTC') as f) s),
  'F: and its cell holds the value');
select is((select pgpm._grid_floor('time', '1.000001 seconds', '0001-01-01 00:00:00+00',
                                   pgpm._grid_next('time', '1.000001 seconds', f, 'UTC'), 'UTC')
             from (select pgpm._grid_floor('time', '1.000001 seconds', '0001-01-01 00:00:00+00',
                                           '2026-09-30 12:34:56.789012+00', 'UTC') as f) s),
          (select pgpm._grid_next('time', '1.000001 seconds', f, 'UTC')
             from (select pgpm._grid_floor('time', '1.000001 seconds', '0001-01-01 00:00:00+00',
                                           '2026-09-30 12:34:56.789012+00', 'UTC') as f) s),
  'F: and the next cell''s start is its own floor (no hole, no overlap)');
select is(pgpm._grid_floor('time', '1 day', '0001-01-01 00:00:00+00', '2026-09-30 12:34:56.789012+00', 'UTC'),
  pgpm._ts_text('2026-09-30 00:00:00+00'),
  'F: a whole-second step floors where it always did');

select * from finish();
