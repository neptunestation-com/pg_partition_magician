-- The shared preflight's refusal conformance suite, resume half (issue #952 bullet 2; lever phase #966).
--
-- A resume reuses the bound an earlier attempt recorded with its claim, and skips phase 1 (the CHECK is
-- there) and phase 2 (once it validates). The install that recorded the bound may not have refused what this
-- one refuses: a pre-#922 install read a NaN maximum straight into the frontier and recorded hi = NaN with a
-- NOT VALID pgpm_monolith_bound CHECK (id < 'NaN'), phase 2's VALIDATE then failed on the NaN row, and after
-- the upgrade and the row's deletion the re-run took the claim over, validated that CHECK and completed a
-- monolith [0, NaN), which takes every future id: obtain, retention and regrain never act on the table again.
-- A claim recorded before the control-type contract can likewise carry a hi its column cannot hold, and the
-- resume died raw in the cutover's ATTACH on every retry. The resume now asks the same contract of the
-- recorded bound that a fresh bound passes (pgpm._control_bound_contract), still in the first transaction,
-- so the raise rolls the take-over back and leaves the claim for transmute_abort.
--
-- MODELLING THE UPGRADED STATE. The pre-#922 state is built by hand here, as bench/upgrade_in_place.sh
-- builds an older state by degrading a fresh one: the claim row exactly as the old install wrote it (lo 0,
-- hi NaN, owned by a session that has gone) and its NOT VALID CHECK. The verifier's reproduction (A952-2)
-- builds the same state from the real pre-#922 install out of git history, and records hi = NaN and the
-- CHECK `id >= '0' AND id < 'NaN'` there; part A's LIVENESS lines assert this file reached that state.
--
-- INSTRUMENT. transmute runs through dblink, top-level, so a resume that is NOT refused really commits its
-- monolith; the claim is taken by a second dblink session that then disconnects, so its owner is gone, as
-- the old install's psql session was. Asymmetric: part C resumes a finite, representable claim and converts
-- on exactly the recorded bound, so a resume refused whatever it recorded could not pass.
-- bench/shared_preflight_conformance.sh runs this file against the mutants.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(17);

select dblink_connect('t269', 'dbname=' || current_database());

-- a claim recorded by a session that has since gone, with the CHECK its phase 1 committed (NOT VALID)
create function pg_temp.t269_claim(p_rel regclass, p_col name, p_lo text, p_hi text) returns void
language plpgsql as $$
declare v_pid int; v_start timestamptz;
begin
  perform dblink_connect('t269_owner', 'dbname=' || current_database());
  select pid, backend_start into v_pid, v_start
    from dblink('t269_owner', 'select pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid())')
      as t(pid int, backend_start timestamptz);
  perform dblink_disconnect('t269_owner');
  insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi, partition_tz,
                                       control_attnum, owner_pid, owner_backend_start)
  select p_rel, n.nspname, c.relname, 'id', p_lo, p_hi, 'UTC',
         (select attnum from pg_attribute where attrelid = p_rel and attname = p_col), v_pid, v_start
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_rel;
  execute format('alter table %s add constraint pgpm_monolith_bound check (%I >= %L and %I < %L) not valid',
                 p_rel, p_col, p_lo, p_col, p_hi);
end $$;
-- the owner's backend exits asynchronously after the disconnect; wait until it is gone. The budget is
-- 30 s (600 polls of 50 ms): the files run four at a time (test.sh's PGPM_JOBS), and on one loaded
-- PostgreSQL 18 run a backend took longer than the 5 s this used to allow to leave pg_stat_activity.
-- The owner is the (pid, backend_start) pair the claim recorded, not the pid alone, so a reused pid
-- can never hold the wait up or end it early.
create function pg_temp.t269_owner_gone(p_rel regclass) returns boolean language plpgsql as $$
declare i int := 0;
begin
  while i < 600 and exists (select 1 from pgpm.transmute_inflight t join pg_stat_activity a
                             on a.pid = t.owner_pid and a.backend_start = t.owner_backend_start
                             where t.parent_table = p_rel) loop
    perform pg_sleep(0.05); i := i + 1;
  end loop;
  return not exists (select 1 from pgpm.transmute_inflight t join pg_stat_activity a
                      on a.pid = t.owner_pid and a.backend_start = t.owner_backend_start
                      where t.parent_table = p_rel);
end $$;
create function pg_temp.t269_state(p_rel regclass) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_rel),
    'config:' || exists (select 1 from pgpm.config where parent_table = p_rel),
    'claim:' || coalesce((select '[' || lo || ', ' || hi || ')' from pgpm.transmute_inflight where parent_table = p_rel), 'none'),
    'bound:' || coalesce((select pg_get_constraintdef(oid) || case when convalidated then ' (validated)' else '' end
                            from pg_constraint where conrelid = p_rel and conname = 'pgpm_monolith_bound'), 'none'),
    'partitions:' || coalesce((select string_agg(pg_get_expr(c.relpartbound, c.oid), ', ')
                                 from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = p_rel), 'none'))
$$;

