-- Issue #1312: a whole-month text_time grid needs its p_tt_epoch itself on the encoding's unit.
--
-- _text_time_unit_contract held only that (anchor - p_tt_epoch) and the step are whole units, reasoning that
-- every bound is the anchor plus whole steps. A whole-month step's bounds are not: they are midnight on the 1st
-- whatever the anchor (_grid_floor's calendar branch), a whole second. With p_tt_epoch
-- '1970-01-01 00:00:00.5+00' on a seconds encoding and an anchor whole seconds from it, transmute registered a
-- grid whose every catalog bound was floored half a second below the bound pgpm.part records, and a 1-month
-- regrain of it (which _regrain_step_shape let through, asking the epoch nothing) copied rows by the floored
-- bounds, reconciled them by the unfloored ones, and brought back at the swap two rows deleted while it ran.
--
-- The rule (_text_time_epoch_on_unit): a whole-month step, the grid's or a regrain target's, is refused on a
-- text_time key whose epoch is not a whole unit. Every site that admits one asks it:
--   door 1, transmute: refuses a whole-month step on such an epoch (seconds and milliseconds alike), and
--     accepts the same table with a fixed step, whose bounds are the anchor plus whole steps and agree with the
--     catalog, bound by bound; a whole-month step on an epoch that IS on the unit converts too.
--   door 2, a registered whole-month grid on such an epoch (an install before this fix registered it, made
--     here by transmute with the helper answering true, then the helper restored from its own saved
--     definition): set_regrain refuses any target, regrain_step refuses before it looks for anything, nothing
--     is stored, and the remedy the refusal names (untransmute, then transmute with a fixed step) works as
--     typed.
--   door 3, a fixed grid on such an epoch: a whole-month regrain target is refused (its fine bounds are
--     midnights), and a fixed target is accepted and keeps a row deleted mid-regrain deleted, rows named by
--     identity, the fixture asymmetric (two boundary rows deleted, one boundary row and two mid-cell rows
--     kept), with liveness that the copy held the deleted rows before the DELETEs committed and that the run
--     reached its swap after them.
-- bench/text_time_month_grid_epoch_unit.sh runs this file against the mutant text_time_epoch_unit_swapped.
set timezone = 'UTC';
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(29);

-- the off-unit epoch every table below but xc and xn uses, and its seconds key: 8 hex digits of whole seconds
-- since that epoch, then a 4-digit row tag
create function pg_temp.k(p_ts timestamptz, n int) returns text language sql as $$
  select pgpm._ts_to_text_time(p_ts, '', 8, 16, 's', null, 0, '1970-01-01 00:00:00.5+00') || lpad(n::text, 4, '0') $$;
create function pg_temp.dec(p_id text, p_epoch timestamptz) returns timestamptz language sql as $$
  select pgpm._text_time_to_ts(left(p_id, 8), '', 8, 16, 's', null, 0, p_epoch) $$;
-- a 10-day fine bound of the fixed grid below (anchor 2000-01-01 00:00:00.5+00): the grid's own floor
create function pg_temp.f10(p_ts timestamptz) returns timestamptz language sql as $$
  select pgpm._grid_floor('text_time', '10 days', '2000-01-01 00:00:00.5+00', pgpm._ts_text(p_ts), 'UTC')::timestamptz $$;
-- every attached partition of p whose catalog bounds do not decode to the bounds pgpm.part records for it
create function pg_temp.bounds_off(p regclass, p_epoch timestamptz) returns text language sql as $$
  select coalesce(string_agg(format('%s recorded [%s, %s) attached [%s, %s)', q.child_name, q.lo, q.hi, q.cat_lo, q.cat_hi),
                             '; ' order by q.lo::timestamptz), 'none')
    from (select p2.child_name, p2.lo, p2.hi,
                 pg_temp.dec((regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$FROM \('([^']*)'\)$re$))[1], p_epoch) as cat_lo,
                 pg_temp.dec((regexp_match(pg_get_expr(c.relpartbound, c.oid), $re$TO \('([^']*)'\)$re$))[1], p_epoch) as cat_hi
            from pgpm.part p2 join pg_class c on c.oid = p2.child_oid
           where p2.parent_table = p and p2.attached) q
   where q.cat_lo is distinct from q.lo::timestamptz or q.cat_hi is distinct from q.hi::timestamptz $$;
create function pg_temp.nparts(p regclass) returns bigint language sql as $$
  select count(*) from pgpm.part where parent_table = p and attached $$;
create function pg_temp.vals(p regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format('select string_agg(v::text, '','' order by v) from %s', p) into v;
  return v;
end $$;

-- ===================== door 1: transmute refuses a whole-month step on an off-unit epoch =====================
create table public.xr (id text collate "C" primary key, v int);
insert into public.xr select pg_temp.k(date_trunc('month', now()) - make_interval(months => m) + interval '10 days 0.5 s', m), m
  from generate_series(1, 3) m;
select throws_like(
  $$ call pgpm.transmute('public.xr', 'id', interval '2 months', p_obtain => 3, p_anchor => '2000-01-01 00:00:00.5+00',
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_epoch => '1970-01-01 00:00:00.5+00') $$,
  'pg_partition_magician: cannot partition xr on id with step 2 mons -- a whole-month step puts every partition bound at midnight on the 1st whatever the anchor%counts whole seconds from 1970-01-01 00:00:00.5+00, which is not itself a whole second%Give a fixed step%or a p_tt_epoch that is a whole second%',
  'transmute refuses a 2-month step on a seconds encoding whose epoch is half a second off the second, the anchor whole seconds from it');
select is((select c.relkind::text || '/' || (select count(*) from pgpm.config where parent_table = 'public.xr'::regclass)
                  || '/' || pg_temp.vals('public.xr') from pg_class c where c.oid = 'public.xr'::regclass),
  'r/0/1,2,3',
  'LIVENESS: the refusal touched nothing: xr is a plain table, unregistered, holding rows 1, 2 and 3');

create table public.xn (id text collate "C" primary key, v int);
insert into public.xn
  select pgpm._ts_to_text_time(now() - make_interval(days => d), '', 12, 16, 'ms', null, 0, '1970-01-01 00:00:00.0005+00') || 'aa', d
    from generate_series(10, 40, 15) d;
select throws_like(
  $$ call pgpm.transmute('public.xn', 'id', interval '1 month', p_obtain => 3, p_anchor => '2000-01-01 00:00:00.0005+00',
       p_tt_prefix => '', p_tt_width => 12, p_tt_radix => 16, p_tt_unit => 'ms', p_tt_epoch => '1970-01-01 00:00:00.0005+00') $$,
  'pg_partition_magician: cannot partition xn on id with step 1 mon -- a whole-month step%counts whole milliseconds from 1970-01-01 00:00:00.0005+00, which is not itself a whole millisecond%',
  'transmute refuses a 1-month step on a millisecond encoding whose epoch is half a millisecond off, the anchor whole milliseconds from it');
select is((select count(*) from pgpm.config where parent_table = 'public.xn'::regclass), 0::bigint,
  'LIVENESS: xn is not registered');

-- the rule is the epoch's, not "the Unix epoch": a whole-month step on an epoch one second past 1970 converts,
-- and every bound it attaches is the bound it records
create table public.xc (id text collate "C" primary key, v int);
insert into public.xc
  select pgpm._ts_to_text_time(date_trunc('month', now()) - make_interval(months => m) + interval '3 days', '', 8, 16, 's', null, 0,
                               '1970-01-01 00:00:01+00') || lpad(m::text, 4, '0'), m
    from generate_series(1, 4) m;
call pgpm.transmute('public.xc', 'id', interval '2 months', p_obtain => 3,
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_epoch => '1970-01-01 00:00:01+00');
select is((select partition_step || '/' || text_time_epoch from pgpm.config where parent_table = 'public.xc'::regclass),
  '2 mons/1970-01-01 00:00:01+00',
  'LIVENESS: transmute registered xc as a 2-month grid on an epoch that is a whole second (though not 1970-01-01 00:00:00)');
select cmp_ok(pg_temp.nparts('public.xc'), '>=', 3::bigint, 'LIVENESS: xc has at least three attached partitions to compare');
select is(pg_temp.bounds_off('public.xc', '1970-01-01 00:00:01+00'), 'none',
  'every partition of the whole-month grid on the on-unit epoch is attached at exactly the bounds pgpm.part records');

-- ====== door 3: a FIXED grid on the off-unit epoch converts, and its bounds are the anchor plus whole steps ======
-- Rows by the 10-day fine lattice a regrain of its monolith will cut: 1 and 2 mid-cell, 3 and 4 the last whole
-- second of a fine cell, 5 the first, all at x.5 seconds (whole seconds from the epoch, encoded exactly).
create table public.xm (id text collate "C" primary key, v int);
insert into public.xm values
  (pg_temp.k(pg_temp.f10(now() - interval '125 days') + interval '3 days', 1), 1),
  (pg_temp.k(pg_temp.f10(now() - interval '65 days')  + interval '4 days', 2), 2),
  (pg_temp.k(pg_temp.f10(now() - interval '95 days')  - interval '1 second', 3), 3),
  (pg_temp.k(pg_temp.f10(now() - interval '75 days')  - interval '1 second', 4), 4),
  (pg_temp.k(pg_temp.f10(now() - interval '85 days'), 5), 5);
select is((select string_agg(v::text, ',' order by v) from public.xm
            where extract(microseconds from pg_temp.dec(id, '1970-01-01 00:00:00.5+00'))::bigint % 1000000 = 500000
              and (v not in (3, 4) or pg_temp.f10(pg_temp.dec(id, '1970-01-01 00:00:00.5+00') + interval '1 second')
                                 = pg_temp.dec(id, '1970-01-01 00:00:00.5+00') + interval '1 second')
              and (v <> 5 or pg_temp.f10(pg_temp.dec(id, '1970-01-01 00:00:00.5+00')) = pg_temp.dec(id, '1970-01-01 00:00:00.5+00'))),
  '1,2,3,4,5',
  'LIVENESS: every xm key decodes to an instant half a second off the second; 3 and 4 are the last second of a 10-day fine cell, 5 the first');
call pgpm.transmute('public.xm', 'id', interval '90 days', p_obtain => 3, p_anchor => '2000-01-01 00:00:00.5+00',
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_epoch => '1970-01-01 00:00:00.5+00');
select is((select partition_step || '/' || partition_anchor || '/' || text_time_epoch from pgpm.config where parent_table = 'public.xm'::regclass),
  '90 days/2000-01-01 00:00:00.5+00/1970-01-01 00:00:00.5+00',
  'LIVENESS: transmute accepts a fixed 90-day step on the off-unit epoch, the anchor whole seconds from it');
select cmp_ok(pg_temp.nparts('public.xm'), '>=', 3::bigint, 'LIVENESS: xm has at least three attached partitions to compare');
select is(pg_temp.bounds_off('public.xm', '1970-01-01 00:00:00.5+00'), 'none',
  'every partition of the fixed grid on the off-unit epoch is attached at exactly the bounds pgpm.part records');

-- a whole-month target's fine bounds are midnights, off this epoch's seconds: refused; a fixed one is not
select throws_like($$ select pgpm.set_regrain('public.xm', '1 month') $$,
  'pg_partition_magician: regrain target step 1 month for xm is a whole number of months, but its control column id is a text_time key, which encodes whole seconds from 1970-01-01 00:00:00.5+00, which is not itself a whole second%give a fixed step%',
  'set_regrain refuses a 1-month target on the fixed grid whose epoch is off the second');
select throws_like(format($$ select pgpm.regrain_step('public.xm', %L, '1 month') $$,
                          (select child_name from pgpm.part where parent_table = 'public.xm'::regclass order by lo::timestamptz limit 1)),
  'pg_partition_magician: regrain target step 1 month for xm is a whole number of months%',
  'regrain_step refuses the same target before it copies anything');
select lives_ok($$ select pgpm.set_regrain('public.xm', '10 days') $$,
  'LIVENESS: set_regrain accepts a 10-day target on the same fixed grid');
select lives_ok($$ select pgpm.set_regrain('public.xm', null) $$, 'LIVENESS: and turns auto-regrain off again');

-- the 10-day regrain of the monolith: a row past it, so the monolith is frozen
insert into public.xm values (pg_temp.k(pg_temp.f10(now() + interval '40 days') + interval '2 days', 9), 9);
create table public.run (phase text primary key, outcome text);
do $do$
declare v_mono name; s text; i int := 0; n int; r record; t text := '';
begin
  select p.child_name into v_mono from pgpm.part p where p.parent_table = 'public.xm'::regclass order by p.lo::timestamptz limit 1;
  insert into public.run values ('mono', v_mono);
  loop
    s := pgpm.regrain_step('public.xm', v_mono, '10 days', 500); i := i + 1; t := t || s || ' ';
    n := 0;
    for r in select p.child_oid::regclass as rel from pgpm.part p
              where p.parent_table = 'public.xm'::regclass and p.child_name <> v_mono
                and p.child_oid not in (select inhrelid from pg_inherits) loop
      execute format('select %s + (select count(*) from %s where v in (3, 4))', n, r.rel) into n;
    end loop;
    exit when n = 2 or i >= 40 or s like 'swapped%';
  end loop;
  insert into public.run values ('copy', case when n = 2 and s not like 'swapped%' then 'copied' else 'not reached: ' || t end);
end $do$;
select is((select outcome from public.run where phase = 'copy'), 'copied',
  'LIVENESS: the 10-day regrain copied rows 3 and 4 into its fine cells and has not swapped yet');
delete from public.xm where v = 3;
delete from public.xm where v = 4;
select is(pg_temp.vals('public.xm'), '1,2,5,9',
  'LIVENESS: the two DELETEs committed mid-regrain, each in its own statement, and xm reads 1,2,5,9 before the swap');
do $do$
declare v_mono name; s text; i int := 0; t text := '';
begin
  select outcome into v_mono from public.run where phase = 'mono';
  loop
    s := pgpm.regrain_step('public.xm', v_mono, '10 days', 500); i := i + 1; t := t || s || ' ';
    exit when s like 'swapped%' or i >= 40;
  end loop;
  insert into public.run values ('swap', case when s like 'swapped%' then 'swapped' else 'not reached: ' || t end);
end $do$;
select is((select outcome from public.run where phase = 'swap'), 'swapped',
  'LIVENESS: the regrain ran to its swap after the deletes');
select is(pg_temp.vals('public.xm'), '1,2,5,9',
  'rows 3 and 4, deleted while the regrain ran, stay deleted after the swap, and 1, 2, 5 and 9 are all kept');
select is(pg_temp.bounds_off('public.xm', '1970-01-01 00:00:00.5+00'), 'none',
  'every fine cell the swap attached is attached at exactly the bounds pgpm.part records');

-- ===== door 2: a whole-month grid on the off-unit epoch an older install registered is refused any regrain =====
-- Made by transmute itself with the helper answering true (the install before this fix asked nothing), then
-- the helper is restored from its own saved definition, so the rest of the file runs the code under test.
create temp table saved_helper as
  select pg_get_functiondef('pgpm._text_time_epoch_on_unit(text, timestamptz)'::regprocedure) as def;
create or replace function pgpm._text_time_epoch_on_unit(p_unit text, p_epoch timestamptz)
returns boolean language sql stable as $$ select true $$;
create table public.xo (id text collate "C" primary key, v int);
insert into public.xo select pg_temp.k(date_trunc('month', now()) - make_interval(months => m) + interval '10 days 0.5 s', m), m
  from generate_series(1, 4) m;
call pgpm.transmute('public.xo', 'id', interval '2 months', p_obtain => 3, p_anchor => '2000-01-01 00:00:00.5+00',
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_epoch => '1970-01-01 00:00:00.5+00');
do $$ begin execute (select def from saved_helper); end $$;
select is(pg_get_functiondef('pgpm._text_time_epoch_on_unit(text, timestamptz)'::regprocedure), (select def from saved_helper),
  'LIVENESS: the helper under test is restored to its own definition after the older-install conversion');
select is((select partition_step || '/' || partition_anchor || '/' || text_time_epoch from pgpm.config where parent_table = 'public.xo'::regclass),
  '2 mons/2000-01-01 00:00:00.5+00/1970-01-01 00:00:00.5+00',
  'LIVENESS: xo is registered as a 2-month grid on the off-unit epoch, as an install before this fix registered it');
select isnt(pg_temp.bounds_off('public.xo', '1970-01-01 00:00:00.5+00'), 'none',
  'LIVENESS: and its catalog bounds are the floored ones, half a second below the midnights pgpm.part records');
select throws_like($$ select pgpm.set_regrain('public.xo', '1 day') $$,
  'pg_partition_magician: cannot regrain xo -- its grid is not on its control column id''s encoded unit: it is a text_time key, which encodes whole seconds from 1970-01-01 00:00:00.5+00, which is not itself a whole second, and its registered partition_step 2 mons is a whole number of months%Re-convert the table%pgpm.untransmute(''xo'')%a fixed step%',
  'set_regrain refuses a 1-day target on the registered whole-month grid whose epoch is off the second, naming the reconversion');
select throws_like($$ select pgpm.set_regrain('public.xo', '1 month') $$,
  'pg_partition_magician: cannot regrain xo -- its grid is not on its control column id''s encoded unit%',
  'set_regrain refuses a 1-month target on it too');
select throws_like($$ select pgpm.regrain_step('public.xo', 'xo_any', '1 month') $$,
  'pg_partition_magician: cannot regrain xo -- its grid is not on its control column id''s encoded unit%',
  'regrain_step refuses it before it looks for the child, so a run resumed across the upgrade is refused as a fresh one is');
select is((select coalesce(regrain_to, 'null') from pgpm.config where parent_table = 'public.xo'::regclass), 'null',
  'the refused calls stored no target for xo');
-- the remedy, as the refusal types it: untransmute while every row is in the monolith, then a fixed step
select pgpm.untransmute('xo');
select is((select c.relkind::text || '/' || (select count(*) from pgpm.config where parent_table = 'public.xo'::regclass)
                  || '/' || pg_temp.vals('public.xo') from pg_class c where c.oid = 'public.xo'::regclass),
  'r/0/1,2,3,4',
  'LIVENESS: untransmute(''xo''), as the refusal types it, handed xo back a plain unregistered table holding rows 1 to 4');
call pgpm.transmute('public.xo', 'id', interval '30 days', p_obtain => 3, p_anchor => '2000-01-01 00:00:00.5+00',
       p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's', p_tt_epoch => '1970-01-01 00:00:00.5+00');
select is((select partition_step || '/' || pg_temp.vals('public.xo') || '/' || pg_temp.bounds_off('public.xo', '1970-01-01 00:00:00.5+00')
             from pgpm.config where parent_table = 'public.xo'::regclass),
  '30 days/1,2,3,4/none',
  'the remedy works as typed: xo is re-converted to a fixed 30-day grid holding rows 1 to 4, every bound attached where it is recorded');

select * from finish();
