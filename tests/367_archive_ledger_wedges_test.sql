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
--           archive_coverage_reset, and the partition archives from its own lo. A row that covers something, and a
--           retired row, stay.
--   PART B  a row under a tracked name whose partition records another oid is discarded by the archive step, those
--           rows only, logged archive_coverage_reset naming the oid, and both swapped partitions archive from their
--           own lo; a row under a tracked name with the partition's own oid stays.
--   PART C  status().archive_skips counts skip_archive rows since the parent's last recorded chunk: it climbs while a
--           strategy fails every tick and is 0 again once a chunk is recorded. method keeps the whole reason.
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

select plan(27);

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
select pgpm_t367.mk('ac367b', array[11, 12, 13, 14, 15]);
select pgpm_t367.mk('ac367c', array[21, 22]);
call pgpm.transmute('public.ac367a', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.ac367b', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
call pgpm.transmute('public.ac367c', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
insert into public.ac367a values (20000, 'frontier');
insert into public.ac367b values (20000, 'frontier');
insert into public.ac367c values (20000, 'frontier');
select child_name as a_child, child_oid as a_oid from pgpm.part where parent_table = 'public.ac367a'::regclass and lo = '0' \gset
select child_name as b_child, child_oid as b_oid from pgpm.part where parent_table = 'public.ac367b'::regclass and lo = '0' \gset
select child_name as c_child, child_oid as c_oid from pgpm.part where parent_table = 'public.ac367c'::regclass and lo = '0' \gset
select pgpm._enforce_write_blocks(p) from unnest(array['public.ac367a', 'public.ac367b', 'public.ac367c']::regclass[]) p;
select pgpm.set_archive_fn(p, 'pgpm_t367.full(regclass,name,text,text)'::regprocedure)
  from unnest(array['public.ac367a', 'public.ac367b', 'public.ac367c']::regclass[]) p;
-- what an install older than #454's check could leave: a at lo, b below it; c a real partial chunk; and a retired
-- row covering nothing, the record of a dropped relation
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid) values
  ('public.ac367a', '0', '0', :'a_child', 0, :a_oid),
  ('public.ac367b', '0', '-5', :'b_child', 0, :b_oid),
  ('public.ac367c', '0', '400', :'c_child', 0, :c_oid);
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid, retired_at) values
  ('public.ac367a', '7000', '7000', 'ac367a_gone', 0, null, now());

select is(pgpm._archive_step('public.ac367a'), 0, 'A: LIVENESS: before the upgrade, a''s first chunk is not recorded');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ac367a'::regclass and action = 'skip_archive' and lo = '0'),
  'A: LIVENESS: it is refused as skip_archive (the empty row wedges it)');

\ir :install

select is(pgpm_t367.ledger('public.ac367a'), array['ac367a_gone:7000-7000:retired'],
  'A: re-running install.sql discarded a''s row covering nothing, and kept the retired one');
select is(pgpm_t367.ledger('public.ac367b'), '{}'::text[], 'A: and b''s row below its lo');
select is(pgpm_t367.ledger('public.ac367c'), array[format('%s:0-400:live', :'c_child')], 'A: c''s partial chunk stays');
select is((select array_agg(parent_table::text || ':' || rows order by parent_table::text) from pgpm.log where action = 'archive_coverage_reset'),
  array['ac367a:1', 'ac367b:1'], 'A: logged archive_coverage_reset once for a and once for b, one chunk each');
select ok((select method from pgpm.log where parent_table = 'public.ac367a'::regclass and action = 'archive_coverage_reset') ~ :'a_child',
  'A: naming the partition');
select is(pgpm._archive_step('public.ac367a'), 1, 'A: a''s first chunk is now recorded');
select is(pgpm_t367.ledger('public.ac367a'), array[format('%s:0-1000:live', :'a_child'), 'ac367a_gone:7000-7000:retired'],
  'A: from its own lo, the whole partition');
select is((select rows_archived from pgpm.archive_ledger where parent_table = 'public.ac367a'::regclass and lo = '0'), 3::bigint,
  'A: its three rows');
select is(pgpm._archive_step('public.ac367c'), 1, 'A: c resumes from its partial chunk');
select is(pgpm_t367.ledger('public.ac367c'), array[format('%s:0-400:live', :'c_child'), format('%s:400-1000:live', :'c_child')],
  'A: c''s coverage is its kept chunk and the rest');

-- ============ PART B: two partitions' names swapped, the ledger left behind ============
create table public.ac367s (id bigint primary key, payload text);
insert into public.ac367s select g, 'p' || g from unnest(array[1, 2, 3, 4]) g;
call pgpm.transmute('public.ac367s', 'id', 1000::bigint, p_retain => 17000, p_paused => false);
insert into public.ac367s select g, 'p' || g from unnest(array[1001, 1002, 1003, 1004, 1005, 1006, 2001]) g;
insert into public.ac367s values (20000, 'frontier');
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
call pgpm.transmute('public.ac367k', 'id', 1000::bigint, p_retain => 19000, p_paused => false);
insert into public.ac367k values (20000, 'frontier');
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
select pgpm.set_archive_fn('public.ac367k', 'pgpm_t367.full(regclass,name,text,text)'::regprocedure);
select is(pgpm._archive_step('public.ac367k'), 1, 'C: LIVENESS: a corrected strategy records a chunk');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367k'::regclass), 0::bigint,
  'C: archive_skips is 0 again');
select is((select archive_skips from pgpm.status() where parent = 'public.ac367a'::regclass), 0::bigint,
  'C: a''s skip before its upgrade is older than its recorded chunk, so not counted');

select * from finish();
