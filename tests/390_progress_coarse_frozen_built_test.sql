-- progress().coarse_frozen counts only coarse partitions that are there (issue #1038, its first bullet).
--
-- THE GAP. coarse_frozen read pgpm.part's attached rows with only _part_detached_by_hand left out (#705), which is
-- true only while the row's relation still exists. A frozen coarse partition the operator DROPPED by hand keeps its
-- attached row (retire() refuses the name and logs it, which is why the row is left), so progress() went on counting
-- it as frozen history waiting to be split, while status().coarse_partitions, which reads the same rows through
-- pgpm._part_built (#908, #956), did not count it: the two disagreed about a cell that is not there.
--
-- THE CONTRACT. coarse_frozen applies _part_built, as status() does: a frozen coarse partition dropped by hand, or
-- detached by hand, is not counted; one that is there is.
-- Fixture: two parents, each a monolith [0, 250) over a step of 50 behind a frontier at 1000. One keeps its monolith
-- (counted, 1), the other's is dropped by hand (0), so a count that ignores the drop cannot read right on both.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(7);

create table public.cf390a (id bigint primary key, payload text);
create table public.cf390b (id bigint primary key, payload text);
insert into public.cf390a select g, 'x' from generate_series(1, 200) g;
insert into public.cf390b select g, 'x' from generate_series(1, 200) g;
call pgpm.transmute('public.cf390a', 'id', 50);
call pgpm.transmute('public.cf390b', 'id', 50);
select pgpm.obtain('public.cf390a');
select pgpm.obtain('public.cf390b');
insert into public.cf390a values (1000, 'frontier');
insert into public.cf390b values (1000, 'frontier');

select child_name as mono_b from pgpm.part
 where parent_table = 'public.cf390b'::regclass and attached order by lo::numeric limit 1 \gset
select is((select array_agg(coarse_frozen order by parent) from pgpm.progress() where parent in ('public.cf390a'::regclass, 'public.cf390b'::regclass)),
  array[1, 1]::bigint[],
  'LIVENESS: before the drop, progress() counts each frozen monolith');

-- An operator drops b's frozen coarse history by hand (PostgreSQL permits DROP TABLE on a partition).
select format('drop table public.%I', :'mono_b') \gexec

select is(to_regclass(format('public.%I', :'mono_b')), null::regclass,
  'LIVENESS: b''s monolith relation is gone');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.cf390b'::regclass
                    and child_name = :'mono_b' and attached and child_oid is not null),
  'LIVENESS: its pgpm.part row still reads attached, with the oid it was created with');
select is(coarse_partitions, 0::bigint,
  'GUARD: status() does not count the dropped cell as coarse (_part_built)') from pgpm.status() where parent = 'public.cf390b'::regclass;
select is(coarse_partitions, 1::bigint,
  'GUARD: and it does count a''s, which is there') from pgpm.status() where parent = 'public.cf390a'::regclass;

select is(coarse_frozen, 0::bigint,
  'progress().coarse_frozen does not count a frozen coarse partition dropped by hand') from pgpm.progress('public.cf390b');
select is(coarse_frozen, 1::bigint,
  'and still counts one that is there') from pgpm.progress('public.cf390a');
select * from finish();
