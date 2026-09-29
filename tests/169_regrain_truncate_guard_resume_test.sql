-- A resumed regrain puts the #449 TRUNCATE guard back on its source (issue #650).
--
-- The guard (tests/119) was installed by the prepare tick alone, and regrain_step skips prepare whenever
-- the capture row trigger is present. So a source that carries capture but no guard stayed unguarded for
-- the rest of its regrain: a regrain begun under 0.6.0 (whose prepare installed no guard, #449 being
-- unreleased) and resumed after the upgrade, or a guard dropped by hand mid-regrain. A TRUNCATE of the
-- source then went through, the delta saw nothing, and the swap attached copies of every truncated row.
--
-- Two levers close it, and this file covers the one a single session can reach: every tick that resumes
-- (capture present, so no prepare) installs the guard when it is missing. The other lever, install.sql's
-- upgrade path putting the guard on every in-flight source before any tick runs, needs install.sql re-run
-- over a live database, which no pgTAP file can do; bench/regrain_truncate_guard_upgrade.sh covers it.
--
-- The 0.6.0 state is reproduced exactly: what 0.6.0's prepare left on the source is the capture trigger
-- and no guard, so the guard is dropped after a real prepare. Every assertion that the guard is back is
-- preceded by the witness that it was gone and that the tick was a resume, not a re-prepare.
create extension if not exists pgtap;
select plan(23);

-- a PROCEDURE, not a function: it calls transmute, which commits
create or replace procedure pg_temp.mk(p_rel text) language plpgsql as $$
begin
  execute format('create table public.%I (id bigint primary key, payload text)', p_rel);
  execute format('insert into public.%I select g*10, ''x'' from generate_series(1, 250) g', p_rel);
  call pgpm.transmute(format('public.%I', p_rel)::regclass, 'id', 1000);
  execute format('insert into public.%I values (20000, ''frontier'')', p_rel);   -- sentinel past hi: frozen
end $$;

call pg_temp.mk('tgr');
\set src tgr_p0000000000000000000_to_0000000000000003000

-- ======================= (A) the resume tick puts a missing guard back =======================
select is(pgpm.regrain_step('public.tgr', :'src', '100', 50), 'prepared', 'tick 1 installs capture (prepared)');
select is(pgpm.regrain_step('public.tgr', :'src', '100', 50), 'copied:9', 'tick 2 copies [0, 100): the nine rows 10..90');

-- what 0.6.0's prepare tick left: the capture trigger, and no TRUNCATE guard
drop trigger pgpm_regrain_truncate_guard on public.tgr_p0000000000000000000_to_0000000000000003000;
select is(
  (select string_agg(tgname::text, ',' order by tgname) from pg_trigger
    where tgrelid = 'public.tgr_p0000000000000000000_to_0000000000000003000'::regclass and tgname like 'pgpm_regrain%'),
  'pgpm_regrain_capture', 'WITNESS: the source carries capture and no guard, as 0.6.0 left it');
select ok(pgpm._regrain_capture_active('public.tgr', :'src'),
  'WITNESS: capture is active, so the next tick resumes rather than prepares');
select is((select count(*)::int from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'), 0,
  'WITNESS: no guard anywhere in the database before the resume tick');

select is(pgpm.regrain_step('public.tgr', :'src', '100', 50), 'copied:10',
  'tick 3 RESUMES: it copies [100, 200), the ten rows 100..190, rather than re-preparing');
select is((select count(*)::int from pgpm.log where parent_table = 'public.tgr'::regclass and action = 'regrain_restart'), 0,
  'WITNESS: the resume discarded nothing (no regrain_restart row)');
select is((select array_agg(id order by id) from public.tgr_p0000000000000000000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 9) g),
  'WITNESS: the first copy still holds ids 10..90, so there are copied rows a swap would resurrect');

