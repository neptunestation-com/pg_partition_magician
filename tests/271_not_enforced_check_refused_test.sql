-- transmute names a NOT ENFORCED CHECK for what it is (#969 bullet 10; lever phase #966, the shared preflight).
--
-- THE DEFECT. _transmute's #730 gate refuses a constraint the cutover cannot carry, and its NOT VALID arm read
-- `contype in ('c', 'n') and not convalidated`. On PostgreSQL 18 a NOT ENFORCED CHECK reads convalidated =
-- false too, so it was refused as NOT VALID with the remedy `ALTER TABLE ... VALIDATE CONSTRAINT`, which
-- PostgreSQL rejects for it ("cannot validate NOT ENFORCED constraint"). The foreign-key gate had the same
-- shape and was fixed by #959 bullet 2 (tests/268 B7, B8); this is the CHECK gate one function over.
--
-- THE CONTRACT. A NOT ENFORCED CHECK is refused before anything commits, named NOT ENFORCED, with a remedy
-- that applies to it: drop it, or re-create it as an enforced CHECK. PostgreSQL 18 can neither validate one
-- nor alter a CHECK's enforceability, so neither VALIDATE CONSTRAINT nor ALTER CONSTRAINT is prescribed. The
-- NOT VALID arm still refuses a NOT VALID CHECK as NOT VALID, with its own remedy.
--
-- Fixtures, asymmetric on purpose:
--   (A) t271_ne: one NOT ENFORCED CHECK that 30 of its 40 rows violate, beside an enforced one; refused naming
--       only the NOT ENFORCED one; nothing committed; with it dropped (the remedy) the same call converts.
--   (B) t271_mix: a NOT ENFORCED CHECK and a NOT VALID one; the first refusal names only the NOT ENFORCED one
--       as NOT ENFORCED, and with it dropped the NOT VALID one is refused as NOT VALID (all versions), so the
--       two arms stay apart and the NOT VALID arm is not switched off by the exclusion.
--   (C) t271_fix: a NOT ENFORCED CHECK every row satisfies, re-created as an enforced one (the other remedy):
--       the same call converts, and the CHECK binds a forward partition.
-- PostgreSQL 18 and later only for the NOT ENFORCED shapes (the syntax does not exist before); before 18 the
-- fixtures carry no NOT ENFORCED CHECK and a control witnesses that the arm refuses nothing there. transmute
-- runs through dblink as a top-level CALL, so a build that does not refuse really commits (or converts),
-- rather than dying at its first COMMIT inside a pgTAP function into the state a refusal leaves.
-- The arm cannot fire on PostgreSQL 17, so the discriminate track cannot judge a mutant of it: this file,
-- run by the PostgreSQL 18 leg of the matrix, is its guard (see the PR for the hand proof against the mutant).
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
set timezone = 'UTC';

select plan(14);

select dblink_connect('t271', 'dbname=' || current_database());
select current_setting('server_version_num')::int >= 180000 as pg18 \gset

-- the table's state, by identity: kind, the oid it had, and what pgpm would have committed
create function pg_temp.t271_state(p_name text, p_oid oid) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_oid),
    case when to_regclass(p_name)::oid = p_oid then 'same oid' else 'oid changed' end,
    'config:' || exists (select 1 from pgpm.config where parent_table::oid = p_oid),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_oid and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table::oid = p_oid))
$$;
-- run a CALL top level through dblink; the error message it raised, or 'converted'
create function pg_temp.t271_call(p_sql text) returns text language plpgsql as $$
begin
  perform dblink_exec('t271', p_sql);
  return 'converted';
exception when others then
  return sqlerrm;
end $$;
create temp table t271_oid (rel text primary key, oid oid);
create temp table t271_err (k text primary key, v text);

-- ======================================================================================================
-- (A) a NOT ENFORCED CHECK that most rows violate
-- ======================================================================================================
create table public.t271_ne (id bigint primary key, v int not null,
                             constraint t271_ne_id_pos check (id > 0));
