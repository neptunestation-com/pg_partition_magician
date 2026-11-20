-- Archive ledger rows that wedge a partition for good are discarded, and a skip that recurs is counted (issues #1439,
-- #1440).
--
-- THE GAPS. The ledger is keyed (parent_table, lo), so a row a partition's next chunk would collide with stops that
-- partition being archived, and at archive_batch's default of 1 every partition of its parent behind it, logged
-- skip_archive on every tick, which no counter of status() moved:
--   * #1439: no release before #454 refused a strategy's covered_hi at or below the chunk's lo, so an older install
--     could hold a row covering nothing, and the partition's first chunk, starting at the same lo, collided with it
--     after the upgrade, long after the strategy was corrected;
--   * #1440: an operator who swapped two partitions' names (tables and pgpm.part rows) left the ledger rows under
--     names that are still tracked, so #511's discard by an untracked name found nothing, and each partition's
--     re-archive from its own lo collided with the other's rows.
--
-- THE CONTRACT.
--   PART A  re-running install.sql discards every unretired row that covers nothing (hi = lo, or below it), logged
--           archive_coverage_reset, and the partition archives from its own lo. A row that covers something, a
--           retired row at a lo no partition holds, and a row whose hi is not a number (an older pgpm recorded one)
--           stay, and the install goes on. A retired row covering nothing at a lo a partition holds goes too: an install
--           older than v0.6.0 has every chunk marked retired by the upgrade's oid backfill, the empty one included.
--   PART B  a row under a tracked name whose partition records another oid is discarded by the archive step, those
--           rows only, logged archive_coverage_reset naming the oid, and both swapped partitions archive from their
--           own lo; a row under a tracked name with the partition's own oid stays.
--   PART C  status().archive_skips counts skip_archive rows since the last recorded chunk: it climbs while a strategy
--           fails every tick and is 0 again once a chunk is recorded; a skip of the archive step as a whole (no lo)
--           counts since the parent's last chunk. method keeps the whole reason.
--   PART D  the count is per partition: one refused every tick while a sibling records a chunk every tick (archive_batch
--           2) still climbs.
--   PART E  and per lo: a regrain's unattached copy shares its source's lo and has no chunk, and starting a regrain
--           does not bring back a skip older than the source's chunk.
--   PART F  nor does the regrain's swap, whose fine partition at that lo has no chunk yet: a skip older than the
--           partition now at a lo was logged against an earlier relation there.
--   PART G  and a whole-step skip (lo null) the parent's chunk cleared stays cleared when the swap deletes that chunk,
--           the parent's only one (#1468): the swap's archive_coverage_reset is a reset mark too.
--
-- ONE TRANSACTION HAS ONE now(), so a skip and a chunk this file writes would share an instant and a "since the last
-- chunk" assertion would pass on the tie. Every tick that precedes another is moved back a minute before the next,
-- and a partition whose skips are counted is moved back an hour (pgpm.part.created_at), as it would be created
-- before the ticks that skip it.
--
-- install.sql is read with \ir, relative to this file; the psql variable `install` overrides the path, which
-- bench/archive_ledger_wedges.sh uses to hand it a mutant.
--
-- ASYMMETRIC FIXTURES. Part A's tables hold 3, 5 and 2 rows below 1000, part B's partitions 4, 6 and 1, part C's 9,
-- so a chunk recorded for the wrong partition or a lost row cannot stand in for the right answer.
\if :{?install}
\else
\set install ../pgpm_core/install.sql
\endif
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(47);

create schema pgpm_t367;
create table pgpm_t367.calls (parent regclass, p_child name, p_lo text, p_hi text);
-- archives the whole chunk it is handed, recording the call
create function pgpm_t367.full(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into pgpm_t367.calls values (p_parent, p_child, p_lo, p_hi);
  v.covered_hi := p_hi;
  execute format('select count(*) from %s where id >= %s and id < %s', p_parent, p_lo, p_hi) into v.rows_archived;
  return v;
end $$;
-- fails every call, with a reason longer than 200 characters whose remedy comes last
create function pgpm_t367.boom(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
begin
  insert into pgpm_t367.calls values (p_parent, p_child, p_lo, p_hi);
  raise exception 'the bucket refused the upload: %; REMEDY-AT-THE-END: rotate the credentials', repeat('x', 240);
end $$;
create function pgpm_t367.ledger(p_parent regclass) returns text[] language sql as $$
  select coalesce(array_agg(format('%s:%s-%s:%s', coalesce(child_name, '-'), lo, hi, case when retired_at is null then 'live' else 'retired' end)
                            order by lo::numeric), '{}')
    from pgpm.archive_ledger where parent_table = p_parent
$$;
create function pgpm_t367.mk(p_name text, p_ids bigint[]) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_name);
  execute format('insert into public.%I select g, ''p'' || g from unnest(%L::bigint[]) g', p_name, p_ids);
end $$;

-- ============ PART A: rows that cover nothing, left by an older install ============
select pgpm_t367.mk('ac367a', array[1, 2, 3]);
select pgpm_formal.baseline('public.ac367a');   -- the invariant oracle's row ledger (docs/formal/phase3-design.md)
select pgpm_t367.mk('ac367b', array[11, 12, 13, 14, 15]);
select pgpm_formal.baseline('public.ac367b');
select pgpm_t367.mk('ac367c', array[21, 22]);
select pgpm_formal.baseline('public.ac367c');
call pgpm.transmute('public.ac367a', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.ac367b', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.ac367c', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
insert into public.ac367a values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367a', 'id = 20000');
insert into public.ac367b values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367b', 'id = 20000');
insert into public.ac367c values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367c', 'id = 20000');
select child_name as a_child, child_oid as a_oid from pgpm.part where parent_table = 'public.ac367a'::regclass and lo = '0' \gset
select child_name as b_child, child_oid as b_oid from pgpm.part where parent_table = 'public.ac367b'::regclass and lo = '0' \gset
select child_name as c_child, child_oid as c_oid from pgpm.part where parent_table = 'public.ac367c'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks(p) from unnest(array['public.ac367a', 'public.ac367b', 'public.ac367c']::regclass[]) p;
select pgpm.set_archive_fn(p, 'pgpm_t367.full(regclass,name,text,text)'::regprocedure)
  from unnest(array['public.ac367a', 'public.ac367b', 'public.ac367c']::regclass[]) p;
select pgpm_t367.mk('ac367n', array[41]);
select pgpm_formal.baseline('public.ac367n');
call pgpm.transmute('public.ac367n', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
select child_name as n_child, child_oid as n_oid from pgpm.part where parent_table = 'public.ac367n'::regclass and lo = '0' \gset
-- a row whose hi is not a value of the column, which an older archive step recorded (reference.md, the contract check)
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('public.ac367n', '0', 'not-a-number', :'n_child', 0, :n_oid);
-- what an install older than #454's check could leave: a at lo, b below it; c a real partial chunk; and a retired
-- row covering nothing, the record of a dropped relation
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('public.ac367a', '0', '0', :'a_child', 0, :a_oid),
  ('public.ac367b', '0', '-5', :'b_child', 0, :b_oid),
  ('public.ac367c', '0', '400', :'c_child', 0, :c_oid);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid, retired_at) values
  ('public.ac367a', '-5000', '-5000', 'ac367a_gone', 0, null, now());
-- an install older than v0.6.0, upgraded: its oid backfill marked the empty row retired (no oid, an adopted anchor)
select pgpm_t367.mk('ac367r', array[71, 72, 73, 74]);
select pgpm_formal.baseline('public.ac367r');
call pgpm.transmute('public.ac367r', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
insert into public.ac367r values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367r', 'id = 20000');
select child_name as r_child from pgpm.part where parent_table = 'public.ac367r'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks('public.ac367r');
select pgpm.set_archive_fn('public.ac367r', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid, retired_at) values
  ('public.ac367r', '0', '0', :'r_child', 0, null, now());
-- a time grid's retired chunk covering years, its hi written as digits, at the lo its partition holds
create table public.ac367t (id bigint, ts timestamptz not null);
insert into public.ac367t select g, '2026-01-01 00:00:00+00'::timestamptz + (g || ' hours')::interval from generate_series(1, 6) g;
select pgpm_formal.baseline('public.ac367t');
call pgpm.transmute('public.ac367t', 'ts', '1 month'::interval, p_retain => '5 years'::interval, p_paused => false);
select lo as t_lo from pgpm.part where parent_table = 'public.ac367t'::regclass and attached order by lo::timestamptz limit 1 \gset
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, rows_archived, child_oid, retired_at) values
  ('public.ac367t', :'t_lo', '20300101', 'ac367t_gone', 'the-only-copy', 20, null, now());

select is(pgpm._archive_step('public.ac367a'), 0, 'A: LIVENESS: before the upgrade, a''s first chunk is not recorded');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ac367a'::regclass and action = 'skip_archive' and lo = '0'),
  'A: LIVENESS: it is refused as skip_archive (the empty row wedges it)');
update pgpm.log set at = at - interval '1 minute' where parent_table = 'public.ac367a'::regclass and action = 'skip_archive';

\ir :install

select is(pgpm_t367.ledger('public.ac367a'), array['ac367a_gone:-5000--5000:retired'],
  'A: re-running install.sql discarded a''s row covering nothing, and kept the retired one no partition holds');
select is(pgpm_t367.ledger('public.ac367r'), '{}'::text[],
  'A: and the retired row covering nothing at the lo a partition holds, which an older install''s upgrade marked');
select is(pgpm_t367.ledger('public.ac367b'), '{}'::text[], 'A: and b''s row below its lo');
select is((select count(*) from pgpm.archive_ledger where parent_table = 'public.ac367t'::regclass and s3_key = 'the-only-copy'),
  1::bigint, 'A: a time grid''s retired chunk whose hi is written as digits is not read as empty, and stays');
select is(pgpm_t367.ledger('public.ac367n'), array[format('%s:0-not-a-number:live', :'n_child')],
  'A: a row whose hi is not a number is compared as written and kept, and the install went on');
delete from pgpm.archive_ledger where parent_table = 'public.ac367n'::regclass;
select is(pgpm_t367.ledger('public.ac367c'), array[format('%s:0-400:live', :'c_child')], 'A: c''s partial chunk stays');
select is((select array_agg(parent_table::text || ':' || rows order by parent_table::text) from pgpm.log where action = 'archive_coverage_reset'),
  array['ac367a:1', 'ac367b:1', 'ac367r:1'], 'A: logged archive_coverage_reset once for a, b and r, one chunk each');
select ok((select method from pgpm.log where parent_table = 'public.ac367a'::regclass and action = 'archive_coverage_reset') ~ :'a_child',
  'A: naming the partition');
select is(pgpm._archive_step('public.ac367a'), 1, 'A: a''s first chunk is now recorded');
select is(pgpm_t367.ledger('public.ac367a'), array['ac367a_gone:-5000--5000:retired', format('%s:0-1000:live', :'a_child')],
  'A: from its own lo, the whole partition');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 'public.ac367a'::regclass and lo = '0'), 3::bigint,
  'A: its three rows');
