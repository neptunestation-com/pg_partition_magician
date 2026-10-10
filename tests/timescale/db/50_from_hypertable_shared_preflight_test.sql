-- The shared preflight's refusal conformance suite, hypertable half (issues #951, #959; lever phase #966).
-- tests/268 is the core half (transmute) and tests/269 the resume path's.
--
-- THE INVARIANT. A refusal the core makes before anything commits is made by one preflight that every
-- converting entry point calls before its first commit. from_hypertable hands the plain table to transmute
-- only AFTER its swap has committed and dropped the hypertable, so a refusal transmute makes there comes too
-- late: the table is left an unmanaged plain table with its incoming keys dropped. Two kinds got through:
--   A. A null argument (#951 bullet 2). No from_hypertable* routine refused one. p_paused => null reached
--      transmute's null check only after the swap; p_lock_timeout => null reset lock_timeout to 0, so the
--      swap's ACCESS EXCLUSIVE wait was unbounded.
--   B. A NOT VALID incoming key (#959 bullet 1). from_hypertable_preflight never read convalidated, the swap
--      dropped and recorded the key, and the handoff re-added and validated it: a clean key the operator left
--      NOT VALID was silently promoted, and one over tolerated orphans failed validation every tick for good.
--      transmute's gate (#902) never saw it, since transmute only meets the plain table after the swap.
-- Both are now refused by the core's own checks, called at the top of each routine: pgpm._refuse_null_arguments,
-- and pgpm._refuse_unconvertible_keys in the preflight (so before the copy) and in the cutover under its lock.
-- (The control-type contract of tests/268 part B does not arise here: the dimension is a timestamp, checked by
-- _from_hypertable_check_dimension. A NOT ENFORCED key needs PostgreSQL 18, and this track runs 15; tests/268
-- covers it on the core track's 18.)
--
-- EXHAUSTIVENESS. Part A enumerates every pgpm routine named from_hypertable* from pg_proc at test time and
-- calls each with null in each argument position, as tests/268 part A does for the core, requiring pgpm's
-- own refusal naming exactly that argument. The arguments whose null is documented are the case table, with
-- the reference.md section documenting each; they must not be refused, and an entry naming no real argument
-- fails. A planted control schema proves the verdict can fail.
--
-- REFUSED BEFORE ANY COMMIT. Each refusal is pinned by its message (throws_like): every procedure here
-- commits, and one that does NOT refuse dies at its first COMMIT inside throws_like with 2D000 and rolls back
-- into the state a refusal leaves, so the message is what separates the two (tests/timescale/db/24 explains).
-- The state after each is asserted by identity: still a hypertable, its rows, its keys and their validity,
-- whether a copy was made, no pgpm.config row and nothing in pgpm.dropped_fk. Asymmetric controls migrate the
-- same tables once the one condition is gone. bench/hypertable_shared_preflight.sh runs this file against the
-- mutants (bench/mutations/mutate.py).
select plan(21);

-- ======================================================================================================
-- The sweep's instrument (tests/268's, over the module's routines)
-- ======================================================================================================
create table public.t50_sweep (id bigint primary key, ts timestamptz not null default now());
insert into public.t50_sweep values (1), (2);

create function pg_temp.t50_sample(p_type oid) returns text language plpgsql as $$
begin
  return case p_type
    when 'regclass'::regtype    then quote_literal('public.t50_sweep') || '::regclass'
    when 'name'::regtype        then quote_literal('ts') || '::name'
    when 'text'::regtype        then quote_literal('1') || '::text'
    when 'integer'::regtype     then '1::integer'
    when 'bigint'::regtype      then '1::bigint'
    when 'numeric'::regtype     then '1::numeric'
    when 'boolean'::regtype     then 'false'
    when 'interval'::regtype    then quote_literal('1 day') || '::interval'
    when 'timestamptz'::regtype then 'now()'
  end;
end $$;

create function pg_temp.t50_sweep(p_nsp name, p_pattern text)
returns table (routine text, arg text, state text, msg text) language plpgsql as $$
declare
  r record; v_names text[]; v_types oid[]; v_n int; v_args text[]; v_call text; i int; j int; v_sample text;
begin
  for r in select p.oid, p.proname::text as proname, p.prokind, p.pronargs, p.pronargdefaults,
                  p.proargnames, p.proargmodes, p.proallargtypes,
                  string_to_array(p.proargtypes::text, ' ')::oid[] as intypes   -- oidvector is 0-based
             from pg_proc p
            where p.pronamespace = p_nsp::regnamespace and p.proname ~ p_pattern
            order by p.proname, p.oid loop
    if r.proargmodes is null then
      v_names := r.proargnames[1:r.pronargs];
      v_types := r.intypes;
    else
      select array_agg(r.proargnames[k] order by k), array_agg(r.proallargtypes[k] order by k)
        into v_names, v_types
        from generate_subscripts(r.proargmodes, 1) k
       where r.proargmodes[k] in ('i', 'b', 'v');
    end if;
    v_n := coalesce(array_length(v_types, 1), 0);
    for i in 1 .. v_n loop
      v_args := '{}';
      for j in 1 .. v_n loop
        if j = i then
          v_args := v_args || format('%I => null::%s', v_names[j], format_type(v_types[j], null));
        elsif j <= v_n - r.pronargdefaults then
          v_sample := pg_temp.t50_sample(v_types[j]);
          if v_sample is null then
            raise exception 't50 sweep: no sample for %.% argument % of type %',
              p_nsp, r.proname, v_names[j], format_type(v_types[j], null);
          end if;
          v_args := v_args || format('%I => %s', v_names[j], v_sample);
        end if;
      end loop;
      v_call := format(case when r.prokind = 'p' then 'call %I.%I(%s)' else 'select %I.%I(%s)' end,
                       p_nsp, r.proname, array_to_string(v_args, ', '));
      routine := r.proname; arg := v_names[i];
      begin
        execute v_call;
        state := '00000'; msg := null;
      exception when others then
        get stacked diagnostics state = returned_sqlstate, msg = message_text;
      end;
      return next;
    end loop;
  end loop;
end $$;

create function pg_temp.t50_refused(p_routine text, p_arg text, p_state text, p_msg text)
returns boolean language sql immutable as $$
  select coalesce(p_state = 'P0001'
                  and starts_with(p_msg, 'pg_partition_magician: ' || p_routine || ' does not accept null for ' || p_arg || ':'),
                  false)
$$;

create temp table t50_documented (routine text, arg text, documented text);
insert into t50_documented values
  ('from_hypertable', 'p_retain', '#from_hypertable: when p_retain is left null, the drop_chunks policy interval is carried in'),
  ('from_hypertable_cutover', 'p_retain', '#from_hypertable: when p_retain is left null, the drop_chunks policy interval is carried in'),
  ('from_hypertable_drain_appends_step', 'p_watermark', '#from_hypertable_drain_appends: _step reads a NULL p_watermark the same way'),
  ('from_hypertable_time_estimate', 'p_copy_mibps', '#from_hypertable_time_estimate: when null it is derived');

create temp table t50_swept as select * from pg_temp.t50_sweep('pgpm', '^from_hypertable');

-- the state of a migration's source, by identity
create function pg_temp.t50_state(p_name text) returns text language sql as $$
  select concat_ws(' | ',
    case when exists (select 1 from timescaledb_information.hypertables
                       where format('%I.%I', hypertable_schema, hypertable_name) = p_name)
         then 'hypertable' else (select relkind::text from pg_class where oid = to_regclass(p_name)) end,
    'copy:' || (to_regclass(p_name || '_pgpm_dest') is not null),
    'config:' || exists (select 1 from pgpm.config where parent_table = to_regclass(p_name)),
    'dropped_fk:' || (select count(*) from pgpm.dropped_fk   -- the records naming this source's keys
                        where constraint_name ~ ('^' || split_part(p_name, '.', 2) || '_')))
$$;
create function pg_temp.t50_keys(p_name text) returns text language sql as $$
  select coalesce(string_agg(k.conname || ':' || k.convalidated::text || ':' || k.conrelid::regclass::text
                             || '->' || k.confrelid::regclass::text, ', ' order by k.conname), 'none')
    from pg_constraint k
   where k.confrelid = to_regclass(p_name) and k.contype = 'f' and k.conparentid = 0
$$;

-- ======================================================================================================
-- A. The null sweep over every from_hypertable* routine
-- ======================================================================================================
create schema t50_ctl;
create function t50_ctl.from_hypertable_unchecked(p_hypertable regclass, p_force boolean default false) returns int
language plpgsql as $$ begin if not p_force then return 0; end if; return 1; end $$;
create function t50_ctl.from_hypertable_checked(p_hypertable regclass, p_force boolean default false) returns int
language plpgsql as $$
begin
  perform pgpm._refuse_null_arguments('from_hypertable_checked',
    json_build_object('p_hypertable', p_hypertable, 'p_force', p_force));
  return 0;
end $$;
select is(
  (select string_agg(routine || '.' || arg || '=' || pg_temp.t50_refused(routine, arg, state, msg)::text, ', '
                     order by routine, arg)
     from pg_temp.t50_sweep('t50_ctl', '^from_hypertable')),
  'from_hypertable_checked.p_force=true, from_hypertable_checked.p_hypertable=true, from_hypertable_unchecked.p_force=false, from_hypertable_unchecked.p_hypertable=false',
  'A CONTROL: the verdict refuses a routine with no null check');
select is(
  (select array_agg(n order by n) from unnest(array['from_hypertable', 'from_hypertable_copy', 'from_hypertable_cutover',
             'from_hypertable_disk_estimate', 'from_hypertable_drain_appends', 'from_hypertable_drain_appends_step',
             'from_hypertable_drain_delta', 'from_hypertable_drain_delta_step', 'from_hypertable_preflight',
             'from_hypertable_time_estimate']) n
    where n in (select routine from t50_swept)),
  array['from_hypertable', 'from_hypertable_copy', 'from_hypertable_cutover', 'from_hypertable_disk_estimate',
        'from_hypertable_drain_appends', 'from_hypertable_drain_appends_step', 'from_hypertable_drain_delta',
        'from_hypertable_drain_delta_step', 'from_hypertable_preflight', 'from_hypertable_time_estimate'],
  'LIVENESS: (A) the sweep enumerated the module''s routines from the catalog, the procedures and the drains among them');
select is(
  (select array_agg(d.routine || '.' || d.arg order by d.routine, d.arg) from t50_documented d
    where not exists (select 1 from t50_swept s where s.routine = d.routine and s.arg = d.arg)),
  null, 'A: every documented-null entry names a real argument of a real routine (the table cannot rot)');
select is(
  (select array_agg(s.routine || '.' || s.arg || ' -> ' || s.state || ' ' || coalesce(left(s.msg, 140), '(no error)')
                    order by s.routine, s.arg)
     from t50_swept s
    where not exists (select 1 from t50_documented d where d.routine = s.routine and d.arg = s.arg)
      and not pg_temp.t50_refused(s.routine, s.arg, s.state, s.msg)),
  null,
  'A: every from_hypertable* routine refuses a null with no documented meaning up front, with pgpm''s message naming it');
select is(
  (select array_agg(s.routine || '.' || s.arg order by s.routine, s.arg)
     from t50_swept s join t50_documented d on d.routine = s.routine and d.arg = s.arg
    where s.msg like '%does not accept null for%'),
  null, 'A: no argument whose null is documented is refused for its null');

-- ======================================================================================================
-- A1. from_hypertable refuses p_paused => null and p_lock_timeout => null before its copy (#951 bullet 2)
-- ======================================================================================================
create table public.t50_a (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.t50_a', 'ts', chunk_time_interval => interval '1 day');
insert into public.t50_a select g, timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', g
  from generate_series(1, 60) g;
create table public.t50_a_ref (rid int primary key, id bigint, ts timestamptz,
  constraint t50_a_ref_fk foreign key (id, ts) references public.t50_a (id, ts));
insert into public.t50_a_ref select 1, id, ts from public.t50_a where id = 7;
insert into public.t50_a_ref select 2, id, ts from public.t50_a where id = 40;
select throws_like(
  $$ call pgpm.from_hypertable('public.t50_a', 'ts', interval '1 day', p_paused => null) $$,
  'pg_partition_magician: from_hypertable does not accept null for p_paused: %',
  'A1: from_hypertable refuses p_paused => null, naming it');
select throws_like(
  $$ call pgpm.from_hypertable('public.t50_a', 'ts', interval '1 day', p_lock_timeout => null) $$,
  'pg_partition_magician: from_hypertable does not accept null for p_lock_timeout: %',
  'A1: and p_lock_timeout => null, which set the swap''s lock wait unbounded');
select is(pg_temp.t50_state('public.t50_a') || ' | ' || pg_temp.t50_keys('public.t50_a')
          || ' | ' || (select string_agg(id::text, ',' order by id) from public.t50_a where id in (1, 7, 40, 60)),
  'hypertable | copy:false | config:false | dropped_fk:0 | t50_a_ref_fk:true:t50_a_ref->t50_a | 1,7,40,60',
  'A1: refused before the copy: still a hypertable, its key in place, no copy, nothing registered or dropped');
call pgpm.from_hypertable('public.t50_a', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.t50_a'::regclass)
          || ' | config:' || exists (select 1 from pgpm.config where parent_table = 'public.t50_a'::regclass)::text,
  'p | config:true', 'LIVENESS: (A1) the same call with p_paused => true migrates the same hypertable');
select is((select string_agg(id::text || ':' || v::text, ',' order by id) from public.t50_a),
  (select string_agg(g::text || ':' || g::text, ',' order by g) from generate_series(1, 60) g),
  'LIVENESS: (A1) every row is there, by identity');
select is(pg_temp.t50_keys('public.t50_a'), 't50_a_ref_fk:true:t50_a_ref->t50_a',
  'LIVENESS: (A1) and its incoming key is back, validated, against the new parent');

-- ======================================================================================================
-- B. A NOT VALID incoming key is refused before the copy (#959 bullet 1, A959-1's fixture)
-- ======================================================================================================
create table public.t50_nv (id bigint not null, ts timestamptz not null, primary key (id, ts));
select create_hypertable('public.t50_nv', 'ts');
insert into public.t50_nv values (1, timestamptz '2026-09-20 00:00+00'), (2, timestamptz '2026-09-21 12:00+00');
create table public.t50_nv_dirty (cid int primary key, pid bigint, pts timestamptz);
create table public.t50_nv_clean (cid int primary key, pid bigint, pts timestamptz);
insert into public.t50_nv_dirty values (1, 1, timestamptz '2026-09-20 00:00+00'), (2, 99, timestamptz '2026-09-22 00:00+00');
insert into public.t50_nv_clean values (1, 2, timestamptz '2026-09-21 12:00+00');
alter table public.t50_nv_dirty add constraint t50_nv_dirty_fk foreign key (pid, pts) references public.t50_nv (id, ts) not valid;
alter table public.t50_nv_clean add constraint t50_nv_clean_fk foreign key (pid, pts) references public.t50_nv (id, ts) not valid;
select is(pg_temp.t50_keys('public.t50_nv') || ' | orphans:'
          || (select count(*) from public.t50_nv_dirty d where not exists
               (select 1 from public.t50_nv h where h.id = d.pid and h.ts = d.pts))::text,
  't50_nv_clean_fk:false:t50_nv_clean->t50_nv, t50_nv_dirty_fk:false:t50_nv_dirty->t50_nv | orphans:1',
  'LIVENESS: (B) both incoming keys are NOT VALID, one over a tolerated orphan');
select throws_like(
  $$ call pgpm.from_hypertable('public.t50_nv', 'ts', interval '1 day', p_paused => false) $$,
  'pg_partition_magician: cannot migrate hypertable t50_nv -- its incoming foreign key(s) (t50_nv_clean_fk on t50_nv_clean, t50_nv_dirty_fk on t50_nv_dirty) are NOT VALID.%',
  'B: from_hypertable refuses the NOT VALID incoming keys, naming them');
select throws_like(
  $$ call pgpm.from_hypertable_copy('public.t50_nv', 'ts') $$,
  'pg_partition_magician: cannot migrate hypertable t50_nv -- its incoming foreign key(s) (t50_nv_clean_fk on t50_nv_clean, t50_nv_dirty_fk on t50_nv_dirty) are NOT VALID.%',
  'B: and so does from_hypertable_copy on its own, before it copies anything');
select is(pg_temp.t50_state('public.t50_nv') || ' | ' || pg_temp.t50_keys('public.t50_nv'),
  'hypertable | copy:false | config:false | dropped_fk:0 | t50_nv_clean_fk:false:t50_nv_clean->t50_nv, t50_nv_dirty_fk:false:t50_nv_dirty->t50_nv',
  'B: refused before the copy: still a hypertable, both keys in place and still NOT VALID, nothing dropped');

-- ======================================================================================================
-- C. A NOT VALID incoming key added after the copy is refused by the cutover, under its lock
-- ======================================================================================================
create table public.t50_w (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.t50_w', 'ts', chunk_time_interval => interval '1 day');
insert into public.t50_w select g, timestamptz '2026-09-10 00:00+00' + g * interval '2 hours', g
  from generate_series(1, 40) g;
create table public.t50_w_ref (rid int primary key, id bigint, ts timestamptz);
insert into public.t50_w_ref select 1, id, ts from public.t50_w where id = 5;
call pgpm.from_hypertable_copy('public.t50_w', 'ts');
select is((select count(*)::int from public.t50_w_pgpm_dest), 40, 'LIVENESS: (C) the online copy ran and holds all 40 rows');
alter table public.t50_w_ref add constraint t50_w_fk foreign key (id, ts) references public.t50_w (id, ts) not valid;
-- p_predrain => false keeps the cutover in one transaction up to the swap, so a cutover that does NOT refuse
-- reaches the swap's COMMIT and dies there with 2D000 instead of the pinned message
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.t50_w', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable t50_w -- its incoming foreign key(s) (t50_w_fk on t50_w_ref) are NOT VALID.%',
  'C: the cutover refuses the NOT VALID key added after the copy, under its lock');
select is(pg_temp.t50_state('public.t50_w') || ' | ' || pg_temp.t50_keys('public.t50_w'),
  'hypertable | copy:true | config:false | dropped_fk:0 | t50_w_fk:false:t50_w_ref->t50_w',
  'C: refused before the swap: still a hypertable, the key in place and still NOT VALID, the copy kept');
alter table public.t50_w_ref validate constraint t50_w_fk;
call pgpm.from_hypertable_cutover('public.t50_w', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.t50_w'::regclass) || ' | '
          || pg_temp.t50_keys('public.t50_w') || ' | '
          || (select string_agg(id::text, ',' order by id) from public.t50_w where id in (1, 5, 40)),
  'p | t50_w_fk:true:t50_w_ref->t50_w | 1,5,40',
  'LIVENESS: (C) validated, the same key migrates: the cutover swaps, and the key comes back validated');

-- ======================================================================================================
-- D. A NOT VALID outgoing key is refused before the copy (#264), the same case as tests/268 part B5
-- ======================================================================================================
create table public.t50_par (k int primary key);
insert into public.t50_par values (1);
create table public.t50_out (ts timestamptz not null, k int, v int);
select create_hypertable('public.t50_out', 'ts');
insert into public.t50_out values (timestamptz '2026-09-15 00:00+00', 1, 1), (timestamptz '2026-09-15 06:00+00', 2, 2);
alter table public.t50_out add constraint t50_out_fk foreign key (k) references public.t50_par (k) not valid;
select throws_like(
  $$ call pgpm.from_hypertable('public.t50_out', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot migrate hypertable t50_out -- its outgoing foreign key(s) (t50_out_fk) are NOT VALID.%',
  'D: from_hypertable refuses the NOT VALID outgoing key, naming it');
select is(pg_temp.t50_state('public.t50_out') || ' | '
          || (select convalidated::text from pg_constraint where conname = 't50_out_fk'),
  'hypertable | copy:false | config:false | dropped_fk:0 | false',
  'D: refused before the copy: still a hypertable, the key still NOT VALID');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