insert into public.t271_ne select g, case when g <= 30 then -g else g end from generate_series(1, 40) g;
\if :pg18
alter table public.t271_ne add constraint t271_ne_v_pos check (v > 0) not enforced;
\endif
insert into t271_oid values ('public.t271_ne', 'public.t271_ne'::regclass);
insert into t271_err values ('ne', pg_temp.t271_call($c$ call pgpm.transmute('public.t271_ne', 'id', 100::bigint, p_obtain => 2) $c$));

select case when :'pg18'::boolean
  then is((select string_agg(conname || ':' || (to_jsonb(c) ->> 'conenforced') || ':' || convalidated::text, ', ' order by conname)
             from pg_constraint c where conrelid = 'public.t271_ne'::regclass and contype = 'c')
          || ' / ' || (select count(*) from public.t271_ne where v <= 0)::text,
          't271_ne_id_pos:true:true, t271_ne_v_pos:false:false / 30',
          'A LIVENESS: t271_ne_v_pos is NOT ENFORCED and reads convalidated = false, beside an enforced CHECK; 30 of 40 rows violate it')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then throws_like($$ alter table public.t271_ne validate constraint t271_ne_v_pos $$,
                   '%cannot validate NOT ENFORCED constraint%',
                   'A LIVENESS: PostgreSQL rejects VALIDATE CONSTRAINT on it, the remedy the NOT VALID wording prescribed')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then throws_like($$ alter table public.t271_ne alter constraint t271_ne_v_pos enforced $$,
                   '%cannot alter enforceability of constraint%',
                   'A LIVENESS: and ALTER CONSTRAINT ... ENFORCED, which on PostgreSQL 18 applies to a foreign key only')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then ok((select v like 'pg_partition_magician: cannot transmute t271_ne -- its CHECK constraint(s) (t271_ne_v_pos) are NOT ENFORCED.%'
             from t271_err where k = 'ne'),
          'A: transmute refuses the NOT ENFORCED CHECK, naming it and only it, as NOT ENFORCED')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then ok((select v like '%ALTER TABLE t271_ne DROP CONSTRAINT <name>%' and v like '%re-create it as an enforced CHECK%'
                  and v not like '%NOT VALID%' and v not like '%VALIDATE CONSTRAINT%' and v not like '%ALTER CONSTRAINT%'
             from t271_err where k = 'ne'),
          'A: with a remedy that applies (drop it, or re-create it enforced), and neither VALIDATE CONSTRAINT nor ALTER CONSTRAINT')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select case when :'pg18'::boolean
  then is(pg_temp.t271_state('public.t271_ne', (select oid from t271_oid where rel = 'public.t271_ne'))
          || ' | ' || (select string_agg(id || '=' || v, ',' order by id) from public.t271_ne where id in (1, 30, 31, 40)),
          'r | same oid | config:false | bound:false | claim:false | 1=-1,30=-30,31=31,40=40',
          'A: refused before anything committed, the rows as they were')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
\if :pg18
alter table public.t271_ne drop constraint t271_ne_v_pos;
select pg_temp.t271_call($c$ call pgpm.transmute('public.t271_ne', 'id', 100::bigint, p_obtain => 2) $c$) as ne_after \gset
\else
select 'n/a' as ne_after \gset
\endif
select case when :'pg18'::boolean
  then is(:'ne_after' || ' / ' || (select relkind::text from pg_class where oid = 'public.t271_ne'::regclass)
          || ' / ' || (select count(*) from public.t271_ne)::text,
          'converted / p / 40', 'A LIVENESS: with t271_ne_v_pos dropped (the remedy) the same call converts t271_ne, all 40 rows in it')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
-- before 18 the table carries no NOT ENFORCED CHECK, so the first call converts it: the arm refuses nothing there
select case when :'pg18'::boolean
  then skip('on PostgreSQL 18 t271_ne carries a NOT ENFORCED CHECK, refused above', 1)
  else is((select v from t271_err where k = 'ne') || ' / '
          || (select relkind::text from pg_class where oid = 'public.t271_ne'::regclass),
          'converted / p', 'A CONTROL: before PostgreSQL 18 (no NOT ENFORCED CHECK) t271_ne converts at the first call') end;

