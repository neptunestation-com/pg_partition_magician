-- Every cell a grid can produce gets its own name (issue #582).
--
-- _part_name is a label, but obtain, extend_to and regrain_step decide whether a cell's child ALREADY
-- EXISTS by that name, so two cells that render one name are one cell too few: obtain skips the second as
-- existing (nothing logged, a permanent hole that refuses writes) and regrain copies the second cell's rows
-- into the first cell's child, whose bound CHECK rejects them with a raw 23514 on every attempt. Three
-- labels were not injective:
--
--   * a fixed time step under a minute: the finest label was YYYY_MM_DD_HH24MI, so the two 30-second
--     cells of a minute (and every sub-second cell of a second) shared a name. transmute, regrain and
--     set_regrain all accept such a step.
--   * an id at or past 10^19: the label was lpad(floor(lo)::text, 19, '0'), and lpad TRUNCATES a longer
--     string, so the cell at 10^19 rendered the name of the cell at 10^18. A numeric key is a documented
--     id column.
--   * a non-integral id: floor() dropped the fraction, so the 0.5-wide cells a regrain toward '0.5' cuts
--     from a numeric grid shared names in pairs.
--
-- The fix labels a sub-minute cell to the second (HH24MISS) and a sub-second one to the microsecond, pads
-- an id label to 19 digits without ever cutting it, and appends a non-integral id's fraction. Every label
-- that was already injective keeps its historical form, so no existing grid's names move.
--
-- Every "distinct" and "no hole" below is paired with a witness that the collision was really set up: the
-- two instants really share a minute, 10^19 really has 20 digits, 1.5 really floors onto 1, obtain and
-- regrain really ran and did work. bench/part_name_labels_injective.sh runs this file against the mutants
-- that put each old label back (part_name_minute_floor, part_name_id_label_truncated), so it is also
-- required to FAIL there.
create extension if not exists pgtap;
select plan(35);
set timezone = 'UTC';

-- a relation's bare name, whatever the search_path makes regclass::text print
create function pg_temp.pli_rel(p_oid oid) returns text language sql as $$
  select relname::text from pg_class where oid = p_oid
$$;
-- regrain's outcome as a value, so a refusal or a raw error is an assertion's failure, not the file's end
create function pg_temp.pli_try_regrain(p_parent regclass, p_child name, p_step text) returns text
language plpgsql as $$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'error [' || sqlstate || ']: ' || sqlerrm;
end $$;

-- =================================== (A) the adapter: time labels ===================================
select is(date_trunc('minute', '2026-09-28 12:14:30+00'::timestamptz), '2026-09-28 12:14:00+00'::timestamptz,
  'LIVENESS: the cells at 12:14:00 and 12:14:30 start in the same minute, so a minute label cannot tell them apart');
select is(pgpm._part_name('ev', 'time', '30 seconds', '2026-09-28 12:14:30+00', null, 'UTC')::text,
  'ev_p2026_09_28_121430', 'a 30-second cell is labelled to the second');
select isnt(pgpm._part_name('ev', 'time', '30 seconds', '2026-09-28 12:14:00+00', null, 'UTC')::text,
  pgpm._part_name('ev', 'time', '30 seconds', '2026-09-28 12:14:30+00', null, 'UTC')::text,
  'the two 30-second cells of one minute have different names');
select is(pgpm._part_name('ev', 'time', '500 milliseconds', '2026-09-28 12:14:00.5+00', null, 'UTC')::text,
  'ev_p2026_09_28_121400_500000', 'a sub-second cell is labelled to the microsecond');
select isnt(pgpm._part_name('ev', 'time', '500 milliseconds', '2026-09-28 12:14:00+00', null, 'UTC')::text,
  pgpm._part_name('ev', 'time', '500 milliseconds', '2026-09-28 12:14:00.5+00', null, 'UTC')::text,
  'the two half-second cells of one second have different names');
select is(pgpm._part_name('ev', 'time', '30 seconds', '2026-09-28 12:14:00+00', '2026-09-28 12:15:30+00', 'UTC')::text,
  'ev_p2026_09_28_121400_to_2026_09_28_121530', 'a coarse sub-minute name renders both bounds to the second');
select is(pgpm._part_name('ev', 'time', '1 minute', '2026-09-28 12:14:00+00', null, 'UTC')::text,
  'ev_p2026_09_28_1214', 'a minute cell keeps its historical minute label, so no existing grid''s names move');
select is(pgpm._part_name('ev', 'time', '90 seconds', '2026-09-28 12:15:30+00', null, 'UTC')::text,
  'ev_p2026_09_28_1215', 'a step of a minute or more keeps the minute label (its cells never share a minute)');

-- ==================================== (B) the adapter: id labels ====================================
select is(length('10000000000000000000'), 20, 'LIVENESS: 10^19 has 20 digits, one more than the 19-digit label');
select is(pgpm._part_name('n', 'id', '1000000000000000000', '10000000000000000000', null, 'UTC')::text,
  'n_p10000000000000000000', 'the cell at 10^19 is labelled with all 20 digits, never truncated');
select is(pgpm._part_name('n', 'id', '1000000000000000000', '1000000000000000000', null, 'UTC')::text,
  'n_p1000000000000000000', 'the cell at 10^18 keeps its 19-digit label');
select is(pgpm._part_name('n', 'id', '1000000000000000000', '11000000000000000000', '13000000000000000000', 'UTC')::text,
  'n_p11000000000000000000_to_13000000000000000000', 'a coarse name past 10^19 carries both bounds whole');
select is(pgpm._part_name('n', 'id', '1000', '5000', null, 'UTC')::text,
  'n_p0000000000000005000', 'a short id is still zero-padded to 19 digits, so no existing grid''s names move');
select is(floor(1.5::numeric), 1::numeric, 'LIVENESS: 1.5 floors onto 1, so a floor label cannot tell the two cells apart');
select is(pgpm._part_name('f', 'id', '0.5', '1.5', null, 'UTC')::text,
  'f_p0000000000000000001_5', 'a non-integral id cell carries its fraction');
select isnt(pgpm._part_name('f', 'id', '0.5', '1', null, 'UTC')::text,
  pgpm._part_name('f', 'id', '0.5', '1.5', null, 'UTC')::text,
  'the 0.5-wide cells at 1 and 1.5 have different names');
select is(pgpm._part_name('f', 'id', '0.5', '1.50', null, 'UTC')::text,
  pgpm._part_name('f', 'id', '0.5', '1.5', null, 'UTC')::text,
  'one cell has one name whatever the scale its bound is written at (1.50 is 1.5)');

-- ================================ (C) obtain on a 30-second time grid ================================
create table public.pli_ev (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into public.pli_ev (ts) values (now() - interval '2 minutes'), (now() - interval '1 minute');
call pgpm.transmute('public.pli_ev', 'ts', interval '30 seconds', p_obtain => 6);
create temp table pli_h as
select max(hi::timestamptz) as mono_hi from pgpm.part
 where parent_table = 'public.pli_ev'::regclass and child_name like '%\_to\_%';

select isnt((select mono_hi from pli_h), null, 'LIVENESS: transmute completed and recorded the monolith');
select cmp_ok((select count(*) from pgpm.log where parent_table = 'public.pli_ev'::regclass and action = 'obtain'),
  '>=', 2::bigint, 'LIVENESS: obtain ran and created more than one forward cell');
select is(
  (select array_agg(c order by c) from pli_h, generate_series(pli_h.mono_hi, pli_h.mono_hi + interval '90 seconds', interval '30 seconds') c
    where not exists (select 1 from pgpm.part p where p.parent_table = 'public.pli_ev'::regclass and p.attached
                        and p.lo::timestamptz = c and p.hi::timestamptz = c + interval '30 seconds')),
  null::timestamptz[],
  'every 30-second cell in [mono_hi, mono_hi + 2 min) has its own partition (none skipped for a shared name)');
select lives_ok(
  format('insert into public.pli_ev (ts) values (%L), (%L), (%L)',
         (select mono_hi + interval '15 seconds' from pli_h), (select mono_hi + interval '45 seconds' from pli_h),
         (select mono_hi + interval '75 seconds' from pli_h)),
  'a write into each of three consecutive 30-second cells is accepted');
select is(
  (select array_agg(pg_temp.pli_rel(e.tableoid) order by e.ts) from public.pli_ev e, pli_h where e.ts >= pli_h.mono_hi),
  (select array_agg(format('pli_ev_p%s', to_char(c at time zone 'UTC', 'YYYY_MM_DD_HH24MISS')) order by c)
     from pli_h, generate_series(pli_h.mono_hi, pli_h.mono_hi + interval '60 seconds', interval '30 seconds') c),
  'each of those writes landed in the cell named for its own 30 seconds');

-- ================================== (D) obtain on an id grid past 10^19 ==================================
create table public.pli_n (id numeric primary key, v text);
insert into public.pli_n values (500000000000000000, 'a'), (600000000000000000, 'b');
call pgpm.transmute('public.pli_n', 'id', 1000000000000000000::bigint, p_obtain => 11);

select ok(exists (select 1 from pgpm.part where parent_table = 'public.pli_n'::regclass and lo::numeric = 11000000000000000000),
  'LIVENESS: obtain''s lookahead reached past 10^19 (the cell at 1.1*10^19 exists)');
select is((select array_agg(c order by c) from generate_series(1000000000000000000::numeric, 11000000000000000000::numeric, 1000000000000000000::numeric) c
            where not exists (select 1 from pgpm.part p where p.parent_table = 'public.pli_n'::regclass and p.attached
                                and p.lo::numeric = c and p.hi::numeric = c + 1000000000000000000)),
          null::numeric[],
  'every cell from 10^18 to 1.1*10^19 has its own partition (none skipped for a truncated name)');
select is((select child_name::text from pgpm.part where parent_table = 'public.pli_n'::regclass and lo::numeric = 10000000000000000000),
  'pli_n_p10000000000000000000', 'the cell at 10^19 is the child named for 10^19');
select lives_ok($$insert into public.pli_n values (10500000000000000000, 'c')$$,
  'a write of 1.05*10^19 is accepted');
select is((select pg_temp.pli_rel(tableoid) from public.pli_n where v = 'c'), 'pli_n_p10000000000000000000',
  'and it landed in the cell at 10^19, not in its predecessor');
select is((select string_agg(v, ',' order by id) from public.pli_n where v in ('a', 'b')), 'a,b',
  'the original rows are intact, by identity');

-- ========================= (E) regrain of a uuidv7 minute monolith toward 30 seconds =========================
-- uuidv7's frontier is its data, so a row written past the monolith freezes it at once (the lever of
-- tests/125_uuidv7_regrain_archive): no waiting for the wall clock the way a `time` monolith needs.
-- Asymmetric on purpose: two rows in the two halves of one minute, one in the next.
create table public.pli_u (id uuid primary key, payload text);
insert into public.pli_u values
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '10 s'), 'first half'),
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '3 minutes' + interval '40 s'), 'second half'),
  (pgpm._ts_to_uuid(date_trunc('minute', now()) - interval '2 minutes' + interval '10 s'), 'next minute');