select is(pgpm._archive_step('public.ac367r'), 1, 'A: r''s first chunk is now recorded, the wedge gone');
select is(pgpm._archive_step('public.ac367c'), 1, 'A: c resumes from its partial chunk');
select is(pgpm_t367.ledger('public.ac367c'), array[format('%s:0-400:live', :'c_child'), format('%s:400-1000:live', :'c_child')],
  'A: c''s coverage is its kept chunk and the rest');

-- ============ PART B: two partitions' names swapped, the ledger left behind ============
create table public.ac367s (id bigint primary key, payload text);
insert into public.ac367s select g, 'p' || g from unnest(array[1, 2, 3, 4]) g;
select pgpm_formal.baseline('public.ac367s');
call pgpm.transmute('public.ac367s', 'id', 1000::bigint, p_retain => 17000, p_paused => false);
insert into public.ac367s select g, 'p' || g from unnest(array[1001, 1002, 1003, 1004, 1005, 1006, 2001]) g;
select pgpm_formal.wrote('public.ac367s', 'id between 1001 and 2001');
insert into public.ac367s values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367s', 'id = 20000');
select child_name as s0, child_oid as s0_oid from pgpm.part where parent_table = 'public.ac367s'::regclass and lo = '0' \gset
select child_name as s1, child_oid as s1_oid from pgpm.part where parent_table = 'public.ac367s'::regclass and lo = '1000' \gset
select child_name as s2, child_oid as s2_oid from pgpm.part where parent_table = 'public.ac367s'::regclass and lo = '2000' \gset
update pgpm.config set archive_batch = 3 where parent_table = 'public.ac367s'::regclass;
select pgpm._enforce_write_blocks('public.ac367s');
select pgpm.set_archive_fn('public.ac367s', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
-- each partition partly archived, as its own relation
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('public.ac367s', '0', '500', :'s0', 4, :s0_oid),
  ('public.ac367s', '1000', '1500', :'s1', 6, :s1_oid),
  ('public.ac367s', '2000', '2500', :'s2', 1, :s2_oid);
-- the operator swaps the first two partitions' names, tables and pgpm.part rows both, and leaves the ledger
alter table public.:"s0" rename to ac367s_swap;
alter table public.:"s1" rename to :"s0";
alter table public.ac367s_swap rename to :"s1";
update pgpm.part set child_name = 'ac367s_swap' where parent_table = 'public.ac367s'::regclass and lo = '0';
update pgpm.part set child_name = :'s0' where parent_table = 'public.ac367s'::regclass and lo = '1000';
update pgpm.part set child_name = :'s1' where parent_table = 'public.ac367s'::regclass and lo = '0';
select ok((select child_oid = :s0_oid from pgpm.part where parent_table = 'public.ac367s'::regclass and child_name = :'s1')
          and (select child_oid = :s1_oid from pgpm.part where parent_table = 'public.ac367s'::regclass and child_name = :'s0'),
  'B: LIVENESS: both names are tracked, each now by the other''s relation');
delete from pgpm_t367.calls;

select is(pgpm._archive_step('public.ac367s'), 3, 'B: one tick records a chunk of each of the three partitions');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ac367s'::regclass and action = 'skip_archive'), 0,
  'B: and refuses none');
