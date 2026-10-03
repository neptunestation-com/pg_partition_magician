-- One partition's archive raise defers that partition alone (issue #833).
--
-- THE BUG. _archive_step's per-candidate loop had no exception block of its own. A strategy that cannot
-- make progress is told to RAISE (docs/reference.md: maintain() logs skip_archive and hands it the same
-- chunk next tick), but the raise unwound the whole step into maintain()'s one handler, so with
-- archive_batch > 1 every other partition archived in the same call lost its ledger row after the strategy
-- had already run for it (a transport strategy had uploaded the chunk, and uploaded it again next tick),
-- and while one partition kept failing no partition of the parent recorded coverage or retired.
--
-- THE CONTRACT. The archive step isolates each candidate the way _enforce_write_blocks does:
--   PART A  with archive_batch 3 and the strategy raising for the MIDDLE candidate only, the partitions
--           before and after it record exactly their own chunks and retire in the same tick, the one that
--           raised is logged skip_archive over its own [lo, hi), keeps no ledger row and stays attached.
--   PART B  once the strategy recovers, the next tick archives the deferred partition from the chunk it was
--           handed, and the two already covered are never handed to the strategy again (no re-upload).
--
-- ASYMMETRIC FIXTURE. Three aged partitions holding different row counts (A [0, 10) ids 1, 2; B [10, 20)
-- id 15; C [20, 30) ids 21, 22, 23), so a ledger row written for the wrong partition, or a count that a
-- lost row and a duplicated one cancel, cannot stand in for the right answer. Two non-transactional
-- sequences count the strategy's calls for A and for C, so "the strategy ran" survives any rollback.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(15);

create table public.ab228 (id bigint primary key, payload text);
insert into public.ab228 values (1, 'a1'), (2, 'a2');
call pgpm.transmute('public.ab228', 'id', 10::bigint, p_obtain => 6, p_retain => 30::bigint);
insert into public.ab228 values (15, 'b'), (21, 'c1'), (22, 'c2'), (23, 'c3'), (65, 'frontier');

select child_name as a_child from pgpm.part where parent_table = 'public.ab228'::regclass and lo = '0' \gset
select child_name as b_child from pgpm.part where parent_table = 'public.ab228'::regclass and lo = '10' \gset
select child_name as c_child from pgpm.part where parent_table = 'public.ab228'::regclass and lo = '20' \gset

create table public.ab228_fail (lo text primary key);
insert into public.ab228_fail values ('10');
create sequence public.ab228_calls_a;
create sequence public.ab228_calls_c;
create function public.ab228_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare r pgpm.archive_result; v_rows bigint;
begin
  if exists (select 1 from public.ab228_fail f where f.lo = p_lo) then
    raise exception 'object store unreachable for %', p_child;   -- the documented deferral path
  end if;
  if p_lo = '0' then perform nextval('public.ab228_calls_a'); end if;
  if p_lo = '20' then perform nextval('public.ab228_calls_c'); end if;
  execute format('select count(*) from public.%I', p_child) into v_rows;
  r.covered_hi := p_hi; r.rows_archived := v_rows;
  return r;
end;
$$;
select pgpm.set_archive_fn('public.ab228', 'public.ab228_strategy(regclass,name,text,text)');
update pgpm.config set archive_batch = 3 where parent_table = 'public.ab228'::regclass;
select pgpm.resume('public.ab228');

-- ==================== (A) the middle candidate raises; its neighbours are recorded ====================
select is((select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.ab228'::regclass), '30',
  'LIVENESS: the horizon is 30, so A [0, 10), B [10, 20) and C [20, 30) are all aged');

call pgpm.maintain('public.ab228');

select ok((select is_called from public.ab228_calls_a),
  'LIVENESS: the strategy ran for A, the first candidate, in the tick');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ab228'::regclass and action = 'skip_archive'
                   and method = format('object store unreachable for %s', :'b_child')),
  'LIVENESS: B''s strategy call raised, and the raise was caught and logged');

select ok((select is_called from public.ab228_calls_c),
  'the step went on past B''s raise: the strategy was handed C''s chunk in the same tick');
select is((select array_agg(child_name || ' ' || lo || '-' || hi || ' ' || rows_archived order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 'public.ab228'::regclass),
  array[:'a_child' || ' 0-10 2', :'c_child' || ' 20-30 3'],
  'A''s and C''s chunks, which the strategy archived, are recorded, each under its own partition with its own row count');
select is((select array_agg(lo || '-' || hi || ' ' || method order by id) from pgpm.log
            where parent_table = 'public.ab228'::regclass and action = 'skip_archive'),
  array['10-20 ' || format('object store unreachable for %s', :'b_child')],
  'the deferral is logged once, as skip_archive over the partition that raised, with the strategy''s own message');
select is((select array_agg(lo order by lo::numeric) from pgpm.log
            where parent_table = 'public.ab228'::regclass and action = 'retain_drop'),
  array['0', '20'],
  'A and C, covered, retired in the same tick');
select ok(to_regclass(format('public.%I', :'b_child')) is not null
          and (select attached from pgpm.part where parent_table = 'public.ab228'::regclass and child_name = :'b_child'),
  'LIVENESS: B is still an attached partition');
select is((select count(*)::int from pgpm.archive_ledger where parent_table = 'public.ab228'::regclass and child_name = :'b_child'),
  0, 'B, whose strategy call raised, recorded no coverage (fail-closed)');
select is((select array_agg(id order by id) from public.ab228 where id < 30), array[15]::bigint[],
  'B''s row is still readable through the parent, and A''s and C''s left with their partitions');

-- ==================== (B) the strategy recovers: B is archived, A and C are not handed again ===========
delete from public.ab228_fail;
call pgpm.maintain('public.ab228');

select is((select array_agg(child_name || ' ' || lo || '-' || hi order by lo::numeric)
             from pgpm.archive_ledger where parent_table = 'public.ab228'::regclass),
  array[:'a_child' || ' 0-10', :'b_child' || ' 10-20', :'c_child' || ' 20-30'],
  'the next tick recorded B''s chunk, from the lo it was deferred at');
select is((select array_agg(lo order by lo::numeric) from pgpm.log
            where parent_table = 'public.ab228'::regclass and action = 'retain_drop'),
  array['0', '10', '20'],
  'and retired B');
select is((select last_value from public.ab228_calls_a), 1::bigint,
  'A''s chunk was handed to the strategy exactly once (not re-uploaded after B''s raise)');
select is((select last_value from public.ab228_calls_c), 1::bigint,
  'C''s chunk was handed to the strategy exactly once');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ab228'::regclass and action = 'skip_archive'),
  1, 'the recovered tick logged no further deferral');

select * from finish();
