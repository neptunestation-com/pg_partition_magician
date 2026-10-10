-- untransmute refuses every object its DROP of the parent would fail on, not only the views and rules over
-- the parent's pg_class row (issue #831, and #815's bullet F10-06).
--
-- #779 made untransmute refuse an object created over the PARENT since the conversion, because the reverse
-- drops the parent. It asked pg_depend about the parent's pg_class row alone. Two kinds of dependant the
-- DROP meets were never asked about, and each made the reverse die raw with 2BP01 ("cannot drop table ...
-- because other objects depend on it"), the failure the refusal exists to replace:
--   * a function or a column typed by the parent's ROW TYPE (its pg_type, or that type's array type),
--     created since the conversion (#831);
--   * a view, a BEGIN ATOMIC function or a function typed by a row type, over one of the empty forward
--     partitions (or an operator's DEFAULT partition) that the DROP cascades to (F10-06).
--
-- Fixtures, asymmetric on purpose:
--   (A) ut223, converted, then two functions and a column typed by the parent's row type (one by its array
--       type), and two objects over the MONOLITH partition (a function typed by its row type, a view) that
--       must NOT be named: the monolith is the original table, detached and handed back, not dropped. The
--       refusal names exactly the three; nothing changes; with the three dropped the reverse runs, and the
--       monolith's function and view work on the restored table's rows.
--   (B) fv223, converted with two forward partitions and an operator's DEFAULT partition, then a view over
--       the first forward partition, a function typed by the second's row type and a view over the DEFAULT,
--       which must be named, and a rule ON the first forward partition and a view over the monolith, which
--       must not (the rule goes with its partition, which the DROP takes without error). The refusal names
--       exactly the three; every partition is still attached; with them dropped the reverse runs.
-- Each refusal is pinned by its message (throws_like). bench/untransmute_drop_dependants.sh runs this file
-- against the mutations that put each defect back (bench/mutations/mutate.py), so it is also required to
-- FAIL there.
create extension if not exists pgtap;
select plan(21);

set client_min_messages = warning;

-- ====================================================================================================
-- (A) dependants of the parent's row type, and not of the monolith's
-- ====================================================================================================
create table public.ut223 (id bigint, ts timestamptz not null, primary key (id, ts));
insert into public.ut223 values (1, now() - interval '1 hour'), (2, now() - interval '2 hours');
call pgpm.transmute('public.ut223', 'ts', interval '1 day', p_obtain => 2);
select monolith_oid::regclass::text as ut_mono from pgpm.config where parent_table = 'public.ut223'::regclass \gset
create function public.row223(r public.ut223) returns bigint language sql as 'select r.id';
create function public.arr223(r public.ut223[]) returns int language sql as 'select cardinality(r)';
create table public.audit223 (r public.ut223);
-- and the two that are not refused: they are bound to the monolith, the original table handed back
create function public.mono223(r :ut_mono) returns bigint language sql as 'select r.id * 10';
create view public.ut223_mono_v as select id from :ut_mono;

select is((select array_agg(public.row223(x) order by 1) from public.ut223 x), array[1, 2]::bigint[],
  'LIVENESS: (A) row223 takes the managed table''s rows (ids 1 and 2)');
select ok(exists (select 1 from pg_depend d join pg_type ty on ty.oid = d.refobjid
                   where d.refclassid = 'pg_type'::regclass and ty.typrelid = 'public.ut223'::regclass
                     and d.classid = 'pg_proc'::regclass and d.objid = 'public.row223(public.ut223)'::regprocedure)
          and not exists (select 1 from pg_depend d where d.refclassid = 'pg_class'::regclass
                     and d.refobjid = 'public.ut223'::regclass and d.classid = 'pg_proc'::regclass),
  'LIVENESS: (A) row223 depends on the parent''s row type, and nothing in pg_proc on its pg_class row');
select throws_like($$ select pgpm.untransmute('public.ut223') $$,
  'pg_partition_magician: cannot untransmute ut223 -- the object(s) (column audit223.r, function arr223(ut223[]), function row223(ut223)) name the partitioned table by its oid,%',
  'A: untransmute refuses the two functions and the column typed by the parent''s row type, naming exactly those');
select is((select relkind::text from pg_class where oid = 'public.ut223'::regclass), 'p', 'A: ut223 is still partitioned');
select ok(exists (select 1 from pgpm.config where parent_table = 'public.ut223'::regclass), 'A: and still managed');
select is((select array_agg(public.row223(x) order by 1) from public.ut223 x), array[1, 2]::bigint[],
  'A: row223 still takes the managed table''s rows');
drop function public.row223(public.ut223);
drop function public.arr223(public.ut223[]);
drop table public.audit223;
select lives_ok($$ select pgpm.untransmute('public.ut223') $$,
  'LIVENESS: (A) with the three gone, untransmute reverses ut223 (the monolith''s function and view did not stop it)');
select is((select relkind::text from pg_class where oid = 'public.ut223'::regclass), 'r', 'LIVENESS: (A) ut223 is the plain table again');
select is((select array_agg(public.mono223(x) order by 1) from public.ut223 x), array[10, 20]::bigint[],
  'A: the monolith''s function takes the restored table''s rows');
select is((select array_agg(id order by id) from public.ut223_mono_v), array[1, 2]::bigint[],
  'A: the view over the monolith reads the restored table');

-- ====================================================================================================
-- (B) dependants of the partitions the DROP cascades to, and not of the monolith's or a partition's own
-- ====================================================================================================
create table public.fv223 (id bigint primary key, v text);
insert into public.fv223 select g, 'x' || g from generate_series(1, 10) g;   -- step 100: monolith [0, 100)
create table public.log223 (id bigint);   -- the rule's target
call pgpm.transmute('public.fv223', 'id', 100::bigint, p_obtain => 2);
select pgpm.obtain('public.fv223');
create table public.fv223_def partition of public.fv223 default;
create view public.fv223_fwd_v as select id from public.fv223_p0000000000000000100;
create function public.fwdrow223(r public.fv223_p0000000000000000200) returns bigint language sql as 'select r.id';
create view public.fv223_def_v as select id from public.fv223_def;
-- and the two that are not refused
create rule fv223_fwd_r as on insert to public.fv223_p0000000000000000100 do also insert into public.log223 values (new.id);
create view public.fv223_mono_v as select id from public.fv223_p0000000000000000000;

select is((select string_agg(c.relname || ':' || (select count(*) from pg_inherits i where i.inhrelid = c.oid
                                                    and i.inhparent = 'public.fv223'::regclass)::text, ' ' order by c.relname)
             from pg_class c where c.relname in ('fv223_p0000000000000000100', 'fv223_p0000000000000000200', 'fv223_def')
              and c.relnamespace = 'public'::regnamespace),
  'fv223_def:1 fv223_p0000000000000000100:1 fv223_p0000000000000000200:1',
  'LIVENESS: (B) two forward partitions and the DEFAULT are attached to fv223, so the DROP would cascade to them');
select is((select count(*)::int from public.fv223 where tableoid <> (select monolith_oid from pgpm.config
                                                                   where parent_table = 'public.fv223'::regclass)),
  0, 'LIVENESS: (B) every row is in the monolith, so the reverse''s gate is open');
select ok(exists (select 1 from pg_rewrite where rulename = 'fv223_fwd_r'
                   and ev_class = 'public.fv223_p0000000000000000100'::regclass),
  'LIVENESS: (B) the rule sits on the first forward partition itself');
select throws_like($$ select pgpm.untransmute('public.fv223') $$,
  'pg_partition_magician: cannot untransmute fv223 -- the object(s) (function fwdrow223(fv223_p0000000000000000200), view fv223_def_v, view fv223_fwd_v) name the partitioned table by its oid,%',
  'B: untransmute refuses the objects over the partitions its DROP takes, naming exactly those three');
select is((select relkind::text from pg_class where oid = 'public.fv223'::regclass), 'p', 'B: fv223 is still partitioned');
select is((select count(*)::int from pg_inherits where inhparent = 'public.fv223'::regclass), 4,
  'B: the monolith, both forward partitions and the DEFAULT are all still attached (the DETACH did not stand)');
drop view public.fv223_fwd_v;
drop function public.fwdrow223(public.fv223_p0000000000000000200);
drop view public.fv223_def_v;
select lives_ok($$ select pgpm.untransmute('public.fv223') $$,
  'LIVENESS: (B) with the three gone, untransmute reverses fv223 (the partition''s own rule and the monolith''s view did not stop it)');
select is((select relkind::text from pg_class where oid = 'public.fv223'::regclass), 'r', 'LIVENESS: (B) fv223 is the plain table again');
select is(to_regclass('public.fv223_p0000000000000000100'), null, 'B: the forward partition went with the DROP, its rule with it');
select is((select array_agg(id order by id) from public.fv223_mono_v), array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]::bigint[],
  'B: the view over the monolith reads the restored table, every row');
select is((select array_agg(id order by id) from public.fv223), array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]::bigint[], 'B: the rows are intact');

select * from finish();