select is((select array_agg(rows order by lo::numeric) from pgpm.log
            where parent_table = 'public.ac367s'::regclass and action = 'archive_coverage_reset'),
  array[1::bigint, 1], 'B: two discards, one chunk each');
select ok((select bool_and(method ~ ('as relation oid (' || :s0_oid || '|' || :s1_oid || ')')) from pgpm.log
            where parent_table = 'public.ac367s'::regclass and action = 'archive_coverage_reset'),
  'B: each names the relation oid its chunks were read from');
select is(pgpm_t367.ledger('public.ac367s'),
  array[format('%s:0-1000:live', :'s1'), format('%s:1000-2000:live', :'s0'), format('%s:2000-2500:live', :'s2'),
        format('%s:2500-3000:live', :'s2')],
  'B: the swapped partitions archived from their own lo under their new names; the third kept its chunk and resumed');
select is((select array_agg(child_oid order by lo::numeric) from pgpm.archive_ledger where parent_table = 'public.ac367s'::regclass),
  array[:s0_oid, :s1_oid, :s2_oid, :s2_oid]::oid[], 'B: every chunk records the relation it was read from');
select is((select array_agg(rows_archived order by lo::numeric) from pgpm.archive_ledger where parent_table = 'public.ac367s'::regclass),
  array[4, 6, 1, 0]::bigint[], 'B: four, six and one rows, the third''s rest empty');

