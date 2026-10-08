-- A cell whose own label makes its PLAIN name too long is a hole, not the end of the call (issue #1072).
--
-- An id label is zero-padded to 19 digits and never cut, so on a numeric key it widens to 20 digits at
-- 10^19 (#582), and a table name that fits every 19-digit cell (up to 42 bytes) does not fit the cells
-- past that edge. #510 makes _part_name REFUSE such a name rather than truncate it. #663 caught that
-- refusal in _obtain_name for the explicit-range stand-in only; the plain name's refusal escaped, and
-- obtain and extend_to are single functions, so the first unnameable cell unwound every cell the call
-- would have built: maintain_obtain logged skip_obtain on every tick, the nameable cell [9.9e18, 10^19)
-- below the edge was never built, and every write into it was refused.
--
-- The contract (docs/reference.md, Partition naming): that cell is left unbuilt, never under a cut name,
-- logged fail_obtain_name for its range with the refusal in `method`, and the cells that fit are built, by
-- the maintenance tick (A) and by extend_to (B) alike. The catch is for a cell whose label is wider than
-- the grid's own (C): a table whose name leaves no room even for the grid's ordinary 19-digit label
-- (renamed after transmute, which refuses one up front) is still refused, loudly, as #510 and tests/161
-- part (c) have it.
--
-- Fixtures are asymmetric: A's tick builds one cell and leaves three unbuilt, B's extend_to builds one and
-- leaves one. Every negative (no skip_obtain, no cut name) is paired with a witness that the walk really
-- reached a cell past 10^19. bench/obtain_plain_name_too_long.sh runs this file against
-- obtain_plain_name_uncaught (the plain name's refusal escapes again) and obtain_plain_name_caught_always
-- (the over-correction, which swallows C's refusal too), and is required to FAIL against each.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(20);

\set A g293_obtain_plain_name_too_long_aaaaaaaaaa
\set B g293_extend_plain_name_too_long_bbbbbbbbbb

select is(octet_length(:'A') * 10 + octet_length(:'B'), 462, 'LIVENESS: both table names are 42 bytes');
select is(octet_length(pgpm._part_name(:'A', 'id', '100000000000000000', '9900000000000000000', null, 'UTC')), 63,
  'LIVENESS: the cell [9.9e18, 10^19) has a legal 63-byte name');
select throws_like(
  format($$ select pgpm._part_name(%L, 'id', '100000000000000000', '10000000000000000000', null, 'UTC') $$, :'A'),
  'pg_partition_magician: cannot name a partition of %_p10000000000000000000 is 64 bytes%',
  'LIVENESS: and the cell [10^19, 1.01e19) has a 20-digit label, whose name _part_name refuses at 64 bytes');

-- ==================== (A) the maintenance tick ====================
create table public.:A (id numeric primary key, payload text);
insert into public.:A values (9700000000000000001, 'x');
call pgpm.transmute(format('public.%I', :'A'), 'id', 100000000000000000::bigint, p_obtain => 1, p_paused => false);
select is(
  (select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = format('public.%I', :'A')::regclass),
  array['9700000000000000000', '9800000000000000000'],
  'LIVENESS: the conversion built the monolith and one cell, so [9.9e18, 10^19) is still to build');

select pgpm.set_obtain(format('public.%I', :'A')::regclass, 5);
call pgpm.maintain_obtain(format('public.%I', :'A')::regclass, null) \gset
select is(:'p_status'::text, 'obtained=1', 'the obtain tick built one cell: ' || :'p_status');
select is((select count(*)::int from pgpm.log where parent_table = format('public.%I', :'A')::regclass and action = 'skip_obtain'), 0,
  'and logged no skip_obtain');
select is(
  (select array_agg(lo order by lo::numeric) from pgpm.part
    where parent_table = format('public.%I', :'A')::regclass and attached),
  array['9700000000000000000', '9800000000000000000', '9900000000000000000'],
  'the nameable cell [9.9e18, 10^19) is built, and nothing past the edge is');
select is(
  (select array_agg(lo || '-' || hi order by id) from pgpm.log
    where parent_table = format('public.%I', :'A')::regclass and action = 'fail_obtain_name'),
  array['10000000000000000000-10100000000000000000', '10100000000000000000-10200000000000000000',
        '10200000000000000000-10300000000000000000'],
  'LIVENESS: the tick reached the three cells past 10^19 and logged fail_obtain_name once for each');
select is(
  (select method from pgpm.log where parent_table = format('public.%I', :'A')::regclass
      and action = 'fail_obtain_name' and lo = '10000000000000000000'),
  format('left unbuilt, so writes into it are refused: its name %s_p10000000000000000000 is 64 bytes, over'
         ' PostgreSQL''s 63-byte identifier limit, and pgpm never truncates a partition name (obtain and regrain'
         ' decide whether a partition already exists by name, so truncated names collide and the forward grid'
         ' silently stops growing). Shorten the table name by at least 1 byte(s), or use a coarser step, whose'
         ' labels are shorter.', :'A'),
  'fail_obtain_name''s method names the cell''s over-long name and the bytes to shorten the table name by');
select is(to_regclass(format('public.%I', :'A' || '_p1000000000000000000')), null,
  'no relation carries the 20-digit name cut to 63 bytes');
select lives_ok(format($$ insert into public.%I values (9950000000000000000, 'y') $$, :'A'),
  'a write into [9.9e18, 10^19) lands');
select throws_ok(format($$ insert into public.%I values (10050000000000000000, 'z') $$, :'A'), '23514', NULL,
  'LIVENESS: and a write past 10^19 is refused, the hole fail_obtain_name reported');

-- ==================== (B) extend_to ====================
create table public.:B (id numeric primary key, payload text);
insert into public.:B values (9850000000000000000, 'x');
call pgpm.transmute(format('public.%I', :'B'), 'id', 100000000000000000::bigint, p_obtain => 0, p_paused => false);
select is(
  (select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = format('public.%I', :'B')::regclass),
  array['9800000000000000000'],
  'LIVENESS: B''s conversion built the monolith [9.8e18, 9.9e18) alone');
-- a raise is caught and returned as its message, so the parts after this one still run against a builder
-- that lets the refusal escape
create function pg_temp.extend_to_or_error(p_parent regclass, p_value text) returns text language plpgsql as $$
begin
  return pgpm.extend_to(p_parent, p_value)::text;
exception when others then
  return sqlerrm;
end $$;
select is(pg_temp.extend_to_or_error(format('public.%I', :'B')::regclass, '10050000000000000000'), '1',
  'extend_to to a value past 10^19 builds the one cell whose name fits, and returns');
select is(
  (select array_agg(lo order by lo::numeric) from pgpm.part
    where parent_table = format('public.%I', :'B')::regclass and attached),
  array['9800000000000000000', '9900000000000000000'],
  'the cell it built is [9.9e18, 10^19)');
select is(
  (select array_agg(lo || '-' || hi order by id) from pgpm.log
    where parent_table = format('public.%I', :'B')::regclass and action = 'fail_obtain_name'),
  array['10000000000000000000-10100000000000000000'],
  'LIVENESS: extend_to reached [10^19, 1.01e19) and logged fail_obtain_name for it alone');
select lives_ok(format($$ insert into public.%I values (9990000000000000000, 'y') $$, :'B'),
  'a write into the cell extend_to built lands');

-- ==================== (C) a table whose name fits no cell of its grid is still refused ====================
-- 45 bytes: even a 19-digit label makes 66, so this is the table name, not one cell's label.
alter table public.:A rename to g293_obtain_plain_name_too_long_aaaaaaaaaaaaa;
select is(octet_length('g293_obtain_plain_name_too_long_aaaaaaaaaaaaa'), 45, 'LIVENESS: a 45-byte table name');
select throws_like(
  $$ select pgpm._part_name('g293_obtain_plain_name_too_long_aaaaaaaaaaaaa', 'id', '100000000000000000', '0', null, 'UTC') $$,
  'pg_partition_magician: cannot name a partition of % is 66 bytes%',
  'LIVENESS: its ordinary 19-digit cell name is 66 bytes, which _part_name refuses');
select throws_like(
  $$ select pgpm.obtain('public.g293_obtain_plain_name_too_long_aaaaaaaaaaaaa') $$,
  'pg_partition_magician: cannot name a partition of g293_obtain_plain_name_too_long_aaaaaaaaaaaaa -- g293_obtain_plain_name_too_long_aaaaaaaaaaaaa_p10000000000000000000 is 67 bytes%',
  'obtain still refuses such a table, naming the first cell it could not name');

select * from finish();