call pgpm.transmute('public.pli_u', 'id', interval '1 minute', p_obtain => 6);
insert into public.pli_u values (pgpm._ts_to_uuid(date_trunc('minute', now()) + interval '4 minutes 5 s'), 'frontier');
select child_name as pli_mono, lo as pli_mono_lo, hi as pli_mono_hi from pgpm.part
 where parent_table = 'public.pli_u'::regclass and attached order by lo::timestamptz limit 1 \gset
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as pli_u_rows from public.pli_u \gset

select ok(:'pli_mono' like '%\_to\_%' and :'pli_mono_hi'::timestamptz - :'pli_mono_lo'::timestamptz >= interval '3 minutes',
  'LIVENESS: a coarse monolith spanning at least three minutes: ' || :'pli_mono');
select is(pg_temp.pli_try_regrain('public.pli_u', :'pli_mono', '30 seconds'),
  'swapped:' || (extract(epoch from :'pli_mono_hi'::timestamptz - :'pli_mono_lo'::timestamptz) / 30)::int,
  'regrain toward 30 seconds completes, one child per 30-second cell of the monolith');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.pli_u'::regclass and attached and hi::timestamptz <= :'pli_mono_hi'::timestamptz),
  (select array_agg(c order by c) from generate_series(:'pli_mono_lo'::timestamptz, :'pli_mono_hi'::timestamptz - interval '30 seconds', interval '30 seconds') c),
  'the monolith is replaced by exactly its 30-second cells');