-- ============ PART C: a skip that recurs is counted ============
create table public.ac367k (id bigint primary key, payload text);
insert into public.ac367k select g, 'p' || g from generate_series(31, 39) g;
select pgpm_formal.baseline('public.ac367k');
call pgpm.transmute('public.ac367k', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
update pgpm.part set created_at = created_at - interval '1 hour' where parent_table = 'public.ac367k'::regclass;
insert into public.ac367k values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367k', 'id = 20000');
select pgpm._enforce_write_blocks('public.ac367k');
select pgpm.set_archive_fn('public.ac367k', 'pgpm_t367.boom(regclass,name,text,text)'::regprocedure);
select is((select archive_skips from pgpm.status() where parent = 'public.ac367k'::regclass), 0::bigint, 'C: no skip yet');
select pgpm._archive_step('public.ac367k');
select pgpm._archive_step('public.ac367k');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367k'::regclass), 2::bigint,
  'C: two failing ticks, archive_skips 2');
select is((select retain_drop_failures from pgpm.status() where parent = 'public.ac367k'::regclass), 0::bigint,
  'C: retain_drop_failures keeps its meaning');
select ok((select bool_and(method ~ 'REMEDY-AT-THE-END: rotate the credentials$') from pgpm.log
            where parent_table = 'public.ac367k'::regclass and action = 'skip_archive'),
  'C: method keeps the whole reason, remedy included');
