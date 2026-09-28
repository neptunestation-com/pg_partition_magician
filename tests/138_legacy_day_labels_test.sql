-- A day grid named before #503 keeps growing after the upgrade (issue #572).
--
-- #503 made a day or week cell's label the UTC date of its start; before it, the label was the WALL date
-- of the start in partition_tz. Names of existing partitions were deliberately not changed, and neither
-- was the check obtain and extend_to use to decide a candidate already exists: to_regclass on its name.
-- In a zone east of UTC with the grid anchored at local midnight (Asia/Tokyo, cells starting 15:00Z),
-- a cell's wall date is one day later than its UTC date, so the NEW label of every cell is the OLD label
-- of the cell before it. On an upgraded grid the first cell past the last pre-upgrade child therefore
-- renders the name that child already carries, obtain took it for built, and skipped it: a one-day hole
-- that refused every write into that day, with nothing logged, while the cells after it were built.
--
-- The contract: a candidate whose plain name is held by one of THIS parent's own partitions for a
-- different range (a pre-#503 label) is built under its explicit-range name, _p<lo>_to_<hi>, which no
-- one-step cell's plain name can equal. The legacy partition is not renamed or touched. Names stay
-- labels; the bounds in pgpm.part are what decide whether a cell exists.
--
-- The legacy state is built the way a pre-#503 release left it: every fine day child renamed to its
-- wall-date label by the documented rename procedure (ALTER TABLE ... RENAME plus pgpm.part.child_name
-- in one transaction), highest lo first so no two names collide mid-way. Every "covered" below is paired
-- with a witness that the collision was really there (the last child's legacy label IS the next cell's
-- plain name) and that the builder really reached past it (the cell after the gap was built).
-- bench/legacy_day_labels.sh runs this file against legacy_day_label_skipped_by_name, the mutation that
-- skips the collided candidate again, and is required to FAIL there.
create extension if not exists pgtap;
select plan(22);

set timezone = 'Asia/Tokyo';

-- the pre-#503 labelling, applied to one parent's fine day children (coarse `_to_` children untouched)
create function pg_temp.legacy_relabel(p_parent regclass) returns int language plpgsql as $$
declare r record; v_old text; v_nsp name; n int := 0;
begin
  select n2.nspname into v_nsp from pg_class c join pg_namespace n2 on n2.oid = c.relnamespace where c.oid = p_parent;
  for r in select p.child_name, p.lo from pgpm.part p
            where p.parent_table = p_parent and p.attached and p.child_name !~ '_to_'
            order by p.lo::timestamptz desc loop
    v_old := regexp_replace(r.child_name, '_p[0-9_]+$', '') || '_p'
             || to_char(r.lo::timestamptz at time zone 'Asia/Tokyo', 'YYYY_MM_DD');
    execute format('alter table %I.%I rename to %I', v_nsp, r.child_name, v_old);
    update pgpm.part set child_name = v_old where parent_table = p_parent and child_name = r.child_name;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ==================== (a) obtain on an upgraded Tokyo day grid ====================
create table public.lg (id bigserial, ts timestamptz not null default now(), payload text, primary key (id, ts));
insert into public.lg (ts, payload) values (now() - interval '3 days', 'old');
call pgpm.transmute('public.lg', 'ts', interval '1 day', p_obtain => 3, p_anchor => '2000-01-01 00:00:00+09');
select cmp_ok(pg_temp.legacy_relabel('public.lg'), '>=', 3, 'LIVENESS: the transmuted grid had its fine day children relabelled the pre-#503 way');

select p.child_name as lg_top_name, p.child_oid as lg_top_oid, p.hi as lg_top_hi
  from pgpm.part p where p.parent_table = 'public.lg'::regclass and p.attached
 order by p.lo::timestamptz desc limit 1 \gset

select is(:'lg_top_name', 'lg_p' || to_char((:'lg_top_hi'::timestamptz - interval '1 day') at time zone 'Asia/Tokyo', 'YYYY_MM_DD'),
  'LIVENESS: the last forward child carries its pre-#503 label, the Tokyo wall date of its start');
select is(pgpm._part_name('lg', 'time', '1 day', :'lg_top_hi', null, 'Asia/Tokyo')::text, :'lg_top_name',
  'LIVENESS: that label is exactly the plain name the current rule gives the NEXT cell (the collision #572 needs)');

select pgpm.set_obtain('public.lg', 5);
select cmp_ok(pgpm.obtain('public.lg'), '>=', 1, 'LIVENESS: obtain built new cells past the upgraded top');
select is(
  (select child_name::text from pgpm.part where parent_table = 'public.lg'::regclass and attached
      and lo::timestamptz = :'lg_top_hi'::timestamptz + interval '1 day'),
  'lg_p' || to_char((:'lg_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'LIVENESS: obtain reached PAST the collided cell and built the one after it under its plain UTC name');

select is(
  (select child_name::text || ' [' || lo::timestamptz || ', ' || hi::timestamptz || ')' from pgpm.part
    where parent_table = 'public.lg'::regclass and attached and lo::timestamptz = :'lg_top_hi'::timestamptz),
  'lg_p' || to_char(:'lg_top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'lg_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD')
    || ' [' || :'lg_top_hi'::timestamptz || ', ' || (:'lg_top_hi'::timestamptz + interval '1 day') || ')',
  'the cell whose plain name the legacy child holds is built, one step wide, under its explicit-range name');
select is(
  (select c.relname::text from pg_inherits i join pg_class c on c.oid = i.inhrelid
    where i.inhparent = 'public.lg'::regclass and c.relname::text = pgpm._part_name('lg', 'time', '1 day', :'lg_top_hi',
          (:'lg_top_hi'::timestamptz + interval '1 day')::text, 'Asia/Tokyo', true)::text),
  pgpm._part_name('lg', 'time', '1 day', :'lg_top_hi', (:'lg_top_hi'::timestamptz + interval '1 day')::text, 'Asia/Tokyo', true)::text,
  'and it is attached to the parent, so PostgreSQL routes into it');
select is(
  (select string_agg(child_name || ' ends ' || hi || ' but the next starts ' || nlo, '; ' order by lo)
     from (select child_name, lo::timestamptz as lo, hi::timestamptz as hi,
                  lead(lo::timestamptz) over (order by lo::timestamptz) as nlo
             from pgpm.part where parent_table = 'public.lg'::regclass and attached) w
    where nlo is not null and hi <> nlo),
  null::text, 'the grid is contiguous from the monolith to the new top: every hi equals the next lo');
select is(
  (select child_name::text || '/' || (child_oid = :'lg_top_oid'::oid)::text || '/' || (to_regclass('public.' || :'lg_top_name')::oid = :'lg_top_oid'::oid)::text
     from pgpm.part where parent_table = 'public.lg'::regclass and attached
      and lo::timestamptz = :'lg_top_hi'::timestamptz - interval '1 day'),
  :'lg_top_name' || '/true/true',
  'the legacy child keeps its name and its identity: obtain renamed and replaced nothing');

insert into public.lg (ts, payload) values (:'lg_top_hi'::timestamptz + interval '2 hours', 'in the collided day');
select is(
  (select c.relname::text from public.lg e join pg_class c on c.oid = e.tableoid where e.payload = 'in the collided day'),
  'lg_p' || to_char(:'lg_top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'lg_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'a write into the collided day is accepted and lands in the cell built for it');
insert into public.lg (ts, payload) values (:'lg_top_hi'::timestamptz - interval '2 hours', 'in the legacy top');
select is(
  (select c.relname::text from public.lg e join pg_class c on c.oid = e.tableoid where e.payload = 'in the legacy top'),
  :'lg_top_name', 'a write into the last legacy day still lands in the legacy child');

select pgpm.obtain('public.lg') as lg_second_obtain \gset
select is(
  (select string_agg(child_name::text, ',' order by child_name) from pgpm.part
    where parent_table = 'public.lg'::regclass and lo::timestamptz = :'lg_top_hi'::timestamptz),
  'lg_p' || to_char(:'lg_top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'lg_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'a second obtain finds the cell by its bounds and builds no second relation for it');

-- ==================== (b) extend_to on an upgraded Tokyo day grid ====================
create table public.lx (id bigserial, ts timestamptz not null default now(), payload text, primary key (id, ts));
insert into public.lx (ts, payload) values (now() - interval '3 days', 'old');
call pgpm.transmute('public.lx', 'ts', interval '1 day', p_obtain => 3, p_anchor => '2000-01-01 00:00:00+09');
select cmp_ok(pg_temp.legacy_relabel('public.lx'), '>=', 3, 'LIVENESS: the second grid had its fine day children relabelled the pre-#503 way');

select p.child_name as lx_top_name, p.hi as lx_top_hi
  from pgpm.part p where p.parent_table = 'public.lx'::regclass and p.attached
 order by p.lo::timestamptz desc limit 1 \gset
select is(pgpm._part_name('lx', 'time', '1 day', :'lx_top_hi', null, 'Asia/Tokyo')::text, :'lx_top_name',
  'LIVENESS: its last child''s legacy label is the plain name of the next cell');

select cmp_ok(pgpm.extend_to('public.lx', (:'lx_top_hi'::timestamptz + interval '1 day 12 hours')::text), '>=', 1,
  'LIVENESS: extend_to built cells past the upgraded top');
select is(
  (select child_name::text from pgpm.part where parent_table = 'public.lx'::regclass and attached
      and lo::timestamptz = :'lx_top_hi'::timestamptz + interval '1 day'),
  'lx_p' || to_char((:'lx_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'LIVENESS: extend_to reached the cell holding its target, past the collided one');
select is(
  (select child_name::text from pgpm.part where parent_table = 'public.lx'::regclass and attached
      and lo::timestamptz = :'lx_top_hi'::timestamptz and hi::timestamptz = :'lx_top_hi'::timestamptz + interval '1 day'),
  'lx_p' || to_char(:'lx_top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'lx_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'extend_to builds the collided cell under its explicit-range name');
insert into public.lx (ts, payload) values (:'lx_top_hi'::timestamptz + interval '5 hours', 'in the collided day');
select is(
  (select c.relname::text from public.lx e join pg_class c on c.oid = e.tableoid where e.payload = 'in the collided day'),
  'lx_p' || to_char(:'lx_top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'lx_top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'),
  'a write into the collided day is accepted there too');

-- ==================== (c) the explicit form is only the fallback ====================
-- A grid that never had legacy labels names every cell plainly: the fallback does not leak into the
-- ordinary path, where the plain name is free.
create table public.lu (id bigserial, ts timestamptz not null default now(), primary key (id, ts));
insert into public.lu (ts) values (now() - interval '3 days');
call pgpm.transmute('public.lu', 'ts', interval '1 day', p_obtain => 3, p_anchor => '2000-01-01 00:00:00+09');
select cmp_ok((select count(*)::int from pgpm.part where parent_table = 'public.lu'::regclass and attached and child_name !~ '_to_'),
  '>=', 3, 'LIVENESS: the unrelabelled grid has its fine children');
select is(
  (select string_agg(child_name::text, ',') from pgpm.part where parent_table = 'public.lu'::regclass and attached
      and child_name <> pgpm._part_name('lu', 'time', '1 day', lo, null, 'Asia/Tokyo')
      and child_name !~ '^lu_p[0-9_]+_to_[0-9_]+$'),
  null::text, 'every fine child of a grid named under the current rule carries its plain UTC name');
select is(
  (select count(*)::int from pgpm.part where parent_table = 'public.lu'::regclass and attached and child_name ~ '_to_'),
  1, 'and the only explicit-range child is the monolith');
select is(
  pgpm._part_name('lu', 'time', '1 day', '2026-10-02 15:00:00+00', '2026-10-03 15:00:00+00', 'Asia/Tokyo', true)::text,
  'lu_p2026_10_02_to_2026_10_03', '_part_name renders a one-step cell''s explicit-range form on request, in UTC dates');

select * from finish();
