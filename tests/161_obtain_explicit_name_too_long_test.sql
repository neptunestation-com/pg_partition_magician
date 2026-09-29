-- An upgraded day grid whose explicit-range name cannot fit keeps growing past the one cell (issue #663).
--
-- #572: on a day grid labelled before #503 (east of UTC, anchored at local midnight), the first cell past the
-- last legacy child renders the plain name that child already carries, so obtain and extend_to build that
-- cell under its explicit-range name, _p<lo>_to_<hi>, which is 14 bytes longer. #510: _part_name REFUSES a
-- name over 63 bytes rather than truncating it. For a table whose name fits the plain day label but not the
-- explicit one (38 to 51 bytes), the two met: the collided cell's explicit name raised, and obtain is one
-- function, so the raise unwound every cell the call would have built. maintain_obtain logged skip_obtain
-- on every tick, the forward grid never grew again, and every write past it was refused.
--
-- The contract: that one cell is left unbuilt (never under a cut name), exactly like a cell whose name a
-- relation pgpm does not own holds, and the cells after it are built, by the maintenance tick and by
-- extend_to alike. The catch is for that name only: a table whose PLAIN label does not fit is still refused.
--
-- The legacy state is built as tests/138 builds it, under a 41-byte name the parent is given after the
-- transmute (the current transmute refuses a name whose monolith label would not fit). Every negative ("no
-- skip_obtain", "no cut name") is paired with a witness that the collision was there and that the builder
-- reached past it. bench/obtain_explicit_name_too_long.sh runs this file against
-- obtain_explicit_name_uncaught, the mutation that lets the refusal escape again, and is required to FAIL.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(15);

set timezone = 'Asia/Tokyo';

\set R f4_events_ingest_pipeline_raw_log_archive

-- the pre-#503 labelling, applied to one parent's fine day children under its CURRENT name
create function pg_temp.legacy_relabel(p_parent regclass) returns int language plpgsql as $$
declare r record; v_old text; v_nsp name; v_rel name; n int := 0;
begin
  select n2.nspname, c.relname into v_nsp, v_rel from pg_class c join pg_namespace n2 on n2.oid = c.relnamespace where c.oid = p_parent;
  for r in select p.child_name, p.lo from pgpm.part p
            where p.parent_table = p_parent and p.attached and p.child_name !~ '_to_'
            order by p.lo::timestamptz desc loop
    v_old := v_rel || '_p' || to_char(r.lo::timestamptz at time zone 'Asia/Tokyo', 'YYYY_MM_DD');
    execute format('alter table %I.%I rename to %I', v_nsp, r.child_name, v_old);
    update pgpm.part set child_name = v_old where parent_table = p_parent and child_name = r.child_name;
    n := n + 1;
  end loop;
  return n;
end $$;

create table public.f663 (id bigserial, ts timestamptz not null default now(), payload text, primary key (id, ts));
insert into public.f663 (ts, payload) values (now() - interval '3 days', 'old');
call pgpm.transmute('public.f663', 'ts', interval '1 day', p_obtain => 3,
                    p_anchor => '2000-01-01 00:00:00+09', p_paused => false);
alter table public.f663 rename to :R;
select cmp_ok(pg_temp.legacy_relabel(format('public.%I', :'R')::regclass), '>=', 3,
  'LIVENESS: the grid''s fine day children carry their pre-#503 (Tokyo wall date) labels');

select p.child_name as top_name, p.hi as top_hi from pgpm.part p
 where p.parent_table = format('public.%I', :'R')::regclass and p.attached
 order by p.lo::timestamptz desc limit 1 \gset
select is(pgpm._part_name(:'R', 'time', '1 day', :'top_hi', null, 'Asia/Tokyo')::text, :'top_name',
  'LIVENESS: the last child''s legacy label is the plain name of the NEXT cell (the #572 collision)');
select is(octet_length(:'top_name'), 53, 'LIVENESS: the table''s plain day labels fit (53 bytes)');
select throws_like(
  format($$ select pgpm._part_name(%L, 'time', '1 day', %L, %L, 'Asia/Tokyo', true) $$,
         :'R', :'top_hi', (:'top_hi'::timestamptz + interval '1 day')::text),
  'pg_partition_magician: cannot name a partition of %_to_% is 67 bytes%',
  'LIVENESS: and the collided cell''s explicit-range name is 67 bytes, which _part_name refuses');

-- ==================== (a) the maintenance tick builds past the collided cell ====================
select pgpm.set_obtain(format('public.%I', :'R')::regclass, 5);
call pgpm.maintain_obtain(format('public.%I', :'R')::regclass, null) \gset
select matches(:'p_status'::text, '^obtained=[1-9][0-9]*$', 'the obtain tick built cells: ' || :'p_status');
select is((select count(*)::int from pgpm.log where parent_table = format('public.%I', :'R')::regclass and action = 'skip_obtain'), 0,
  'and logged no skip_obtain');
select is(
  (select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
    where parent_table = format('public.%I', :'R')::regclass and attached and lo::timestamptz > :'top_hi'::timestamptz),
  (select array_agg(d order by d) from generate_series(:'top_hi'::timestamptz + interval '1 day',
     pgpm._grid_floor('time', '1 day', '2000-01-01 00:00:00+09', pgpm._ts_text(now()), 'UTC')::timestamptz + interval '5 days',
     interval '1 day') d),
  'every cell from the one after the collided cell to the end of the lookahead is built');
select is(
  (select count(*)::int from pgpm.part where parent_table = format('public.%I', :'R')::regclass
      and lo::timestamptz = :'top_hi'::timestamptz),
  0, 'the collided cell itself is left unbuilt');
select is(
  to_regclass(format('public.%I', left(:'R' || '_p' || to_char(:'top_hi'::timestamptz at time zone 'UTC', 'YYYY_MM_DD')
    || '_to_' || to_char((:'top_hi'::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY_MM_DD'), 63))),
  null, 'and no relation carries its explicit-range name cut to 63 bytes');
select is(
  (select child_oid from pgpm.part where parent_table = format('public.%I', :'R')::regclass and child_name = :'top_name'),
  to_regclass(format('public.%I', :'top_name'))::oid,
  'the legacy child keeps its name and its registry row');

-- ==================== (b) extend_to reaches past it too ====================
select max(hi) as grid_top from pgpm.part where parent_table = format('public.%I', :'R')::regclass and attached \gset
select cmp_ok(pgpm.extend_to(format('public.%I', :'R')::regclass, (:'grid_top'::timestamptz + interval '1 day 1 hour')::text), '=', 2,
  'extend_to builds the two cells up to a value a day past the grid''s top');
select is(
  (select max(hi)::timestamptz from pgpm.part where parent_table = format('public.%I', :'R')::regclass and attached),
  :'grid_top'::timestamptz + interval '2 days', 'and the grid now covers it');
select lives_ok(
  format($$ insert into public.%I (ts, payload) values (%L, 'far') $$, :'R', (:'grid_top'::timestamptz + interval '1 day 1 hour')::text),
  'so a write there is accepted');

-- ==================== (c) the catch is for that one name only ====================
-- 52 bytes: its PLAIN day label is 64, which is still refused, loudly, as #510 has it.
alter table public.:R rename to f4_events_ingest_pipeline_raw_log_archive_1234567890;
select is(octet_length('f4_events_ingest_pipeline_raw_log_archive_1234567890'), 52, 'LIVENESS: a 52-byte table name');
select throws_like(
  $$ select pgpm.obtain('public.f4_events_ingest_pipeline_raw_log_archive_1234567890') $$,
  'pg_partition_magician: cannot name a partition of %is 64 bytes%',
  'obtain still refuses a table whose plain day label would not fit');

select * from finish();