update pgpm.log set at = at - interval '1 minute' where parent_table = 'public.ac367k'::regclass and action = 'skip_archive';
select pgpm.set_archive_fn('public.ac367k', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
select is(pgpm._archive_step('public.ac367k'), 1, 'C: LIVENESS: a corrected strategy records a chunk');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367k'::regclass), 0::bigint,
  'C: archive_skips is 0 again');
-- maintain()'s skip_archive for the archive step as a whole, as its handler writes it: no lo
update pgpm.archive_ledger set archived_at = archived_at - interval '1 minute' where parent_table = 'public.ac367k'::regclass;
insert into pgpm.log (parent_table, action, method)
  select 'public.ac367k', 'skip_archive', 'the archive step failed: ' || g from generate_series(1, 3) g;
select is((select archive_skips from pgpm.status() where parent = 'public.ac367k'::regclass), 3::bigint,
  'C: three skips of the archive step as a whole since the parent''s last chunk count 3');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367a'::regclass), 0::bigint,
  'C: a''s skip before its upgrade is older than its recorded chunk, so not counted');

-- ============ PART D: one partition refused every tick while a sibling records chunks ============
-- refuses the first partition's chunks; archives a sibling's 100 ids at a time, so it has a chunk left every tick
create function pgpm_t367.sibling(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result;
begin
  insert into pgpm_t367.calls values (p_parent, p_child, p_lo, p_hi);
  if p_lo::numeric < 1000 then
    raise exception 'the bucket refused the upload of %', p_child;
  end if;
  v.covered_hi := least(p_lo::numeric + 100, p_hi::numeric)::text;
  execute format('select count(*) from %s where id >= %s and id < %s', p_parent, p_lo, v.covered_hi) into v.rows_archived;
  return v;
end $$;
create table public.ac367d (id bigint primary key, payload text);
insert into public.ac367d select g, 'p' || g from unnest(array[51, 52, 53, 54, 55, 56, 57]) g;
select pgpm_formal.baseline('public.ac367d');
call pgpm.transmute('public.ac367d', 'id', 1000::bigint, p_retain => 17000, p_paused => false);
update pgpm.part set created_at = created_at - interval '1 hour' where parent_table = 'public.ac367d'::regclass;
insert into public.ac367d select g, 'p' || g from unnest(array[1001, 1102, 1203]) g;
select pgpm_formal.wrote('public.ac367d', 'id in (1001, 1102, 1203)');
insert into public.ac367d values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367d', 'id = 20000');
select child_name as d1 from pgpm.part where parent_table = 'public.ac367d'::regclass and lo = '1000' \gset
update pgpm.config set archive_batch = 2 where parent_table = 'public.ac367d'::regclass;
select pgpm._enforce_write_blocks('public.ac367d');
select pgpm.set_archive_fn('public.ac367d', 'pgpm_t367.sibling(regclass,name,text,text)'::regprocedure);
-- three ticks, each moved back a minute before the next
do $$
begin
  for i in 1 .. 3 loop
    perform pgpm._archive_step('public.ac367d');
    update pgpm.log set at = at - interval '1 minute' where parent_table = 'public.ac367d'::regclass;
    update pgpm.archive_ledger set archived_at = archived_at - interval '1 minute' where parent_table = 'public.ac367d'::regclass;
  end loop;
end $$;
select is((select count(*) from pgpm.log where parent_table = 'public.ac367d'::regclass and action = 'skip_archive' and lo = '0'),
  3::bigint, 'D: LIVENESS: the first partition was refused on every tick');
select is((select array_agg(lo order by lo::numeric) from pgpm.archive_ledger
            where parent_table = 'public.ac367d'::regclass and child_name = :'d1'),
  array['1000', '1100', '1200'], 'D: LIVENESS: the sibling recorded a chunk on every tick, and has chunks left');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367d'::regclass), 3::bigint,
  'D: archive_skips counts the refused partition''s three skips, whatever its sibling records');