-- ======================================================================================================
-- (B) a NOT ENFORCED CHECK beside a NOT VALID one: the two arms stay apart
-- ======================================================================================================
create table public.t271_mix (id bigint primary key, v int not null, w int not null);
insert into public.t271_mix select g, -g, case when g = 7 then -7 else g end from generate_series(1, 20) g;
alter table public.t271_mix add constraint t271_mix_nv check (w > 0) not valid;
\if :pg18
alter table public.t271_mix add constraint t271_mix_ne check (v > 0) not enforced;
\endif
insert into t271_oid values ('public.t271_mix', 'public.t271_mix'::regclass);
insert into t271_err values ('mix1', pg_temp.t271_call($c$ call pgpm.transmute('public.t271_mix', 'id', 100::bigint, p_obtain => 2) $c$));
\if :pg18
alter table public.t271_mix drop constraint t271_mix_ne;
insert into t271_err values ('mix2', pg_temp.t271_call($c$ call pgpm.transmute('public.t271_mix', 'id', 100::bigint, p_obtain => 2) $c$));
\else
insert into t271_err select 'mix2', v from t271_err where k = 'mix1';
\endif
select case when :'pg18'::boolean
  then ok((select v like 'pg_partition_magician: cannot transmute t271_mix -- its CHECK constraint(s) (t271_mix_ne) are NOT ENFORCED.%'
             from t271_err where k = 'mix1'),
          'B: the NOT ENFORCED CHECK is refused as NOT ENFORCED, naming it and not the NOT VALID one beside it')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select ok((select v like 'pg_partition_magician: cannot transmute t271_mix -- its constraint(s) (t271_mix_nv) are NOT VALID,%VALIDATE CONSTRAINT%'
             from t271_err where k = 'mix2'),
  'B: the NOT VALID CHECK is refused as NOT VALID, with the VALIDATE remedy, naming it alone');
select is(pg_temp.t271_state('public.t271_mix', (select oid from t271_oid where rel = 'public.t271_mix'))
          || ' | ' || (select string_agg(id || '=' || w, ',' order by id) from public.t271_mix where w <= 0),
  'r | same oid | config:false | bound:false | claim:false | 7=-7',
  'B: refused before anything committed, the row the NOT VALID CHECK tolerates still there');

-- ======================================================================================================
-- (C) the other remedy: a NOT ENFORCED CHECK re-created as an enforced one
-- ======================================================================================================
create table public.t271_fix (id bigint primary key, v int not null);
insert into public.t271_fix select g, g from generate_series(1, 150) g;
\if :pg18
alter table public.t271_fix add constraint t271_fix_v_pos check (v > 0) not enforced;
insert into t271_err values ('fix1', pg_temp.t271_call($c$ call pgpm.transmute('public.t271_fix', 'id', 100::bigint, p_obtain => 2) $c$));
alter table public.t271_fix drop constraint t271_fix_v_pos;
\else
insert into t271_err values ('fix1', 'n/a');
\endif
alter table public.t271_fix add constraint t271_fix_v_pos check (v > 0) not valid;
alter table public.t271_fix validate constraint t271_fix_v_pos;
insert into t271_err values ('fix2', pg_temp.t271_call($c$ call pgpm.transmute('public.t271_fix', 'id', 100::bigint, p_obtain => 2) $c$));
select case when :'pg18'::boolean
  then ok((select v like 'pg_partition_magician: cannot transmute t271_fix -- its CHECK constraint(s) (t271_fix_v_pos) are NOT ENFORCED.%'
             from t271_err where k = 'fix1'),
          'C: t271_fix is refused as NOT ENFORCED while its CHECK is')
  else skip('NOT ENFORCED CHECK constraints exist from PostgreSQL 18', 1) end;
select is((select v from t271_err where k = 'fix2') || ' / ' || (select relkind::text from pg_class where oid = 'public.t271_fix'::regclass),
  'converted / p', 'C: re-created as an enforced CHECK (the remedy), the same call converts t271_fix');
select throws_like($$ insert into public.t271_fix values (310, -1) $$, '%violates check constraint "t271_fix_v_pos"%',
  'C: and the enforced CHECK binds a forward partition');

select dblink_disconnect('t271');
select * from finish();