-- ======================================================================================================
-- A. A claim with hi = NaN, as a pre-#922 install left it, is not resumed into [0, NaN)
-- ======================================================================================================
create table public.t269a (id numeric primary key, v text);
insert into public.t269a select g, 'x' from generate_series(1, 50) g;
select pg_temp.t269_claim('public.t269a', 'id', '0', 'NaN');
select ok(pg_temp.t269_owner_gone('public.t269a'), 'A LIVENESS: the session that recorded the claim is gone');
select is(pg_temp.t269_state('public.t269a'),
  'r | config:false | claim:[0, NaN) | bound:CHECK (((id >= ''0''::numeric) AND (id < ''NaN''::numeric))) NOT VALID | partitions:none',
  'A LIVENESS: the pre-#922 state: a claim [0, NaN) and its NOT VALID CHECK, the NaN row already deleted');
select is((select count(*)::int from public.t269a where id >= 0 and id < 'NaN'), 50,
  'A LIVENESS: every row satisfies that CHECK, so a resume would validate it and go on to the cutover');
select throws_like(
  $$ select dblink_exec('t269', $c$ call pgpm.transmute('public.t269a', 'id', 100::bigint) $c$) $$,
  'pg_partition_magician: cannot resume the transmute of t269a on id: the bound [0, NaN) an earlier attempt recorded%NaN is not finite%pgpm.transmute_abort(t269a)%',
  'A: the resume refuses the recorded non-finite bound, naming it and the remedy');
select is(pg_temp.t269_state('public.t269a'),
  'r | config:false | claim:[0, NaN) | bound:CHECK (((id >= ''0''::numeric) AND (id < ''NaN''::numeric))) NOT VALID | partitions:none',
  'A: refused before anything committed: no monolith, no registration, the claim and its CHECK as they were');
select ok(pgpm.transmute_abort('public.t269a'), 'A: the remedy the refusal names, transmute_abort, clears the claim');
select lives_ok(
  $$ select dblink_exec('t269', $c$ call pgpm.transmute('public.t269a', 'id', 100::bigint) $c$) $$,
  'A LIVENESS: and the re-run converts the same table on a fresh bound');
select is((select string_agg(pg_get_expr(c.relpartbound, c.oid), ', ') from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t269a'::regclass
              and c.oid = (select monolith_oid from pgpm.config where parent_table = 'public.t269a'::regclass)),
  'FOR VALUES FROM (''0'') TO (''100'')', 'A: whose monolith is [0, 100), finite');

-- ======================================================================================================
-- B. A recorded hi the column cannot hold (numeric(4,0), hi 10000) is not resumed into the cutover
-- ======================================================================================================
create table public.t269b (id numeric(4,0) primary key, v text);
insert into public.t269b select g * 5, 'x' from generate_series(1, 1999) g;   -- max 9995
select pg_temp.t269_claim('public.t269b', 'id', '0', '10000');
select ok(pg_temp.t269_owner_gone('public.t269b'), 'B LIVENESS: the session that recorded the claim is gone');
select throws_ok($$ select 10000::numeric(4,0) $$, '22003', NULL,
  'B LIVENESS: the recorded hi, 10000, cannot be stored in numeric(4,0)');
select throws_like(
  $$ select dblink_exec('t269', $c$ call pgpm.transmute('public.t269b', 'id', 10::bigint) $c$) $$,
  'pg_partition_magician: cannot resume the transmute of t269b on id: the bound [0, 10000) an earlier attempt recorded%numeric(4,0)%10000 cannot be stored in it at all%',
  'B: the resume refuses the recorded bound the column cannot hold');
select is(pg_temp.t269_state('public.t269b'),
  'r | config:false | claim:[0, 10000) | bound:CHECK (((id >= ''0''::numeric) AND (id < ''10000''::numeric))) NOT VALID | partitions:none',
  'B: refused before anything committed: phase 2 did not validate the CHECK, nothing was registered');

-- ======================================================================================================
-- C. A finite, representable claim resumes, on exactly the recorded bound
-- ======================================================================================================
create table public.t269c (id bigint primary key, v text);
insert into public.t269c select g, 'x' from generate_series(1, 30) g;
select pg_temp.t269_claim('public.t269c', 'id', '0', '200');   -- wider than a fresh bound [0, 40) would be
select ok(pg_temp.t269_owner_gone('public.t269c'), 'C LIVENESS: the session that recorded the claim is gone');
select lives_ok(
  $$ select dblink_exec('t269', $c$ call pgpm.transmute('public.t269c', 'id', 10::bigint) $c$) $$,
  'C: a resume of a finite claim the column can hold goes ahead');
select is((select string_agg(pg_get_expr(c.relpartbound, c.oid), ', ') from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t269c'::regclass
              and c.oid = (select monolith_oid from pgpm.config where parent_table = 'public.t269c'::regclass)),
  'FOR VALUES FROM (''0'') TO (''200'')', 'C: and attaches the monolith on the RECORDED bound [0, 200), not a fresh one');
select is((select string_agg(id::text, ',' order by id) from public.t269c where id in (1, 15, 30)), '1,15,30',
  'C: with the rows in place');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t269c'::regclass),
  'C: and the claim is gone');

select dblink_disconnect('t269');
select * from finish();