-- ============ PART E: a regrain's copy at the same lo ============
create table public.ac367e (id bigint primary key, payload text);
insert into public.ac367e select g, 'p' || g from generate_series(61, 1661) g;
select pgpm_formal.baseline('public.ac367e');
call pgpm.transmute('public.ac367e', 'id', 1000::bigint, p_retain => 15000, p_paused => false);
update pgpm.part set created_at = created_at - interval '3 hours' where parent_table = 'public.ac367e'::regclass;
insert into public.ac367e values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367e', 'id = 20000');
select child_name as e0 from pgpm.part where parent_table = 'public.ac367e'::regclass and lo = '0' and attached \gset
select pgpm._enforce_write_blocks('public.ac367e');
select pgpm.set_archive_fn('public.ac367e', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
-- one transient skip of the partition, ticks ago
insert into pgpm.log (parent_table, action, lo, hi, method, at)
  values ('public.ac367e', 'skip_archive', '0', '1000', 'a lock race, long cleared', now() - interval '2 hours');
select is(pgpm._archive_step('public.ac367e'), 1, 'E: LIVENESS: the partition then recorded its chunk');
-- a regrain begins: its first copy sub-range is minted unattached at the source's own lo
select pgpm.regrain_step('public.ac367e', :'e0', '500', 100);
select pgpm.regrain_step('public.ac367e', :'e0', '500', 100);
select is((select count(*) from pgpm.part where parent_table = 'public.ac367e'::regclass and lo = '0' and not attached),
  1::bigint, 'E: LIVENESS: an unattached copy now shares lo 0 with its source');
select is((select count(*) from pgpm.log where parent_table = 'public.ac367e'::regclass and action = 'skip_archive'), 1::bigint,
  'E: LIVENESS: still the one skip, older than the chunk');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367e'::regclass), 0::bigint,
  'E: archive_skips stays 0: nothing was refused since the chunk at that lo');

