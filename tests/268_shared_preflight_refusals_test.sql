-- The shared preflight's refusal conformance suite, core half (issues #951, #952, #959; lever phase #966).
-- tests/269 is the resume path's half and tests/timescale/db/50 the hypertable path's.
--
-- THE INVARIANT. A refusal the core makes before anything commits is made by one preflight that every
-- converting entry point calls before its first commit, so no entry point reaches a swap, a drop or a
-- handoff with an input the core would have refused up front. Before the lever three kinds of input got
-- through somewhere:
--   A. A null argument. pgpm._refuse_null_arguments (#896) guarded transmute and extend_to only, and
--      PL/pgSQL reads a null with three-valued logic, so `if not p_force then return 0` let
--      suspend_incoming_fks(p, null) fall through as p_force => true and drop the live incoming keys
--      (#951 bullet 1), and every other public routine took a null somewhere it has no meaning.
--   B. A control column whose type cannot hold the grid's bounds. A numeric(6,-2) key with step 10 passed
--      the id-kind preflight, phases 1 and 2 committed the bound CHECK and the claim, and the cutover's
--      ATTACH (which rounds a bound to the column's scale) died raw on every retry (#952 bullet 1). A
--      numeric(4,0) key whose next boundary is 10000 took the same path on numeric field overflow.
--   C. A key the conversion cannot carry: a NOT VALID incoming key (#902), refused by transmute but not
--      by from_hypertable (tests/timescale/db/50), and on PostgreSQL 18 a NOT ENFORCED key, refused with
--      the NOT VALID wording and a VALIDATE CONSTRAINT remedy PostgreSQL rejects for it (#959 bullet 2).
--
-- EXHAUSTIVENESS. Part A enumerates every public routine of schema pgpm from pg_proc AT TEST TIME and calls
-- each with null in each argument position (every other argument a type-correct sample, or its default),
-- and requires pgpm's own null refusal, naming exactly that argument: SQLSTATE P0001 and the message
-- 'pg_partition_magician: <routine> does not accept null for <arg>:'. A public routine added later without
-- the check fails the sweep by construction. The arguments whose null IS a documented meaning are the case
-- table t268_documented, each with the reference.md section that documents it; those must NOT be refused,
-- and an entry naming an argument that does not exist fails too, so the table cannot rot. A planted control
-- schema proves the verdict can fail (an unchecked routine, and one that checks the wrong argument list).
--
-- REFUSED BEFORE ANY COMMIT. Part B's cases run transmute through dblink, as top-level CALLs whose phases
-- can commit: a build that does not refuse really commits (or converts), rather than dying at its first
-- COMMIT inside a pgTAP function and rolling back into the state a refusal leaves. Each case pins the
-- refusal by its message, witnesses that its fixture really carried the condition, and then asserts the
-- table untouched by identity: the same oid, still a plain table, its rows and its keys as they were, no
-- pgpm.config row, no pgpm_monolith_bound CHECK and no claim. Asymmetric controls convert the same table
-- once the one condition is gone (a representable step, a non-null argument), so a preflight that refused
-- everything could not pass. bench/shared_preflight_conformance.sh runs this file against the mutants.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(34);

select dblink_connect('t268', 'dbname=' || current_database());

-- ======================================================================================================
-- The sweep's instrument
-- ======================================================================================================
-- the table every swept call names: plain and unmanaged, so a call that is not refused acts on nothing
create table public.t268_sweep (id bigint primary key, ts timestamptz not null default now());
insert into public.t268_sweep values (1), (2), (3);

-- a type-correct sample for every argument type a public routine takes; an unknown type is an ERROR, never
-- a skipped case, so a routine with a new argument type cannot leave the sweep silently
create function pg_temp.t268_sample(p_type oid) returns text language plpgsql as $$
begin
  return case p_type
    when 'regclass'::regtype      then quote_literal('public.t268_sweep') || '::regclass'
    when 'name'::regtype          then quote_literal('id') || '::name'
    when 'text'::regtype          then quote_literal('1') || '::text'
    when 'integer'::regtype       then '1::integer'
    when 'bigint'::regtype        then '1::bigint'
    when 'numeric'::regtype       then '1::numeric'
    when 'boolean'::regtype       then 'false'
    when 'interval'::regtype      then quote_literal('1 day') || '::interval'
    when 'timestamptz'::regtype   then 'now()'
    when 'regprocedure'::regtype  then quote_literal('pgpm.version()') || '::regprocedure'
    when 'bigint[]'::regtype      then quote_literal('{1}') || '::bigint[]'
  end;
end $$;

-- every (routine, input argument) of schema p_nsp not starting with '_', called with null in that position
create function pg_temp.t268_sweep(p_nsp name)
returns table (routine text, arg text, state text, msg text) language plpgsql as $$
declare
  r record; v_names text[]; v_types oid[]; v_n int; v_args text[]; v_call text; i int; j int; v_sample text;
begin
  for r in select p.oid, p.proname::text as proname, p.prokind, p.pronargs, p.pronargdefaults,
                  p.proargnames, p.proargmodes, p.proallargtypes, string_to_array(p.proargtypes::text, ' ')::oid[] as intypes   -- oidvector is 0-based
             from pg_proc p
            where p.pronamespace = p_nsp::regnamespace and p.proname !~ '^_'
            order by p.proname, p.oid loop
    -- the INPUT arguments in order (IN, INOUT and VARIADIC; an OUT argument is not passed)
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
          v_sample := pg_temp.t268_sample(v_types[j]);
          if v_sample is null then
            raise exception 't268 sweep: no sample for %.% argument % of type %',
              p_nsp, r.proname, v_names[j], format_type(v_types[j], null);
          end if;
          v_args := v_args || format('%I => %s', v_names[j], v_sample);
        end if;   -- a later argument with a default is left to it
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

-- pgpm's own null refusal, naming exactly the one argument that was null
create function pg_temp.t268_refused(p_routine text, p_arg text, p_state text, p_msg text)
returns boolean language sql immutable as $$
  select coalesce(p_state = 'P0001'
                  and starts_with(p_msg, 'pg_partition_magician: ' || p_routine || ' does not accept null for ' || p_arg || ':'),
                  false)
$$;

-- the arguments whose null is a documented meaning, and where it is documented (docs/reference.md)
create temp table t268_documented (routine text, arg text, documented text);
insert into t268_documented values
  ('transmute', 'p_retain', '#transmute: p_retain -- `null` keeps everything'),
  ('transmute', 'p_tt_prefix', '#transmute: the text_time shape arguments, null outside text_time'),
  ('transmute', 'p_tt_width', '#transmute: the text_time shape arguments, null outside text_time'),
  ('transmute', 'p_tt_radix', '#transmute: the text_time shape arguments, null outside text_time'),
  ('transmute', 'p_tt_unit', '#transmute: the text_time shape arguments, null outside text_time'),
  ('transmute', 'p_tt_alphabet', '#transmute: p_tt_alphabet, whose null is the default alphabet'),
  ('regrain', 'p_target_step', '#regrain: width p_target_step (default config.partition_step)'),
  ('regrain_step', 'p_target_step', '#regrain_step: p_target_step text default null'),
  ('regrain_step', 'p_batch', '#regrain_step: a null `p_batch` takes `config.regrain_batch`'),
  ('regrain_history', 'p_target_step', '#regrain_history: p_target_step text default null'),
  ('maintain', 'p_status', '#maintain: inout p_status text default null, the status it returns'),
  ('maintain_obtain', 'p_status', '#maintain_obtain: inout p_status text default null'),
  ('set_regrain', 'p_target_step', '#set_regrain: `null` turns it off'),
  ('set_retain', 'p_retain', '#set_retain: (`null` = keep forever)'),
  ('set_archive_fn', 'p_archive_fn', '#archive-strategies: a bare `null` turns archiving back off'),
  ('progress', 'p_parent', '#progress: one row per managed table, or just p_parent''s'),
  ('restore_incoming_fks', 'p_ids', '#restore_incoming_fks: leave it at the default (`null`, restore every row)'),
  ('check_text_time', 'p_alphabet', '#check_text_time: p_alphabet text default null, the default alphabet');

create temp table t268_swept as select * from pg_temp.t268_sweep('pgpm');

-- ======================================================================================================
-- A. The null sweep over every public routine of schema pgpm
-- ======================================================================================================
-- the planted control: what the verdict says of a routine with no check, and of one checking the wrong list
create schema t268_ctl;
create function t268_ctl.unchecked(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$ begin if not p_force then return 0; end if; return 1; end $$;
create function t268_ctl.misnamed(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$
begin
  perform pgpm._refuse_null_arguments('misnamed', json_build_object('p_parent', p_parent));
  if not p_force then return 0; end if; return 1;
end $$;
create function t268_ctl.checked(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$
begin
  perform pgpm._refuse_null_arguments('checked', json_build_object('p_parent', p_parent, 'p_force', p_force));
  return 0;
end $$;
select is(
  (select string_agg(routine || '.' || arg || '=' || pg_temp.t268_refused(routine, arg, state, msg)::text, ', '
                     order by routine, arg)
     from pg_temp.t268_sweep('t268_ctl')),
  'checked.p_force=true, checked.p_parent=true, misnamed.p_force=false, misnamed.p_parent=true, unchecked.p_force=false, unchecked.p_parent=false',
  'A CONTROL: the verdict refuses a routine with no null check, and one whose check leaves an argument out');

select ok((select count(*) from t268_swept) >= 80
          and (select count(distinct routine) from t268_swept) >= 30,
  'A LIVENESS: the sweep enumerated every public routine from the catalog (at least 30, 80 argument positions)');
select is(
  (select array_agg(n order by n) from unnest(array['suspend_incoming_fks.p_force', 'restore_incoming_fks.p_parent',
             'validate_incoming_fks.p_respect_backoff', 'set_obtain.p_obtain', 'set_partition_tz.p_tz',
             'transmute.p_paused', 'transmute.p_lock_timeout', 'extend_to.p_max', 'maintain.p_parent',
             'observe_window.p_since']) n
    where n in (select routine || '.' || arg from t268_swept)),
  array['extend_to.p_max', 'maintain.p_parent', 'observe_window.p_since', 'restore_incoming_fks.p_parent',
        'set_obtain.p_obtain', 'set_partition_tz.p_tz', 'suspend_incoming_fks.p_force',
        'transmute.p_lock_timeout', 'transmute.p_paused', 'validate_incoming_fks.p_respect_backoff'],
  'A LIVENESS: the swept positions include the ones the issues name (the FK helpers, the setters, transmute)');
select is(
  (select array_agg(d.routine || '.' || d.arg order by d.routine, d.arg) from t268_documented d
    where not exists (select 1 from t268_swept s where s.routine = d.routine and s.arg = d.arg)),
  null,
  'A: every documented-null entry names a real argument of a real public routine (the table cannot rot)');
select is(
  (select array_agg(s.routine || '.' || s.arg || ' -> ' || s.state || ' ' || coalesce(left(s.msg, 140), '(no error)')
                    order by s.routine, s.arg)
     from t268_swept s
    where not exists (select 1 from t268_documented d where d.routine = s.routine and d.arg = s.arg)
      and not pg_temp.t268_refused(s.routine, s.arg, s.state, s.msg)),
  null,
  'A: every public routine refuses a null with no documented meaning up front, with pgpm''s message naming it');
select is(
  (select array_agg(s.routine || '.' || s.arg order by s.routine, s.arg)
     from t268_swept s join t268_documented d on d.routine = s.routine and d.arg = s.arg
    where s.msg like '%does not accept null for%'),
  null,
  'A: no argument whose null is documented is refused for its null');

-- ======================================================================================================
-- A1. suspend_incoming_fks(p, null) does nothing to a live, restored key (#951 bullet 1)
-- ======================================================================================================
create table public.t268_sp (id bigint primary key, body text);
insert into public.t268_sp select g * 10, 'r' || g from generate_series(1, 250) g;
create table public.t268_spc (rid bigint primary key,
                              id bigint constraint t268_spc_fk references public.t268_sp on delete cascade);
insert into public.t268_spc values (1, 10), (2, 2500);
select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_sp', 'id', 1000::bigint, p_obtain => 30,
                                                    p_incoming_fks => 'preserve') $c$);
select is(pgpm.restore_incoming_fks('public.t268_sp'), 1, 'A1 LIVENESS: the preserved key is re-added on the parent');
select is(pgpm.suspend_incoming_fks('public.t268_sp', false), 0, 'A1 GUARD: p_force => false does nothing');
select throws_like($$ select pgpm.suspend_incoming_fks('public.t268_sp', null) $$,
  'pg_partition_magician: suspend_incoming_fks does not accept null for p_force: %',
  'A1: p_force => null is refused, naming it');
select is((select string_agg(conname || ':' || confrelid::regclass::text, ',') from pg_constraint
            where conrelid = 'public.t268_spc'::regclass and contype = 'f' and conparentid = 0)
          || ' / ' || (select (restored_at is not null)::text from pgpm.dropped_fk
                        where parent_table = 'public.t268_sp'::regclass and constraint_name = 't268_spc_fk'),
  't268_spc_fk:t268_sp / true', 'A1: the key is still live against the parent, and still recorded as restored');

-- ======================================================================================================
-- B. The refusal cases, each against transmute, each refused before anything commits
-- ======================================================================================================
-- the table's state, by identity: kind, the oid it had, and what pgpm would have committed
create function pg_temp.t268_state(p_name text, p_oid oid) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_oid),
    case when to_regclass(p_name)::oid = p_oid then 'same oid' else 'oid changed' end,
    'config:' || exists (select 1 from pgpm.config where parent_table::oid = p_oid),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_oid and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table::oid = p_oid))
$$;
-- every top-level foreign key on or to a relation, by name, validity and the relations it joins
create function pg_temp.t268_keys(p_oid oid) returns text language sql as $$
  select coalesce(string_agg(k.conname || ':' || k.convalidated::text || ':' || k.conrelid::regclass::text
                             || '->' || k.confrelid::regclass::text, ', ' order by k.conname), 'none')
    from pg_constraint k
   where (k.conrelid = p_oid or k.confrelid = p_oid) and k.contype = 'f' and k.conparentid = 0
$$;
create temp table t268_oid (rel text primary key, oid oid);

-- B1. a null argument (p_paused), and the same call without it converts
create table public.t268_np (id bigint primary key, v text);
insert into public.t268_np select g, 'x' from generate_series(1, 30) g;
insert into t268_oid values ('public.t268_np', 'public.t268_np'::regclass);
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_np', 'id', 10::bigint, p_paused => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_paused: %',
  'B1: transmute refuses p_paused => null, naming it');
select is(pg_temp.t268_state('public.t268_np', (select oid from t268_oid where rel = 'public.t268_np'))
          || ' | ' || (select count(*) from public.t268_np)::text,
  'r | same oid | config:false | bound:false | claim:false | 30', 'B1: refused before anything committed');
select lives_ok(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_np', 'id', 10::bigint, p_paused => true) $c$) $$,
  'B1 LIVENESS: the same call with p_paused => true converts the same table');

-- B2. a negative-scale numeric key whose step its bounds cannot represent (#952 bullet 1, A952-1's fixture)
create table public.t268_ns (id numeric(6,-2) primary key, v text);
insert into public.t268_ns select g * 100, 'x' from generate_series(1, 20) g;
insert into t268_oid values ('public.t268_ns', 'public.t268_ns'::regclass);
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.t268_ns'::regclass and attname = 'id') || ' / ' || (select max(id) from public.t268_ns)::text
          || ' / ' || 2010::numeric(6,-2)::text,
  'numeric(6,-2) / 2000 / 2000', 'B2 LIVENESS: the key is numeric(6,-2), and the step-10 bound 2010 would round to 2000');
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_ns', 'id', 10::bigint) $c$) $$,
  'pg_partition_magician: cannot partition t268_ns on id with step 10 and anchor 0 -- the column is numeric(6,-2), which holds only multiples of 100,%',
  'B2: transmute refuses the step the column cannot represent, naming the column''s unit');
select is(pg_temp.t268_state('public.t268_ns', (select oid from t268_oid where rel = 'public.t268_ns'))
          || ' | ' || (select string_agg(id::text, ',' order by id) from public.t268_ns where id in (100, 1000, 2000)),
  'r | same oid | config:false | bound:false | claim:false | 100,1000,2000', 'B2: refused before anything committed');
select lives_ok($$ insert into public.t268_ns values (2100, 'past hi') $$, 'B2: a write past the old frontier is accepted');
select lives_ok(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_ns', 'id', 100::bigint) $c$) $$,
  'B2 LIVENESS: a step of 100, which the column can represent, converts the same table');
select is((select string_agg(pg_get_expr(c.relpartbound, c.oid), ', ') from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = 'public.t268_ns'::regclass and c.oid = (select monolith_oid from pgpm.config where parent_table = 'public.t268_ns'::regclass)),
  'FOR VALUES FROM (''100'') TO (''2200'')', 'B2: and the monolith is attached on bounds the column holds exactly');

-- B3. a bound past the column's precision: numeric(4,0) whose next step-10 boundary is 10000
create table public.t268_ov (id numeric(4,0) primary key, v text);
insert into public.t268_ov select g * 5, 'x' from generate_series(1, 1999) g;
insert into t268_oid values ('public.t268_ov', 'public.t268_ov'::regclass);
select throws_ok($$ select 10000::numeric(4,0) $$, '22003', NULL,
  'B3 LIVENESS: the boundary above the newest key, 10000, cannot be stored in numeric(4,0)');
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_ov', 'id', 10::bigint) $c$) $$,
  'pg_partition_magician: cannot partition t268_ov on id: the monolith''s bound [0, 10000) cannot be stored in the column, which is numeric(4,0)%',
  'B3: transmute refuses a monolith bound the column cannot hold');
select is(pg_temp.t268_state('public.t268_ov', (select oid from t268_oid where rel = 'public.t268_ov'))
          || ' | ' || (select max(id) from public.t268_ov)::text,
  'r | same oid | config:false | bound:false | claim:false | 9995', 'B3: refused before anything committed');

-- B4. a NOT VALID incoming key under 'preserve' (#902)
create table public.t268_nvi (id bigint primary key);
insert into public.t268_nvi values (1), (4), (9);
create table public.t268_nvi_ref (cid int primary key, nid bigint);
insert into public.t268_nvi_ref values (1, 4), (2, 77);
alter table public.t268_nvi_ref add constraint t268_nvi_fk foreign key (nid) references public.t268_nvi (id) not valid;
insert into t268_oid values ('public.t268_nvi', 'public.t268_nvi'::regclass);
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_nvi', 'id', 10::bigint, p_incoming_fks => 'preserve') $c$) $$,
  'pg_partition_magician: cannot transmute t268_nvi -- its incoming foreign key(s) (t268_nvi_fk on t268_nvi_ref) are NOT VALID.%',
  'B4: transmute refuses the NOT VALID incoming key, naming it');
select is(pg_temp.t268_state('public.t268_nvi', (select oid from t268_oid where rel = 'public.t268_nvi'))
          || ' | ' || pg_temp.t268_keys((select oid from t268_oid where rel = 'public.t268_nvi')),
  'r | same oid | config:false | bound:false | claim:false | t268_nvi_fk:false:t268_nvi_ref->t268_nvi',
  'B4: refused before anything committed, the key still NOT VALID in place');

-- B5. a NOT VALID outgoing key (#263)
create table public.t268_tgt (k int primary key);
insert into public.t268_tgt values (1), (2);
create table public.t268_nvo (id bigint primary key, k int);
insert into public.t268_nvo values (1, 1), (2, 2), (3, 5);
alter table public.t268_nvo add constraint t268_nvo_fk foreign key (k) references public.t268_tgt (k) not valid;
insert into t268_oid values ('public.t268_nvo', 'public.t268_nvo'::regclass);
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_nvo', 'id', 10::bigint) $c$) $$,
  'pg_partition_magician: cannot transmute t268_nvo -- its outgoing foreign key(s) (t268_nvo_fk) are NOT VALID.%',
  'B5: transmute refuses the NOT VALID outgoing key, naming it');
select is(pg_temp.t268_state('public.t268_nvo', (select oid from t268_oid where rel = 'public.t268_nvo'))
          || ' | ' || pg_temp.t268_keys((select oid from t268_oid where rel = 'public.t268_nvo')),
  'r | same oid | config:false | bound:false | claim:false | t268_nvo_fk:false:t268_nvo->t268_tgt',
  'B5: refused before anything committed, the key still NOT VALID in place');

-- B6. a non-finite id (#895)
create table public.t268_nan (id numeric primary key, v text);
insert into public.t268_nan select g, 'x' from generate_series(1, 40) g;
insert into public.t268_nan values ('NaN', 'poison');
insert into t268_oid values ('public.t268_nan', 'public.t268_nan'::regclass);
select throws_like(
  $$ select dblink_exec('t268', $c$ call pgpm.transmute('public.t268_nan', 'id', 10::bigint) $c$) $$,
  'pg_partition_magician: t268_nan cannot be partitioned on an id grid using id: it holds a non-finite value%',
  'B6: transmute refuses the NaN key');
select is(pg_temp.t268_state('public.t268_nan', (select oid from t268_oid where rel = 'public.t268_nan'))
          || ' | ' || (select count(*) from public.t268_nan where id = 'NaN')::text,
  'r | same oid | config:false | bound:false | claim:false | 1', 'B6: refused before anything committed');

-- B7, B8. NOT ENFORCED keys, incoming and outgoing (#959 bullet 2): PostgreSQL 18 and later only
select current_setting('server_version_num')::int >= 180000 as pg18 \gset
create table public.t268_nei (id bigint primary key, v text);
insert into public.t268_nei select g, 'x' from generate_series(1, 50) g;
create table public.t268_nei_ref (cid int primary key, nid bigint);
insert into public.t268_nei_ref values (1, 7), (2, 9999);
create table public.t268_neo (id bigint primary key, k int);
insert into public.t268_neo values (1, 1), (2, 404);
\if :pg18
alter table public.t268_nei_ref add constraint t268_nei_fk foreign key (nid) references public.t268_nei (id) not enforced;
alter table public.t268_neo add constraint t268_neo_fk foreign key (k) references public.t268_tgt (k) not enforced;
\endif
insert into t268_oid values ('public.t268_nei', 'public.t268_nei'::regclass), ('public.t268_neo', 'public.t268_neo'::regclass);
create temp table t268_err (k text primary key, v text);
do $$
begin
  perform dblink_exec('t268', $c$ call pgpm.transmute('public.t268_nei', 'id', 10::bigint, p_incoming_fks => 'preserve') $c$);
  insert into t268_err values ('nei', 'no error');
exception when others then insert into t268_err values ('nei', sqlerrm);
end $$;
do $$
begin
  perform dblink_exec('t268', $c$ call pgpm.transmute('public.t268_neo', 'id', 10::bigint) $c$);
  insert into t268_err values ('neo', 'no error');
exception when others then insert into t268_err values ('neo', sqlerrm);
end $$;
select case when :'pg18'::boolean
  then is((select string_agg(conname || ':' || (to_jsonb(c) ->> 'conenforced') || ':' || convalidated::text, ', ' order by conname)
             from pg_constraint c where conname in ('t268_nei_fk', 't268_neo_fk')),
          't268_nei_fk:false:false, t268_neo_fk:false:false',
          'B7 LIVENESS: both keys are NOT ENFORCED, and read convalidated = false')
  else skip('NOT ENFORCED foreign keys exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then ok((select v like 'pg_partition_magician: cannot transmute t268_nei -- its foreign key(s) (t268_nei_fk on t268_nei_ref) are NOT ENFORCED.%'
                  and v like '%ALTER CONSTRAINT <name> ENFORCED%' and v not like '%VALIDATE CONSTRAINT%'
             from t268_err where k = 'nei'),
          'B7: the NOT ENFORCED incoming key is named NOT ENFORCED, with the remedy that applies to it')
  else skip('NOT ENFORCED foreign keys exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then ok((select v like 'pg_partition_magician: cannot transmute t268_neo -- its foreign key(s) (t268_neo_fk on t268_neo) are NOT ENFORCED.%'
                  and v not like '%VALIDATE CONSTRAINT%'
             from t268_err where k = 'neo'),
          'B8: the NOT ENFORCED outgoing key is named NOT ENFORCED, with the remedy that applies to it')
  else skip('NOT ENFORCED foreign keys exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then is(pg_temp.t268_state('public.t268_nei', (select oid from t268_oid where rel = 'public.t268_nei'))
          || ' / ' || pg_temp.t268_state('public.t268_neo', (select oid from t268_oid where rel = 'public.t268_neo')),
          'r | same oid | config:false | bound:false | claim:false / r | same oid | config:false | bound:false | claim:false',
          'B7, B8: both refused before anything committed')
  else skip('NOT ENFORCED foreign keys exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then is((select string_agg(conname || ':' || (to_jsonb(c) ->> 'conenforced'), ', ' order by conname)
             from pg_constraint c where conname in ('t268_nei_fk', 't268_neo_fk')),
          't268_nei_fk:false, t268_neo_fk:false', 'B7, B8: and both keys are still in place, still NOT ENFORCED')
  else skip('NOT ENFORCED foreign keys exist from PostgreSQL 18', 1) end;
-- before 18 neither key exists, so both conversions go ahead: the witness that the arm is no refusal there
select case when :'pg18'::boolean
  then skip('before PostgreSQL 18 the two tables carry no key, and convert', 1)
  else is((select string_agg(k || '=' || v, ', ' order by k) from t268_err), 'nei=no error, neo=no error',
          'B7, B8 CONTROL: before PostgreSQL 18 (no NOT ENFORCED keys) both tables convert') end;

select dblink_disconnect('t268');
select * from finish();