select is(
  (select pg_get_triggerdef(t.oid) from pg_trigger t
    where t.tgrelid = 'public.tgr_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'CREATE TRIGGER pgpm_regrain_truncate_guard BEFORE TRUNCATE ON public.tgr_p0000000000000000000_to_0000000000000003000 FOR EACH STATEMENT EXECUTE FUNCTION pgpm._regrain_truncate_guard()',
  'the resume tick put the BEFORE TRUNCATE statement trigger back on the source');
select is(
  (select t.tgenabled from pg_trigger t
    where t.tgrelid = 'public.tgr_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  'A', 'and it is ENABLE ALWAYS, as the prepare tick installs it');
select is(
  (select array_agg(tgrelid::regclass::text) from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'),
  array['tgr_p0000000000000000000_to_0000000000000003000'],
  'on the in-flight source and nowhere else (not on the copies, not on the forward partition)');

select throws_like(
  $$ truncate public.tgr_p0000000000000000000_to_0000000000000003000 $$,
  'pg_partition_magician: cannot TRUNCATE public.tgr_p0000000000000000000_to_0000000000000003000 -- a regrain is in flight on it%pgpm.regrain_cancel(%tgr)%',
  'TRUNCATE of the resumed source is refused');
select throws_like(
  $$ truncate public.tgr $$,
  'pg_partition_magician: cannot TRUNCATE public.tgr_p0000000000000000000_to_0000000000000003000 -- a regrain is in flight on it%',
  'and so is TRUNCATE parent, which cascades to it');
select is((select array_agg(id order by id) from public.tgr_p0000000000000000000_to_0000000000000003000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 250) g),
  'nothing was truncated: the source still holds ids 10..2500');

-- ======================= (B) a steady tick issues no DDL =======================
-- The guard is put back only when it is missing. A tick that dropped and re-created it every time would
-- take SHARE ROW EXCLUSIVE on the source every tick; the oid staying put is what tells the two apart.
select t.oid as guard_oid from pg_trigger t
 where t.tgrelid = 'public.tgr_p0000000000000000000_to_0000000000000003000'::regclass
   and t.tgname = 'pgpm_regrain_truncate_guard' \gset
select is(pgpm.regrain_step('public.tgr', :'src', '100', 50), 'copied:10',
  'tick 4 copies [200, 300), the ten rows 200..290');
select is(
  (select t.oid from pg_trigger t
    where t.tgrelid = 'public.tgr_p0000000000000000000_to_0000000000000003000'::regclass
      and t.tgname = 'pgpm_regrain_truncate_guard'),
  :'guard_oid'::oid, 'the guard present at tick 4 is the same trigger (same oid): a present guard is left alone');

-- ======================= (C) a write the capture DOES see still reconciles; the swap loses nothing =======================
-- Asymmetric on purpose: two rows deleted from a copied sub-range, one updated in it, so a lost delete and
-- a resurrected one cannot cancel into a plausible total.
delete from public.tgr where id in (20, 150);
update public.tgr set payload = 'upd' where id = 110;

do $$ declare s text; n int := 0; begin
  loop s := pgpm.regrain_step('public.tgr', 'tgr_p0000000000000000000_to_0000000000000003000', '100', 50);
    exit when s like 'swapped:%'; n := n + 1; if n > 500 then raise exception 'no convergence'; end if; end loop;
end $$;

select is(
  (select count(*)::int from pgpm.log where parent_table = 'public.tgr'::regclass
     and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'WITNESS: the swap ran (one regrain / copy_swap_drop row)');
select is((select array_agg(id order by id) from public.tgr where id < 3000),
  (select array_agg((g*10)::bigint order by g) from generate_series(1, 250) g where g not in (2, 15)),
  'after the swap the parent holds ids 10..2500 less exactly the two deleted (20, 150)');
select is((select payload from public.tgr where id = 110), 'upd', 'and the update of id 110 survived the swap');
select is((select string_agg(payload, ',' order by id) from public.tgr where id in (100, 120)), 'x,x',
  'and its neighbours kept their original payload');
select is((select count(*)::int from pg_trigger where tgname = 'pgpm_regrain_truncate_guard'), 0,
  'the swap took the re-installed guard with the dropped source: none remains anywhere');
select lives_ok($$ truncate public.tgr $$, 'so TRUNCATE parent succeeds after the swap');
select ok(not exists (select 1 from public.tgr), 'and it truncated: the parent is empty');

select * from finish();