-- ============ PART F: the regrain's swap ============
create table public.ac367f (id bigint primary key, payload text);
insert into public.ac367f select g, 'p' || g from generate_series(81, 1681) g;
select pgpm_formal.baseline('public.ac367f');
call pgpm.transmute('public.ac367f', 'id', 1000::bigint, p_retain => 15000, p_paused => false);
update pgpm.part set created_at = created_at - interval '3 hours' where parent_table = 'public.ac367f'::regclass;
insert into public.ac367f values (20000, 'frontier');
select pgpm_formal.wrote('public.ac367f', 'id = 20000');
select pgpm._enforce_write_blocks('public.ac367f');
select pgpm.set_archive_fn('public.ac367f', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
-- one transient skip of the source, ticks ago, then its chunk
insert into pgpm.log (parent_table, action, lo, hi, method, at)
  values ('public.ac367f', 'skip_archive', '0', '1000', 'a lock race, long cleared', now() - interval '2 hours');
select pgpm._archive_step('public.ac367f');
-- the regrain runs to its swap
do $$
declare r text; n int := 0;
begin
  loop
    r := pgpm.regrain_step('public.ac367f', (select child_name from pgpm.part where parent_table = 'public.ac367f'::regclass
                                              and lo = '0' and attached limit 1), '500', 100);
    n := n + 1;
    exit when r like 'swapped%' or n > 80;
  end loop;
end $$;
select is((select array_agg(lo order by lo::numeric) from pgpm.part where parent_table = 'public.ac367f'::regclass
            and lo::numeric < 1000 and attached),
  array['0', '500'], 'F: LIVENESS: the swap happened, two fine partitions where the source was');
select is((select count(*) from pgpm.archive_ledger where parent_table = 'public.ac367f'::regclass and lo = '0'), 0::bigint,
  'F: LIVENESS: no chunk marks lo 0 now (the source''s went with it, the fine partition has none yet)');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367f'::regclass), 0::bigint,
  'F: archive_skips is 0: the one skip was logged against the source, before the fine partition existed');

-- ============ PART G: the swap deletes the parent's only chunk (#1468) ============
create table public.ac367g (id bigint primary key, payload text);
insert into public.ac367g select g, 'p' || g from generate_series(81, 881) g;
select pgpm_formal.baseline('public.ac367g');
call pgpm.transmute('public.ac367g', 'id', 1000::bigint, p_retain => 15000, p_paused => false);
update pgpm.part set created_at = created_at - interval '3 hours' where parent_table = 'public.ac367g'::regclass;
insert into public.ac367g values (16000, 'frontier');
select pgpm_formal.wrote('public.ac367g', 'id = 16000');
select pgpm._enforce_write_blocks('public.ac367g');
select pgpm.set_archive_fn('public.ac367g', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
-- one transient whole-step skip, hours ago, then the chunk that cleared it
insert into pgpm.log (parent_table, action, lo, hi, method, at)
  values ('public.ac367g', 'skip_archive', null, null, 'credentials expired, long since renewed', now() - interval '2 hours');
select pgpm._archive_step('public.ac367g');
select is((select array_agg(lo) from pgpm.archive_ledger where parent_table = 'public.ac367g'::regclass),
  array['0'], 'G: LIVENESS: the parent''s one chunk is at lo 0, the partition the regrain will replace');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367g'::regclass), 0::bigint,
  'G: LIVENESS: the chunk cleared the whole-step skip');
do $$
declare r text; n int := 0;
begin
  loop
    r := pgpm.regrain_step('public.ac367g', (select child_name from pgpm.part where parent_table = 'public.ac367g'::regclass
                                              and lo = '0' and attached limit 1), '500', 100);
    n := n + 1;
    exit when r like 'swapped%' or n > 80;
  end loop;
end $$;
select is((select count(*) from pgpm.archive_ledger where parent_table = 'public.ac367g'::regclass), 0::bigint,
  'G: LIVENESS: the swap left the parent no chunk at all');
select is((select count(*) from pgpm.log where parent_table = 'public.ac367g'::regclass and action = 'archive_coverage_reset'),
  1::bigint, 'G: LIVENESS: and logged the one archive_coverage_reset that says so');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367g'::regclass), 0::bigint,
  'G: archive_skips stays 0: the cleared whole-step skip does not come back when the chunk that cleared it goes');

select * from finish();