select is((select array_agg(pg_temp.pli_rel(tableoid) order by id) from public.pli_u where payload like '%half'),
  array[format('pli_u_p%s00', to_char(:'pli_mono_lo'::timestamptz at time zone 'UTC', 'YYYY_MM_DD_HH24MI')),
        format('pli_u_p%s30', to_char(:'pli_mono_lo'::timestamptz at time zone 'UTC', 'YYYY_MM_DD_HH24MI'))],
  'the two rows of one minute sit in the two children named for their own halves of it');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.pli_u), :'pli_u_rows',
  'every row survives the regrain: none lost, none duplicated');

-- ================================ (F) regrain of an id monolith toward 0.5 ================================
create table public.pli_f (id numeric primary key, v text);
insert into public.pli_f values (1, 'a'), (1.7, 'b'), (2.2, 'c');
call pgpm.transmute('public.pli_f', 'id', 10::bigint, p_obtain => 2);
insert into public.pli_f values (25, 'frontier');
select is(pg_temp.pli_try_regrain('public.pli_f', (select child_name from pgpm.part where parent_table = 'public.pli_f'::regclass
                                                     and attached order by lo::numeric limit 1), '0.5'),
  'swapped:20', 'regrain of [0, 10) toward 0.5 completes, into twenty children');
select is((select array_agg(v || '@' || pg_temp.pli_rel(tableoid) order by id) from public.pli_f where id < 10),
  array['a@pli_f_p0000000000000000001', 'b@pli_f_p0000000000000000001_5', 'c@pli_f_p0000000000000000002'],
  'each row sits in the half-unit cell that holds it: 1 and 1.7 no longer share a child');

select * from finish();
